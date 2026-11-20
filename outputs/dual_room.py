"""Two-player LAN lobby prototype for the fixed JJXF extension set.

This verifies both installations before admitting a peer. It does not yet
attach to the Godot game or synchronize gameplay.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import secrets
import socket
import sys
from pathlib import Path

REQUIRED_IDS = ("jjxf.combat_core", "jjxf.anim_guard")
MAX_MESSAGE = 16_384


def find_root() -> Path:
    candidates = [Path(sys.executable).resolve().parent, Path(__file__).resolve().parent, Path.cwd()]
    for parent in candidates:
        for folder in (parent, *parent.parents):
            if (folder / "tools/compat.py").is_file() and (folder / "baseline/identity.json").is_file():
                return folder
            for child in folder.glob("机甲旋风兼容启动器V1.45.2"):
                if (child / "tools/compat.py").is_file() and (child / "baseline/identity.json").is_file():
                    return child
    raise FileNotFoundError("未自动找到启动器目录，请使用 --root 指定")


def canonical(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


def fingerprint(value: object) -> str:
    return hashlib.sha256(canonical(value)).hexdigest()


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(8 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_lock(root: Path, zip_paths: tuple[Path, Path] | None = None) -> dict:
    root = root.resolve()
    tools_path = root / "tools"
    sys.path.insert(0, str(tools_path))
    try:
        import compat  # type: ignore

        compat.ROOT = root
        records = {}
        if zip_paths is None:
            library = json.loads((root / ".state/launcher/library.json").read_text(encoding="utf-8"))
            records = {entry["id"]: entry for entry in library["packages"]}
        identity = json.loads((root / "baseline/identity.json").read_text(encoding="utf-8"))
        game = json.loads((root / ".state/game.json").read_text(encoding="utf-8"))
        game_path = Path(game["path"])
        if (game["sha256"] != identity["exe_sha256"] or not game_path.is_file()
                or game_path.stat().st_size != identity["exe_size"]
                or file_sha256(game_path) != identity["exe_sha256"]):
            raise ValueError("游戏本体身份未验证或文件已丢失")
        packages = []
        for index, package_id in enumerate(REQUIRED_IDS):
            if zip_paths is None:
                if package_id not in records:
                    raise ValueError(f"缺少已导入扩展：{package_id}；也可在窗口中直接选择 ZIP")
                record = records[package_id]
                package_path = (root / record["path"]).resolve()
                if not package_path.is_relative_to(root):
                    raise ValueError(f"扩展路径越界：{package_id}")
            else:
                package_path = zip_paths[index].resolve()
                if not package_path.is_file() or package_path.suffix.lower() != ".zip":
                    raise ValueError(f"请选择有效 ZIP：{package_id}")
            package = compat.Package(package_path)
            try:
                if package.id != package_id:
                    raise ValueError(f"选错扩展包：预期 {package_id}，实际 {package.id}")
                if zip_paths is None and package.content_hash != record["content_hash"]:
                    raise ValueError(f"扩展内容与已安装记录不一致：{package_id}")
                packages.append({"id": package.id, "version": package.manifest["version"],
                                 "content_hash": package.content_hash})
            finally:
                if package.archive:
                    package.archive.close()
        lock = {"protocol": 1, "baseline": identity["id"], "game_sha256": identity["exe_sha256"],
                "framework": compat.VERSION, "extensions": packages}
        lock["fingerprint"] = fingerprint(lock)
        return lock
    finally:
        sys.path.remove(str(tools_path))


def send(sock: socket.socket, value: dict) -> None:
    payload = canonical(value) + b"\n"
    if len(payload) > MAX_MESSAGE:
        raise ValueError("房间消息过大")
    sock.sendall(payload)


def receive(sock: socket.socket) -> dict:
    data = bytearray()
    while len(data) < MAX_MESSAGE:
        chunk = sock.recv(1)
        if not chunk:
            raise ConnectionError("连接已关闭")
        if chunk == b"\n":
            value = json.loads(data)
            if not isinstance(value, dict):
                raise ValueError("房间消息格式错误")
            return value
        data.extend(chunk)
    raise ValueError("房间消息过大")


def compare(host: dict, guest: dict) -> str:
    for key in ("protocol", "baseline", "game_sha256", "framework"):
        if host.get(key) != guest.get(key):
            return f"{key} 不一致"
    host_items = host.get("extensions")
    guest_items = guest.get("extensions")
    if not isinstance(host_items, list) or not isinstance(guest_items, list):
        return "扩展清单格式错误"
    if len(host_items) != len(REQUIRED_IDS) or len(guest_items) != len(REQUIRED_IDS):
        return "必须且只能使用两个固定扩展"
    for i, package_id in enumerate(REQUIRED_IDS):
        if not isinstance(host_items[i], dict) or not isinstance(guest_items[i], dict):
            return "扩展清单格式错误"
        if host_items[i].get("id") != package_id or guest_items[i].get("id") != package_id:
            return f"扩展顺序或 ID 不一致：{package_id}"
        for key in ("version", "content_hash"):
            if host_items[i].get(key) != guest_items[i].get(key):
                return f"{package_id} 的 {key} 不一致"
    if host.get("fingerprint") != guest.get("fingerprint"):
        return "配置指纹不一致"
    return ""


def host_room(lock: dict, bind: str, port: int, code: str) -> None:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as server:
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind((bind, port))
        server.listen(1)
        print(f"房间已开启：{bind}:{server.getsockname()[1]}", flush=True)
        print(f"房间口令：{code}", flush=True)
        print(f"固定配置指纹：{lock['fingerprint']}", flush=True)
        while True:
            conn, address = server.accept()
            with conn:
                conn.settimeout(10)
                try:
                    request = receive(conn)
                    if request.get("type") != "join" or request.get("code") != code:
                        reason = "房间口令错误"
                    else:
                        reason = compare(lock, request.get("lock", {}))
                    send(conn, {"type": "reject" if reason else "admit", "reason": reason,
                                "fingerprint": lock["fingerprint"]})
                    print(f"{address[0]}: {'拒绝：' + reason if reason else '配置一致，已加入候厅'}", flush=True)
                    if not reason:
                        conn.settimeout(None)
                        while conn.recv(1024):
                            pass  # Keep the only guest slot occupied until disconnect.
                        print("客人已离开，房间可再次加入", flush=True)
                except (OSError, ValueError, TypeError, ConnectionError) as error:
                    print(f"{address[0]}: 无效连接：{error}", flush=True)


def join_room(lock: dict, address: str, port: int, code: str) -> bool:
    with socket.create_connection((address, port), timeout=10) as conn:
        conn.settimeout(10)
        send(conn, {"type": "join", "code": code, "lock": lock})
        result = receive(conn)
        if result.get("type") == "admit" and result.get("fingerprint") == lock["fingerprint"]:
            print("配置一致，已加入候厅。按 Ctrl+C 离开。游戏同步尚未接入。", flush=True)
            conn.settimeout(None)
            while conn.recv(1024):
                pass
            return True
        print("无法入房：" + str(result.get("reason", "协议错误")))
        return False


def main() -> int:
    parser = argparse.ArgumentParser(description="机甲旋风固定双扩展局域网候厅原型")
    parser.add_argument("--root", type=Path, help="现有启动器目录；未指定时自动查找")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("check", help="验证并打印固定配置")
    host = sub.add_parser("host", help="创建候厅")
    host.add_argument("--bind", default="127.0.0.1", help="局域网开放时填本机局域网 IP")
    host.add_argument("--port", type=int, default=47645)
    host.add_argument("--code", default="", help="可选的房间口令；默认自动生成")
    join = sub.add_parser("join", help="加入候厅")
    join.add_argument("address", help="房主 IP")
    join.add_argument("--port", type=int, default=47645)
    join.add_argument("--code", required=True)
    args = parser.parse_args()
    try:
        lock = load_lock(args.root or find_root())
        if args.command == "check":
            print(json.dumps(lock, ensure_ascii=False, indent=2))
        elif args.command == "host":
            host_room(lock, args.bind, args.port, args.code or secrets.token_urlsafe(12))
        else:
            return 0 if join_room(lock, args.address, args.port, args.code) else 2
        return 0
    except (OSError, ValueError, KeyError) as error:
        print(f"错误：{error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
