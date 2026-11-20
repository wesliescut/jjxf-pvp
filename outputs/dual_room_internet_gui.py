"""Internet room-code GUI. Requires a deployed relay URL."""
from __future__ import annotations

import os
import sys
import json
import queue
import hashlib
import threading
import time
import tkinter as tk
from pathlib import Path
from tkinter import filedialog, messagebox, ttk

import dual_room as room
import relay_client
import save_import
import multiplayer_profile

try:
    import relay_deploy
except Exception:  # pragma: no cover
    relay_deploy = None

# The published build ships without a relay on purpose: every host runs their own
# Worker (see relay_worker/) and points the launcher at it. Resolution order:
#   --relay <url>  >  JJXF_RELAY_URL  >  relay.json next to the exe  >  RELAY_URL
RELAY_URL = ""
RELAY_CONFIG_NAME = "relay.json"


def _relay_config_path() -> Path:
    base = Path(sys.executable).parent if getattr(sys, "frozen", False) else Path(__file__).resolve().parent
    return base / RELAY_CONFIG_NAME


def load_relay_url() -> str:
    for index, arg in enumerate(sys.argv):
        if arg == "--relay" and index + 1 < len(sys.argv):
            return sys.argv[index + 1].strip()
        if arg.startswith("--relay="):
            return arg.split("=", 1)[1].strip()
    env = os.environ.get("JJXF_RELAY_URL", "").strip()
    if env:
        return env
    try:
        data = json.loads(_relay_config_path().read_text(encoding="utf-8"))
        value = str(data.get("relay_url", "")).strip()
        if value:
            return value
    except Exception:
        pass
    return RELAY_URL


def save_relay_url(value: str) -> bool:
    try:
        _relay_config_path().write_text(
            json.dumps({"relay_url": value.strip()}, ensure_ascii=False, indent=2),
            encoding="utf-8")
        return True
    except OSError:
        return False


# ---------------------------------------------------------------- theme ----
FONT = "Microsoft YaHei UI"
MONO = "Consolas"
BG_TOP = (8, 14, 24)
BG_BOTTOM = (13, 26, 43)
CARD = "#101d2e"
BORDER = "#1e3a55"
FIELD = "#08111c"
FIELD_BORDER = "#1c3348"
CYAN = "#35d0ff"
CYAN_DIM = "#8fc8e6"
GOLD = "#f0c040"
TEXT = "#e8f4ff"
TEXT_DIM = "#8fb0c8"
TEXT_FAINT = "#5f7f9f"
ASSET_DIR = Path(__file__).resolve().parent / "assets" / "launcher"

# Physical pixels per design pixel. Without this the OS bitmap-stretches the whole
# window on scaled displays, which is what made the text look blurry.
SCALE = 1.0


def _enable_dpi_awareness() -> None:
    try:
        import ctypes
        try:
            ctypes.windll.shcore.SetProcessDpiAwareness(1)
        except Exception:
            ctypes.windll.user32.SetProcessDPIAware()
    except Exception:
        pass


def _px(value) -> int:
    return int(round(float(value) * SCALE))


def _place(widget, x, y) -> None:
    widget.place(x=_px(x), y=_px(y))


def _hex(rgb) -> str:
    return "#%02x%02x%02x" % tuple(int(v) for v in rgb)


def _round_rect(canvas, x1, y1, x2, y2, r, **kwargs):
    points = [
        x1 + r, y1, x2 - r, y1, x2, y1, x2, y1 + r,
        x2, y2 - r, x2, y2, x2 - r, y2, x1 + r, y2,
        x1, y2, x1, y2 - r, x1, y1 + r, x1, y1,
    ]
    return canvas.create_polygon(points, smooth=True, **kwargs)


def _load_avatar(name: str):
    """Load a pre-rendered circular avatar; None when the asset is missing."""
    path = ASSET_DIR / name
    try:
        if not path.exists():
            return None
        photo = tk.PhotoImage(file=str(path))
        factor = max(1, int(round(2 * SCALE)))
        return photo.subsample(factor)
    except Exception:
        return None


class RoundButton(tk.Canvas):
    """Rounded button drawn on a canvas, with hover and disabled states."""

    PALETTE = {
        "primary": {"fill": "#1c6ea8", "border": "#46c8f0", "text": TEXT,
                    "hover": "#2a8ecb", "disabled_fill": "#12212f", "disabled_text": "#4c6478"},
        "secondary": {"fill": "#142338", "border": "#2c5a82", "text": CYAN_DIM,
                      "hover": "#1b3048", "disabled_fill": "#101d2b", "disabled_text": "#44586c"},
    }

    def __init__(self, master, text, command=None, width=120, height=34,
                 kind="secondary", font=None, radius=8, parent_bg=None):
        super().__init__(master, width=_px(width), height=_px(height), highlightthickness=0,
                         bg=parent_bg or master.cget("bg"), bd=0)
        self._text = text
        self._command = command
        self._kind = kind
        self._radius = radius
        self._font = font or (FONT, 10)
        self._state = "normal"
        self._hover = False
        self._draw()
        self.bind("<Enter>", self._on_enter)
        self.bind("<Leave>", self._on_leave)
        self.bind("<Button-1>", self._on_press)
        self.bind("<ButtonRelease-1>", self._on_release)

    def _draw(self) -> None:
        self.delete("all")
        spec = self.PALETTE[self._kind]
        disabled = self._state == "disabled"
        fill = spec["disabled_fill"] if disabled else (spec["hover"] if self._hover else spec["fill"])
        border = "#22394c" if disabled else spec["border"]
        color = spec["disabled_text"] if disabled else spec["text"]
        width = int(float(self.cget("width")))
        height = int(float(self.cget("height")))
        _round_rect(self, 1, 1, width - 1, height - 1, _px(self._radius),
                    fill=fill, outline=border, width=max(1, _px(2)))
        self.create_text(width // 2, height // 2, text=self._text, fill=color, font=self._font)

    def _on_enter(self, _event=None) -> None:
        if self._state != "disabled":
            self._hover = True
            self._draw()
            self.configure(cursor="hand2")

    def _on_leave(self, _event=None) -> None:
        self._hover = False
        self._draw()
        self.configure(cursor="")

    def _on_press(self, _event=None) -> None:
        if self._state == "disabled":
            return
        self._hover = False
        self._draw()

    def _on_release(self, _event=None) -> None:
        if self._state == "disabled":
            return
        self._hover = True
        self._draw()
        if self._command:
            self._command()

    def configure(self, *args, **kwargs):
        if args:
            return super().configure(*args)
        redraw = False
        if "state" in kwargs:
            self._state = "disabled" if kwargs.pop("state") == "disabled" else "normal"
            redraw = True
        if "text" in kwargs:
            self._text = kwargs.pop("text")
            redraw = True
        if kwargs:
            super().configure(**kwargs)
        if redraw:
            self._draw()

    config = configure

    def cget(self, key):
        if key == "state":
            return self._state
        return super().cget(key)


class InternetWindow:
    def __init__(self) -> None:
        _enable_dpi_awareness()
        self.root = tk.Tk()
        global SCALE
        SCALE = max(1.0, float(self.root.winfo_fpixels("1i")) / 96.0)
        self.root.title("机甲旋风联机启动器 v1.0")
        self.root.geometry("900x640")
        self.root.minsize(900, 640)
        try:
            initial = str(room.find_root())
        except FileNotFoundError:
            initial = ""
        self.root_path = tk.StringVar(value=initial)
        self.combat_zip = tk.StringVar()
        self.anim_zip = tk.StringVar()
        self.relay_url = tk.StringVar(value=load_relay_url())
        self.code = tk.StringVar()
        self.status = tk.StringVar(value="选择启动器目录和两个 ZIP，再检查配置。")
        self.events: queue.Queue[tuple[str, str]] = queue.Queue()
        self.worker: threading.Thread | None = None
        self.game_worker: threading.Thread | None = None
        self.stop_event = threading.Event()
        self.session: tuple[str, str, str] | None = None
        self.connected = False
        self._layout()
        self.root.after(100, self._drain)
        self.root.protocol("WM_DELETE_WINDOW", self._close)

    def _layout(self) -> None:
        self.root.resizable(False, False)
        self.root.configure(bg=_hex(BG_TOP))
        self.root.geometry(f"{_px(900)}x{_px(640)}")
        self.root.minsize(_px(900), _px(640))
        canvas = tk.Canvas(self.root, width=_px(900), height=_px(640), highlightthickness=0,
                           bg=_hex(BG_TOP))
        canvas.place(x=0, y=0)
        self.canvas = canvas

        for y in range(640):
            t = y / 639.0
            canvas.create_line(0, y, 900, y,
                               fill=_hex([BG_TOP[i] + (BG_BOTTOM[i] - BG_TOP[i]) * t for i in range(3)]))
        for x in range(0, 900, 40):
            canvas.create_line(x, 0, x, 640, fill="#0d2033")
        for y in range(0, 640, 40):
            canvas.create_line(0, y, 900, y, fill="#0d2033")

        _round_rect(canvas, 32, 26, 80, 74, 12, fill="#12283e", outline=CYAN, width=2)
        canvas.create_text(56, 50, text="P", fill=CYAN, font=(FONT, 21, "bold"))
        canvas.create_text(92, 26, text="机甲旋风联机启动器", anchor="nw", fill=TEXT, font=(FONT, 20, "bold"))
        canvas.create_text(92, 58, text="跨网双人 PvP  ·  固定战斗核心 + 动画与技能修正",
                           anchor="nw", fill=TEXT_DIM, font=(FONT, 9))
        _round_rect(canvas, 786, 34, 868, 62, 8, fill="#16283c", outline=BORDER)
        canvas.create_text(827, 48, text="v1.0", fill=GOLD, font=(MONO, 11))
        canvas.create_line(32, 96, 868, 96, fill="#1b3348")

        canvas.create_text(576, 30, text="开发者", anchor="e", fill=TEXT_FAINT, font=(FONT, 9))
        self._dev_photos = []
        devs = (("dev_user.png", "作者"), ("dev_gpt.png", "GPT"), ("dev_dsh.png", "DSH"))
        for index, (asset, label) in enumerate(devs):
            cx = 600 + index * 56
            photo = _load_avatar(asset)
            if photo is not None:
                self._dev_photos.append(photo)
                canvas.create_image(cx, 38, image=photo)
            else:
                canvas.create_oval(cx - 18, 20, cx + 18, 56, fill="#2a4a66", outline=CYAN, width=2)
                canvas.create_text(cx, 38, text=label[0], fill="white", font=(FONT, 12, "bold"))
            canvas.create_text(cx, 66, text=label, fill=TEXT_DIM, font=(FONT, 8))

        specs = (
            ("启动器目录", self.root_path, self._browse_folder),
            ("战斗核心 ZIP", self.combat_zip, lambda: self._browse_zip(self.combat_zip)),
            ("动画与技能修正 ZIP", self.anim_zip, lambda: self._browse_zip(self.anim_zip)),
        )
        top = 120
        for label, variable, browse in specs:
            _round_rect(canvas, 32, top, 580, top + 86, 10, fill=CARD, outline=BORDER)
            canvas.create_rectangle(32, top + 12, 35, top + 74, fill=CYAN, outline="")
            canvas.create_text(48, top + 10, text=label, anchor="nw", fill=TEXT_DIM, font=(FONT, 9))
            _round_rect(canvas, 48, top + 34, 476, top + 70, 6, fill=FIELD, outline=FIELD_BORDER)
            self._field(variable, 56, top + 40, 412, 24)
            _place(RoundButton(self.root, "浏览…", browse, width=80, height=34, font=(FONT, 9),
                               parent_bg=CARD), 488, top + 34)
            top += 98

        self.instance_two = tk.BooleanVar(value=os.environ.get("JJXF_PVP_INSTANCE", "1") == "2")
        self._check_box = _round_rect(canvas, 32, 420, 48, 436, 4, fill=FIELD,
                                      outline="#2c5a82", width=2)
        self._check_mark = canvas.create_line(36, 428, 40, 433, 45, 422, fill=CYAN, width=2)
        self._check_text = canvas.create_text(58, 428, text="本机双开（第二实例）", anchor="w",
                                              fill=TEXT_DIM, font=(FONT, 9))
        for item in (self._check_box, self._check_text, self._check_mark):
            canvas.tag_bind(item, "<Button-1>", lambda _event: self._toggle_instance())
        self._draw_instance_state()
        if self.instance_two.get():
            self._apply_instance()

        _place(RoundButton(self.root, "导入单机存档", self.import_save, width=110, height=26,
                           font=(FONT, 9)), 220, 414)
        _place(RoundButton(self.root, "检查配置", self.check, width=96, height=26,
                           font=(FONT, 9)), 338, 414)
        _place(RoundButton(self.root, "测试网络", self.test_network, width=96, height=26,
                           font=(FONT, 9)), 442, 414)

        _round_rect(canvas, 600, 120, 868, 330, 10, fill=CARD, outline=BORDER)
        canvas.create_text(616, 132, text="房间", anchor="nw", fill=TEXT, font=(FONT, 12, "bold"))
        canvas.create_text(616, 156, text="房主创建后把房间码给对方", anchor="nw",
                           fill=TEXT_FAINT, font=(FONT, 8))
        _round_rect(canvas, 616, 178, 852, 232, 8, fill=FIELD, outline="#2c6e96", width=2)
        code_entry = tk.Entry(self.root, textvariable=self.code, font=(MONO, 17), bg=FIELD, fg=CYAN,
                              insertbackground=CYAN, relief="flat", justify="center",
                              highlightthickness=0)
        code_entry.place(x=_px(620), y=_px(186), width=_px(228), height=_px(38))
        _place(RoundButton(self.root, "创建房间", self.host, width=236, height=34, kind="primary",
                           font=(FONT, 10, "bold"), parent_bg=CARD), 616, 240)
        _place(RoundButton(self.root, "加入房间", self.join, width=114, height=34, font=(FONT, 9),
                           parent_bg=CARD), 616, 282)
        _place(RoundButton(self.root, "离开房间", self.leave, width=114, height=34, font=(FONT, 9),
                           parent_bg=CARD), 738, 282)

        _round_rect(canvas, 600, 342, 868, 440, 10, fill=CARD, outline=BORDER)
        canvas.create_text(616, 354, text="中继", anchor="nw", fill=TEXT, font=(FONT, 12, "bold"))
        _round_rect(canvas, 616, 372, 740, 398, 6, fill=FIELD, outline=FIELD_BORDER)
        self._field(self.relay_url, 620, 377, 116, 16, font_size=7)
        _place(RoundButton(self.root, "保存", self.save_relay, width=44, height=26, font=(FONT, 9),
                           parent_bg=CARD), 744, 372)
        _place(RoundButton(self.root, "部署", self.deploy_relay, width=52, height=26, kind="primary",
                           font=(FONT, 9, "bold"), parent_bg=CARD), 792, 372)
        self._relay_dot = canvas.create_oval(616, 410, 626, 420, fill="#f0c040", outline="")
        self._relay_note = canvas.create_text(634, 415, text="", anchor="w",
                                              fill=TEXT_DIM, font=(FONT, 8))
        self._refresh_relay_note()

        self.play_button = RoundButton(self.root, "进入双人 PvP", self.play, width=380, height=54,
                                       kind="primary", font=(FONT, 15, "bold"))
        _place(self.play_button, 32, 460)
        self.play_button.configure(state="disabled")
        self.solo_button = RoundButton(self.root, "单人木桩", self.solo, width=156, height=54,
                                       font=(FONT, 10))
        _place(self.solo_button, 424, 460)

        self._status_item = canvas.create_text(34, 524, text=self.status.get(), anchor="w",
                                               fill="#6edcbe", font=(FONT, 9))
        self.status.trace_add("write", lambda *_args: canvas.itemconfigure(
            self._status_item, text=self.status.get()))

        self.log = tk.Text(self.root, state="disabled", wrap="word", bg="#060c14", fg=TEXT_FAINT,
                           relief="flat", highlightthickness=1, highlightbackground="#182c42",
                           insertbackground=CYAN, font=(MONO, 8))
        self.log.place(x=_px(32), y=_px(540), width=_px(836), height=_px(84))

        # Everything above was laid out in design units; scale once to physical pixels
        # so the geometry matches the DPI-scaled font metrics.
        if SCALE != 1.0:
            canvas.scale("all", 0, 0, SCALE, SCALE)

    def _field(self, variable, x, y, width, height, font_size=9):
        entry = tk.Entry(self.root, textvariable=variable, font=(MONO, font_size), bg=FIELD, fg=TEXT_DIM,
                         insertbackground=CYAN, relief="flat", highlightthickness=1,
                         highlightbackground=FIELD_BORDER, highlightcolor=CYAN)
        entry.place(x=_px(x), y=_px(y), width=_px(width), height=_px(height))
        return entry

    def _refresh_relay_note(self) -> None:
        value = self.relay_url.get().strip()
        if not value:
            self.canvas.itemconfigure(self._relay_dot, fill="#f0c040")
            self.canvas.itemconfigure(self._relay_note, text="未配置：请填写你自己的中继地址")
            return
        host = value.replace("https://", "").replace("http://", "").rstrip("/")
        self.canvas.itemconfigure(self._relay_dot, fill="#50dc8c")
        self.canvas.itemconfigure(self._relay_note, text=host[:34])

    def deploy_relay(self) -> None:
        """Create the relay in the user's own Cloudflare account, no terminal needed."""
        global relay_deploy
        if relay_deploy is None:
            try:
                import relay_deploy as module
                relay_deploy = module
            except Exception as error:
                self.status.set("部署模块不可用：" + str(error))
                return
        dialog = tk.Toplevel(self.root)
        dialog.title("部署我自己的中继")
        dialog.geometry("660x580")
        dialog.configure(bg=_hex(BG_TOP))
        dialog.transient(self.root)
        tk.Label(dialog, text="部署自己的中继（Cloudflare Workers）", bg=_hex(BG_TOP), fg=TEXT,
                 font=(FONT, 15, "bold")).place(x=22, y=16)
        tk.Label(dialog, text=(
            "1. 点“打开 Token 页面”，选模板「Edit Cloudflare Workers」→ Continue → Create token。\n"
            "2. 复制 Token 粘贴到第 1 栏；第 2 栏账号 ID 一般留空。\n"
            "3. 点“开始部署”，成功后地址会自动填进启动器。"),
            justify="left", wraplength=610, bg=_hex(BG_TOP), fg=TEXT_DIM,
            font=(FONT, 9)).place(x=22, y=50)

        tk.Label(dialog, text="① API Token（必填）", bg=_hex(BG_TOP), fg=TEXT_DIM,
                 font=(FONT, 9)).place(x=22, y=150)
        token_var = tk.StringVar()
        token_entry = tk.Entry(dialog, textvariable=token_var, show="*", bg=FIELD, fg=TEXT,
                               insertbackground=CYAN, relief="flat", highlightthickness=1,
                               highlightbackground=FIELD_BORDER, highlightcolor=CYAN,
                               font=(MONO, 9))
        token_entry.place(x=22, y=170, width=616, height=28)

        tk.Label(dialog, text="② 账号 ID（可留空，32 位十六进制）", bg=_hex(BG_TOP), fg=TEXT_DIM,
                 font=(FONT, 9)).place(x=22, y=206)
        tk.Label(dialog, text="③ Worker 名称", bg=_hex(BG_TOP), fg=TEXT_DIM,
                 font=(FONT, 9)).place(x=342, y=206)
        account_var = tk.StringVar()
        account_entry = tk.Entry(dialog, textvariable=account_var, bg=FIELD, fg=TEXT,
                                 insertbackground=CYAN, relief="flat", highlightthickness=1,
                                 highlightbackground=FIELD_BORDER, highlightcolor=CYAN,
                                 font=(MONO, 9))
        account_entry.place(x=22, y=226, width=300, height=28)
        worker_var = tk.StringVar(value=str(getattr(relay_deploy.relay_bundle, "SCRIPT_NAME",
                                                    "jjxf-two-player-lobby")))
        worker_entry = tk.Entry(dialog, textvariable=worker_var, bg=FIELD, fg=TEXT,
                                insertbackground=CYAN, relief="flat", highlightthickness=1,
                                highlightbackground=FIELD_BORDER, highlightcolor=CYAN,
                                font=(MONO, 9))
        worker_entry.place(x=342, y=226, width=296, height=28)

        log = tk.Text(dialog, state="disabled", wrap="word", bg="#060c14", fg=TEXT_FAINT,
                      relief="flat", highlightthickness=1, highlightbackground="#182c42",
                      font=(MONO, 8))
        log.place(x=22, y=306, width=616, height=180)
        result = tk.StringVar(value="")
        tk.Label(dialog, textvariable=result, bg=_hex(BG_TOP), fg="#6edcbe",
                 font=(FONT, 9), wraplength=470, justify="left").place(x=22, y=496)

        def write(message: str) -> None:
            log.configure(state="normal")
            log.insert("end", message + "\n")
            log.see("end")
            log.configure(state="disabled")

        def open_token_page() -> None:
            import webbrowser
            webbrowser.open("https://dash.cloudflare.com/profile/api-tokens")

        events: queue.Queue[tuple[str, object]] = queue.Queue()
        deploy_button = RoundButton(dialog, "开始部署", None, width=130, height=34, kind="primary",
                                    font=(FONT, 10, "bold"), parent_bg=_hex(BG_TOP))
        deploy_button.place(x=22, y=264)
        verify_button = RoundButton(dialog, "验证 Token", None, width=120, height=34,
                                    font=(FONT, 9), parent_bg=_hex(BG_TOP))
        verify_button.place(x=162, y=264)
        page_button = RoundButton(dialog, "打开 Token 页面", None, width=150, height=34,
                                  font=(FONT, 9), parent_bg=_hex(BG_TOP))
        page_button.place(x=292, y=264)
        close_button = RoundButton(dialog, "关闭", dialog.destroy, width=90, height=34,
                                   font=(FONT, 9), parent_bg=_hex(BG_TOP))
        close_button.place(x=548, y=496)

        def start() -> None:
            token = token_var.get().strip()
            if not token:
                write("请先粘贴 API Token")
                return
            deploy_button.configure(state="disabled")
            verify_button.configure(state="disabled")
            result.set("")
            write("开始部署…")
            account_id = account_var.get().strip()

            def work() -> None:
                try:
                    url, account = relay_deploy.deploy_all(
                        token, script_name=worker_var.get().strip() or "jjxf-two-player-lobby",
                        account_id=account_id,
                        progress=lambda message: events.put(("log", message)))
                    events.put(("done", (url, account)))
                except Exception as error:  # noqa: BLE001 - surfaced to the dialog
                    events.put(("error", str(error)))

            threading.Thread(target=work, daemon=True).start()

        def verify() -> None:
            token = token_var.get().strip()
            if not token:
                write("请先粘贴 API Token")
                return

            def work() -> None:
                try:
                    relay_deploy.verify_token(token)
                    events.put(("log", "Token 有效"))
                    try:
                        accounts = relay_deploy.list_accounts(token)
                        name = str(accounts[0].get("name", accounts[0].get("id", "")))
                        events.put(("verified", name))
                    except Exception as error:  # noqa: BLE001
                        events.put(("log", "Token 有效，但读不到账号列表：%s" % error))
                        events.put(("log", "请在 Cloudflare 首页右侧复制账号 ID，填到第 2 栏。"))
                except Exception as error:  # noqa: BLE001
                    events.put(("error", str(error)))

            threading.Thread(target=work, daemon=True).start()

        deploy_button.configure(text="开始部署")
        deploy_button._command = start
        verify_button._command = verify
        page_button._command = open_token_page

        def drain() -> None:
            if not dialog.winfo_exists():
                return
            while True:
                try:
                    kind, value = events.get_nowait()
                except queue.Empty:
                    break
                if kind == "log":
                    write(str(value))
                elif kind == "verified":
                    write("账号：" + str(value))
                elif kind == "done":
                    url, account = value
                    result.set("部署成功，已填入：" + url)
                    write("账号 %s 部署完成" % account)
                    self.relay_url.set(url)
                    self._refresh_relay_note()
                    save_relay_url(url)
                    self.status.set("中继已部署并保存：" + url)
                    deploy_button.configure(state="normal")
                    verify_button.configure(state="normal")
                else:
                    write("失败：" + str(value))
                    result.set("部署失败，详见上面的日志")
                    deploy_button.configure(state="normal")
                    verify_button.configure(state="normal")
            dialog.after(120, drain)

        dialog.after(120, drain)

    def save_relay(self) -> None:
        value = self.relay_url.get().strip().rstrip("/")
        if not value.startswith("https://"):
            self.status.set("中继地址必须以 https:// 开头")
            return
        self.relay_url.set(value)
        self._refresh_relay_note()
        if save_relay_url(value):
            self.status.set("中继地址已保存到 " + _relay_config_path().name)
            self._emit("log", "中继地址已保存：" + value)
        else:
            self.status.set("中继地址已生效，但写入配置文件失败（下次需重新填写）")

    def _draw_instance_state(self) -> None:
        self.canvas.itemconfigure(self._check_mark,
                                  state="normal" if self.instance_two.get() else "hidden")

    def _toggle_instance(self) -> None:
        self.instance_two.set(not self.instance_two.get())
        self._draw_instance_state()
        self._apply_instance()

    def _apply_instance(self) -> None:
        # Two windows on one PC must not share the isolated profile: the runtime
        # scripts, the PvP save, the user settings and the compat lock all live in
        # that directory, so the second instance gets its own folder.
        os.environ["JJXF_PVP_INSTANCE"] = "2" if self.instance_two.get() else "1"
        suffix = "（实例 2）" if self.instance_two.get() else ""
        self.root.title(f"机甲旋风联机启动器 v1.0{suffix}")
        self.status.set("本机双开已开启：这个窗口使用独立的联机存档与运行目录。"
                        if self.instance_two.get() else
                        "选择启动器目录和两个 ZIP，再检查配置。")

    def _browse_folder(self) -> None:
        path = filedialog.askdirectory(title="选择兼容启动器目录")
        if path:
            self.root_path.set(path)

    def _browse_zip(self, variable: tk.StringVar) -> None:
        path = filedialog.askopenfilename(title="选择扩展 ZIP", filetypes=[("ZIP 文件", "*.zip")])
        if path:
            variable.set(path)

    def import_save(self) -> None:
        """Stage a role in the separate multiplayer profile, without touching the source."""
        launcher_root = Path(self.root_path.get().strip()) if self.root_path.get().strip() else None
        source = tk.StringVar(value=str(save_import.suggest_source(launcher_root)))
        legacy_curve = tk.BooleanVar(value=False)
        dialog = tk.Toplevel(self.root)
        dialog.title("导入单机角色")
        dialog.geometry("650x465")
        dialog.transient(self.root)
        frame = ttk.Frame(dialog, padding=16)
        frame.pack(fill="both", expand=True)
        ttk.Label(frame, text="从单机存档选择角色", font=("Microsoft YaHei UI", 14, "bold")).pack(anchor="w")
        ttk.Label(frame, text="先保存只读副本，再选择追加角色或备份后替换全部联机角色。原单机存档不会被修改。",
                  wraplength=610).pack(anchor="w", pady=(8, 12))
        path_frame = ttk.Frame(frame)
        path_frame.pack(fill="x")
        ttk.Entry(path_frame, textvariable=source).pack(side="left", fill="x", expand=True)
        def browse() -> None:
            path = filedialog.askopenfilename(parent=dialog, title="选择 offline_roles.json",
                                              filetypes=[("JSON 存档", "*.json")])
            if path:
                source.set(path)
                preview()
        ttk.Button(path_frame, text="浏览…", command=browse).pack(side="left", padx=(8, 0))
        ttk.Checkbutton(frame, text="单机使用过「背包与主界面 1.2.1」经验曲线：按原版曲线换算，保持等级",
                        variable=legacy_curve).pack(anchor="w", pady=(10, 0))
        ttk.Label(frame, text="选择要导入的角色：").pack(anchor="w", pady=(12, 3))
        role_list = tk.Listbox(frame, exportselection=False, height=9)
        role_list.pack(fill="both", expand=True)
        info = tk.StringVar(value="点击“读取角色”预览存档。")
        ttk.Label(frame, textvariable=info, wraplength=610, foreground="#126d82").pack(anchor="w", pady=8)
        preview_sha: str | None = None
        stage_path: Path | None = None
        dialog_events: queue.Queue[tuple[str, object]] = queue.Queue()

        def preview() -> None:
            nonlocal preview_sha
            role_list.delete(0, "end")
            preview_sha = None
            try:
                data, value = save_import.read_save(Path(source.get().strip()))
                preview_sha = hashlib.sha256(data).hexdigest()
                for summary in save_import.role_summaries(value):
                    role_list.insert("end", summary)
                count = len(value["roles"])
                info.set(f"已读取 {count} 个角色；请选择一个角色。" if count else "该存档没有角色可导入。")
            except save_import.SaveImportError as error:
                info.set(str(error))

        def confirm() -> None:
            nonlocal stage_path
            selected = role_list.curselection()
            if preview_sha is None or not selected:
                info.set("请先读取存档并选择一个角色。")
                return
            try:
                target = save_import.stage_role(Path(source.get().strip()), selected[0], expected_sha256=preview_sha)
            except (save_import.SaveImportError, OSError) as error:
                info.set("导入失败：" + str(error))
                return
            self._emit("log", "单机角色导入副本已保存：" + str(target))
            stage_path = target
            append_button.configure(state="normal")
            replace_button.configure(state="normal")
            info.set("导入副本已保存。选“追加角色”可保留现有联机角色；“替换全部”会先备份旧存档。")

        def convert(mode: str, approved_adjustment_hash: str | None = None) -> None:
            if stage_path is None:
                info.set("请先保存一个角色的导入副本。")
                return
            if mode == "replace" and approved_adjustment_hash is None and not messagebox.askyesno(
                "备份后替换全部联机角色",
                "这会用所选角色替换联机存档中的全部角色和进度。程序会先保存旧存档备份。确定继续吗？",
                parent=dialog,
            ):
                return
            try:
                config = self._config()
            except ValueError as error:
                info.set(str(error))
                return
            append_button.configure(state="disabled")
            replace_button.configure(state="disabled")
            info.set("正在准备固定扩展组合并由游戏引擎验证角色，可能需要一分钟…")
            staged = stage_path
            use_legacy_curve = legacy_curve.get()

            def work() -> None:
                try:
                    launch, plan, base = multiplayer_profile.prepare_profile(config[0], config[1])
                    result = multiplayer_profile.convert_staged_role(
                        staged, launch, plan, base, mode=mode,
                        approved_adjustment_hash=approved_adjustment_hash,
                        force_legacy_experience=use_legacy_curve)
                    self._emit("log", "隔离角色存档已生成：" + str(result))
                    _, converted_save = save_import.read_save(result)
                    import_record = converted_save.get("_multiplayer_imports", [])[-1]
                    experience_note = ""
                    transfer = import_record.get("experience_curve_transfer") if isinstance(import_record, dict) else None
                    if isinstance(transfer, dict):
                        experience_note = f"已按原版本体经验曲线换算，角色保持 {transfer['level']} 级。"
                        self._emit("log", experience_note)
                    self._emit("status", "角色转换完成，可以进入单人木桩或双人 PvP。")
                    dialog_events.put(("done", ("追加" if mode == "append" else "替换", experience_note)))
                except multiplayer_profile.RoleAdjustmentRequired as error:
                    self._emit("log", "游戏整理了导入副本：\n" + error.summary)
                    dialog_events.put(("adjust", (mode, error.summary, error.fingerprint)))
                except Exception as error:
                    self._emit("log", "角色转换未完成：" + str(error))
                    self._emit("status", "角色转换未完成：" + str(error))
                    dialog_events.put(("error", str(error)))

            threading.Thread(target=work, daemon=True).start()

        def drain_dialog() -> None:
            if not dialog.winfo_exists():
                return
            while True:
                try:
                    kind, value = dialog_events.get_nowait()
                except queue.Empty:
                    break
                if kind == "done":
                    action, experience_note = value
                    info.set(action + "角色通过验证，联机专用隔离存档已更新。" + experience_note)
                    messagebox.showinfo("角色转换通过", action + "角色已完成。\n" + experience_note
                                        + "\n单机原存档未修改。\n游戏战斗同步仍需开发。", parent=dialog)
                elif kind == "adjust":
                    mode, summary, fingerprint = value
                    append_button.configure(state="normal")
                    replace_button.configure(state="normal")
                    approved = messagebox.askyesno(
                        "确认游戏整理后的角色数据",
                        "游戏读取这份单机存档时会整理以下内容：\n\n" + summary
                        + "\n\n继续后只会更新联机专用存档；单机原档和导入副本保留。"
                        "已有联机存档会先备份。是否采用游戏整理后的结果？",
                        parent=dialog,
                    )
                    if approved:
                        convert(mode, approved_adjustment_hash=fingerprint)
                    else:
                        info.set("已取消转换；现有联机存档未修改。")
                else:
                    info.set("转换未完成：" + value)
                    append_button.configure(state="normal")
                    replace_button.configure(state="normal")
            dialog.after(100, drain_dialog)

        buttons = ttk.Frame(frame)
        buttons.pack(anchor="w")
        ttk.Button(buttons, text="读取角色", command=preview).pack(side="left", padx=(0, 8))
        ttk.Button(buttons, text="保存导入副本", command=confirm).pack(side="left", padx=(0, 8))
        append_button = ttk.Button(buttons, text="追加角色", command=lambda: convert("append"), state="disabled")
        append_button.pack(side="left", padx=(0, 8))
        replace_button = ttk.Button(buttons, text="备份后替换全部", command=lambda: convert("replace"), state="disabled")
        replace_button.pack(side="left")
        preview()
        dialog.after(100, drain_dialog)

    def _emit(self, kind: str, value: str) -> None:
        self.events.put((kind, value))

    def _drain(self) -> None:
        while True:
            try:
                kind, value = self.events.get_nowait()
            except queue.Empty:
                break
            if kind == "status":
                self.status.set(value)
            elif kind == "code":
                self.code.set(value)
            elif kind == "connected":
                self.connected = value == "1"
                self.play_button.configure(state="normal" if self.connected else "disabled")
            else:
                self.log.configure(state="normal")
                self.log.insert("end", value + "\n")
                self.log.see("end")
                self.log.configure(state="disabled")
        self.root.after(100, self._drain)

    def _config(self) -> tuple[Path, tuple[Path, Path], str]:
        root = self.root_path.get().strip()
        combat = self.combat_zip.get().strip()
        anim = self.anim_zip.get().strip()
        if not root or not combat or not anim:
            raise ValueError("请先选择启动器目录和两个 ZIP")
        relay = self.relay_url.get().strip()
        if not relay:
            raise ValueError("请先填写中继地址：开源版不内置中继，需要先部署自己的 Worker")
        return Path(root), (Path(combat), Path(anim)), relay

    def _start(self, target, *args) -> None:
        if self.worker and self.worker.is_alive():
            self._emit("status", "请先离开当前房间。")
            return
        self.stop_event.clear()
        self.worker = threading.Thread(target=self._run, args=(target, args), daemon=True)
        self.worker.start()

    def _run(self, target, args) -> None:
        try:
            target(*args)
        except Exception as error:
            self._emit("status", "操作失败：" + str(error))
            self._emit("log", "错误：" + str(error))

    def check(self) -> None:
        try:
            config = self._config()
            self._start(self._check, config)
        except ValueError as error:
            self.status.set(str(error))

    def _check(self, config) -> None:
        self._emit("status", "正在校验游戏本体和两个 ZIP…")
        lock = room.load_lock(config[0], config[1])
        self._emit("log", "配置指纹：" + lock["fingerprint"])
        self._emit("status", "配置校验通过。")

    def test_network(self) -> None:
        url = self.relay_url.get().strip()
        if not url:
            self.status.set("请先填写中继地址")
            return
        self._start(self._test_network, url)

    def _test_network(self, url: str) -> None:
        self._emit("status", "正在连接跨网房间服务…")
        relay_client.probe(url)
        self._emit("log", "这台电脑可以访问跨网房间服务。")
        self._emit("status", "网络测试通过。")

    def host(self) -> None:
        try:
            self._start(self._host, self._config())
        except ValueError as error:
            self.status.set(str(error))

    def join(self) -> None:
        try:
            code = self.code.get().strip().upper()
            if not code:
                raise ValueError("请输入房主给出的房间码")
            self._start(self._join, self._config(), code)
        except ValueError as error:
            self.status.set(str(error))

    def _host(self, config) -> None:
        self._emit("status", "正在校验并创建房间…")
        lock = room.load_lock(config[0], config[1])
        result = relay_client.call(config[2], "create", {"lock": lock})
        code, token = result["code"], result["host_token"]
        self.session = (config[2], code, token)
        self._emit("code", code)
        self._emit("log", "房间已创建，房间码：" + code)
        self._poll()

    def _join(self, config, code: str) -> None:
        self._emit("status", "正在校验并加入房间…")
        lock = room.load_lock(config[0], config[1])
        result = relay_client.call(config[2], "join", {"code": code, "lock": lock})
        self.session = (config[2], code, result["guest_token"])
        self._emit("log", "已加入房间：" + code)
        self._poll()

    def _poll(self) -> None:
        previous = None
        try:
            while not self.stop_event.is_set():
                if not self.session:
                    break
                url, code, token = self.session
                result = relay_client.call(url, "status", {"code": code, "token": token})
                connected = bool(result["connected"])
                if connected != previous:
                    self._emit("connected", "1" if connected else "0")
                    self._emit("status", "双人房间已连接，可以进入 PvP 擂台。" if connected else "房间已创建，等待另一位玩家。")
                    self._emit("log", "另一位玩家已连接。" if connected else "等待另一位玩家加入。")
                    previous = connected
                self.stop_event.wait(3)
        finally:
            session = self.session
            self.session = None
            if session:
                try:
                    relay_client.call(session[0], "leave", {"code": session[1], "token": session[2]})
                except Exception:
                    pass
            self._emit("status", "已离开房间。")
            self._emit("connected", "0")

    def play(self) -> None:
        if not self.connected or self.session is None:
            self.status.set("请先让两人加入同一个房间。")
            return
        if self.game_worker and self.game_worker.is_alive():
            self.status.set("共享场景已经在运行。")
            return
        try:
            config = self._config()
        except ValueError as error:
            self.status.set(str(error))
            return
        session = self.session
        self.game_worker = threading.Thread(target=self._run_game, args=(config, session), daemon=True)
        self.game_worker.start()

    def solo(self) -> None:
        if self.game_worker and self.game_worker.is_alive():
            self.status.set("游戏已经在运行。")
            return
        try:
            config = self._config()
        except ValueError as error:
            self.status.set(str(error))
            return
        self.game_worker = threading.Thread(target=self._run_solo, args=(config,), daemon=True)
        self.game_worker.start()

    def _run_solo(self, config) -> None:
        try:
            self._emit("status", "正在准备隔离游戏，随后打开单人练习场…")
            launch, plan, base = multiplayer_profile.prepare_profile(config[0], config[1])
            result = multiplayer_profile.run_solo_scene(launch, plan, base)
            self._emit("log", "单人练习场已关闭，退出码：" + str(result))
            self._emit("status", "游戏已关闭。")
        except Exception as error:
            self._emit("status", "单人练习场启动失败：" + str(error))
            self._emit("log", "单人练习场启动失败：" + str(error))

    def _run_game(self, config, session) -> None:
        try:
            self._emit("status", "正在准备隔离游戏，随后打开 PvP 擂台…")
            launch, plan, base = multiplayer_profile.prepare_profile(config[0], config[1])
            result = multiplayer_profile.run_shared_scene(launch, plan, base, session[1], session[2], session[0])
            self._emit("log", "PvP 擂台已关闭，退出码：" + str(result))
            self._emit("status", "游戏已关闭；候厅房间仍保持连接。")
        except Exception as error:
            self._emit("status", "PvP 擂台启动失败：" + str(error))
            self._emit("log", "PvP 擂台启动失败：" + str(error))

    def leave(self) -> None:
        self.stop_event.set()
        self.status.set("正在离开房间…")

    def _close(self) -> None:
        if self.game_worker and self.game_worker.is_alive():
            self.status.set("请先关闭游戏窗口，再退出候厅。")
            return
        self.leave()
        self.root.destroy()


if __name__ == "__main__":
    InternetWindow().root.mainloop()
