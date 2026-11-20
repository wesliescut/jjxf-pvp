"""Prepare an isolated fixed-mod game profile and verify one imported role.

This is a foundation for a multiplayer launcher, not networked gameplay.
The source launcher and original player save are never written by this module.
"""
from __future__ import annotations

import copy
import hashlib
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

import dual_room
import experience_transfer
import save_import

EXPECTED = {
    "jjxf.combat_core": ("1.1.27", "d6541acabf6eac8128039b3ccee8edd8c12922fbbc6e3774d9caaed03551694f"),
    "jjxf.anim_guard": ("2.0.5", "19a7a31dc7a94e6dc0ea0fba44ad17061c1fe32c083f1db3ac9b44b81125660e"),
}


class ProfileError(ValueError):
    pass


class RoleAdjustmentRequired(ProfileError):
    """The game migrated role data; the player must review the changes."""

    def __init__(self, changes: list[str], fingerprint: str) -> None:
        self.changes = changes
        self.fingerprint = fingerprint
        self.summary = "\n".join(changes[:12])
        if len(changes) > 12:
            self.summary += f"\n……另有 {len(changes) - 12} 处变化"
        super().__init__("游戏读取存档时整理了角色数据，请确认后再导入。\n" + self.summary)


def _role_changes(before: object, after: object, path: str = "角色") -> list[str]:
    """Report changed paths without exposing player names or inventory values."""
    if isinstance(before, dict) and isinstance(after, dict):
        changes = []
        for key in sorted(before.keys() | after.keys(), key=str):
            child = f"{path}.{key}"
            if key not in before:
                changes.append(child + "：游戏补充字段")
            elif key not in after:
                changes.append(child + "：游戏移除字段")
            else:
                changes.extend(_role_changes(before[key], after[key], child))
        return changes
    if isinstance(before, list) and isinstance(after, list):
        if before == after:
            return []
        if len(before) != len(after):
            return [f"{path}：条目数 {len(before)} → {len(after)}"]
        if before and all(isinstance(item, dict) for item in before + after) and path == "角色":
            changes = []
            for index, (old_role, new_role) in enumerate(zip(before, after), 1):
                changes.extend(_role_changes(old_role, new_role, f"角色 {index}"))
            return changes
        changed = sum(a != b for a, b in zip(before, after))
        return [f"{path}：{changed} 个条目发生变化"]
    return [] if before == after else [path + "：值发生变化"]


def profile_directory() -> Path:
    local = Path(os.environ.get("LOCALAPPDATA", Path.home() / "AppData" / "Local"))
    # A second window on the same PC must not share runtime scripts, the PvP save,
    # the user settings or the compat lock, so it gets its own directory.
    instance = os.environ.get("JJXF_PVP_INSTANCE", "1").strip() or "1"
    if not instance.isdigit() or int(instance) <= 1:
        return local / "JJXF_Internet_Room" / "isolated_game"
    return local / "JJXF_Internet_Room" / ("isolated_game_" + instance)


def _write_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent,
                                     prefix=".write-", delete=False) as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2)
        stream.write("\n")
        temporary = Path(stream.name)
    os.replace(temporary, path)


def _copy_base(source_root: Path, destination: Path, game_path: Path, engine_path: Path) -> None:
    for folder in ("baseline", "runtime", "tools"):
        source = source_root / folder
        if not source.is_dir():
            raise ProfileError("启动器缺少运行文件：" + folder)
        for item in source.rglob("*"):
            if not item.is_file() or "__pycache__" in item.parts or item.suffix == ".pyc":
                continue
            target = destination / folder / item.relative_to(source)
            target.parent.mkdir(parents=True, exist_ok=True)
            if not target.exists() or hashlib.sha256(target.read_bytes()).digest() != hashlib.sha256(item.read_bytes()).digest():
                shutil.copy2(item, target)
    bundled = Path(getattr(sys, "_MEIPASS", Path(__file__).parent)) / "runtime_multiplayer"
    if not all((bundled / name).is_file() for name in (
        "peer_sync.gd", "pvp_world.gd", "pvp_world.tscn", "pvp_run.gd",
        "pvp_target.gd", "pvp_remote_actor.gd", "pvp_visual_run.gd", "pvp_visual_target.gd")):
        raise ProfileError("PvP 擂台运行文件缺失，请重新下载完整 EXE。")
    for asset in bundled.iterdir():
        if asset.is_file() and asset.suffix in (".gd", ".tscn"):
            target = destination / "runtime" / "_multiplayer" / asset.name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(asset.read_bytes())
    project = destination / "runtime" / "project.godot"
    project_text = project.read_text(encoding="utf-8-sig")
    if "PeerSync=\"*res://_multiplayer/peer_sync.gd\"" not in project_text:
        if "\n[display]" not in project_text or "\n[autoload]" not in project_text:
            raise ProfileError("启动器工程结构不兼容，无法加入联机同步脚本。")
        project_text = project_text.replace("\n[display]", "\nPeerSync=\"*res://_multiplayer/peer_sync.gd\"\n\n[display]", 1)
        project.write_text(project_text, encoding="utf-8")
    _write_json(destination / "local.json", {"base_exe": str(game_path), "engine": str(engine_path)})


def _compat_at(destination: Path):
    tools = destination / "tools"
    sys.path.insert(0, str(tools))
    try:
        spec = importlib.util.spec_from_file_location("jjxf_multiplayer_compat", tools / "compat.py")
        if spec is None or spec.loader is None:
            raise ProfileError("无法读取独立运行底座。")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module
    finally:
        sys.path.remove(str(tools))


def prepare_profile(source_root: Path, zip_paths: tuple[Path, Path],
                    destination: Path | None = None) -> tuple[dict, Path, Path]:
    source_root = source_root.resolve()
    zip_paths = tuple(path.resolve() for path in zip_paths)
    lock = dual_room.load_lock(source_root, zip_paths)
    for package in lock["extensions"]:
        if (package["version"], package["content_hash"]) != EXPECTED[package["id"]]:
            raise ProfileError("联机资料只接受指定版本的两个扩展包：" + package["id"])
    game = json.loads((source_root / ".state" / "game.json").read_text(encoding="utf-8-sig"))
    game_path = Path(game["path"])
    engine_path = source_root / "launcher" / "runtime" / "Godot.exe"
    if not engine_path.is_file():
        raise ProfileError("找不到启动器自带的 Godot.exe。")
    destination = (destination or profile_directory()).resolve()
    if destination == source_root or source_root in destination.parents:
        raise ProfileError("联机资料目录必须与原启动器分开。")
    _copy_base(source_root, destination, game_path, engine_path)
    profile = destination / ".state" / "fixed_profile.json"
    _write_json(profile, {"id": "multiplayer_fixed", "save_mode": "isolated",
                          "extensions": [str(path) for path in zip_paths], "runtime_optimizations": True})
    sys.path.insert(0, str(destination / "tools"))
    try:
        compat = _compat_at(destination)
        launch, launch_path = compat.prepare(profile)
    except Exception as error:
        raise ProfileError("固定扩展组合准备失败：" + str(error)) from error
    finally:
        sys.path.remove(str(destination / "tools"))
    if [part["id"] for part in launch["modules"]] != list(dual_room.REQUIRED_IDS):
        raise ProfileError("固定扩展组合顺序不符。")
    return launch, launch_path, destination


def convert_staged_role(stage: Path, launch: dict, launch_path: Path, destination: Path,
                        mode: str = "append", timeout: int = 120,
                        approved_adjustment_hash: str | None = None,
                        force_legacy_experience: bool = False) -> Path:
    """Append a role, or replace all isolated roles after a verified backup."""
    if mode not in ("append", "replace"):
        raise ProfileError("未知的角色导入方式。")
    compat = _compat_at(destination)
    try:
        with compat.profile_guard(compat.save_lock_path(launch)):
            return _convert_staged_role_locked(stage, launch, launch_path, destination, mode, timeout,
                                               approved_adjustment_hash, force_legacy_experience)
    except compat.CompatError as error:
        raise ProfileError(str(error)) from error


def _convert_staged_role_locked(stage: Path, launch: dict, launch_path: Path,
                                destination: Path, mode: str, timeout: int,
                                approved_adjustment_hash: str | None,
                                force_legacy_experience: bool) -> Path:
    stage = stage.resolve()
    manifest = json.loads((stage / "import.json").read_text(encoding="utf-8-sig"))
    if manifest.get("schema") != 1 or manifest.get("status") != "awaiting_multiplayer_runtime":
        raise ProfileError("导入副本标记不正确。")
    snapshot = stage / "source_snapshot.json"
    data, source = save_import.read_save(snapshot)
    if hashlib.sha256(data).hexdigest() != manifest.get("source_sha256"):
        raise ProfileError("导入副本指纹不匹配。")
    index = manifest.get("role_index")
    if not isinstance(index, int) or isinstance(index, bool) or not 0 <= index < len(source["roles"]):
        raise ProfileError("导入副本角色索引无效。")
    role = copy.deepcopy(source["roles"][index])
    if role["name"] != manifest.get("role_name"):
        raise ProfileError("导入副本角色名称不匹配。")
    try:
        role, experience_conversion = experience_transfer.convert_known_mod_role(
            role, force=force_legacy_experience)
    except ValueError as error:
        raise ProfileError(str(error)) from error
    final_save = Path(launch["save_path"]).resolve()
    if destination.resolve() not in final_save.parents:
        raise ProfileError("联机存档路径越界。")
    previous_bytes: bytes | None = None
    previous: dict | None = None
    if final_save.exists():
        previous_bytes, previous = save_import.read_save(final_save)
        envelope = previous.get("_extensions", {})
        if envelope.get("configuration_id") != launch["configuration_id"] or envelope.get("save_mode") != "isolated":
            raise ProfileError("现有联机存档与固定扩展组合不匹配。")
        if any(key not in EXPECTED for key in envelope.get("states", {})):
            raise ProfileError("现有联机存档含其他扩展状态，已停止操作。")
    states = source.get("_extensions", {}).get("states", {})
    filtered = {key: copy.deepcopy(value) for key, value in states.items() if key in EXPECTED}
    provenance = {"source_sha256": manifest["source_sha256"], "role_index": index,
                  "role_name": role["name"]}
    if experience_conversion is not None:
        provenance["experience_curve_transfer"] = experience_conversion
    if mode == "append" and previous is not None:
        if len(previous["roles"]) >= 40:
            raise ProfileError("联机角色位已满（40 个），请先整理角色。")
        prior_imports = previous.get("_multiplayer_imports", [])
        if not isinstance(prior_imports, list):
            raise ProfileError("现有联机导入记录损坏。")
        if any(isinstance(entry, dict) and entry.get("source_sha256") == provenance["source_sha256"]
               and entry.get("role_index") == index for entry in prior_imports):
            raise ProfileError("这个单机角色已经导入过。")
        if any(entry.get("name") == role["name"] and entry.get("career") == role.get("career")
               for entry in previous["roles"]):
            raise ProfileError("同名同职业角色已存在；如需重置，请使用“备份后替换全部”。")
        used_slots = {int(entry.get("role_slot", -1)) for entry in previous["roles"]}
        role["role_slot"] = next(slot for slot in range(40) if slot not in used_slots)
        candidate = copy.deepcopy(previous)
        candidate["roles"].append(role)
        candidate["selected_role"] = len(candidate["roles"]) - 1
        candidate["_multiplayer_imports"] = prior_imports + [provenance]
        candidate["_extensions"]["states"].update({key: value for key, value in filtered.items()
                                                       if key not in candidate["_extensions"]["states"]})
    else:
        candidate = {"version": 1, "selected_role": 0, "roles": [role],
                     "control_mode": source.get("control_mode", 0),
                     "display_settings": source.get("display_settings", {}),
                     "online_time": source.get("online_time", {}),
                     "_multiplayer_imports": [provenance],
                     "_extensions": {"schema": 1, "configuration_id": launch["configuration_id"],
                                     "save_mode": "isolated", "framework": launch["framework"],
                                     "modules": launch["modules"], "states": filtered}}
    final_save.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".role-check-", dir=final_save.parent) as temp:
        temp_dir = Path(temp)
        test_save = temp_dir / "offline_roles.json"
        test_launch = temp_dir / "launch.json"
        _write_json(test_save, candidate)
        check_plan = dict(launch)
        check_plan["save_path"] = str(test_save)
        _write_json(test_launch, check_plan)
        engine = Path(json.loads((destination / "local.json").read_text(encoding="utf-8"))["engine"])
        args = [str(engine), "--headless", "--path", str(destination / "runtime"),
                "--log-file", str(temp_dir / "game.log"), "--", "--compat-config=" + str(test_launch),
                "--save-path=" + str(test_save), "--compat-smoke"]
        env = dict(os.environ)
        env["APPDATA"] = str(destination / ".state" / "user")
        flags = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0
        try:
            run = subprocess.run(args, capture_output=True, timeout=timeout, cwd=destination,
                                 env=env, creationflags=flags)
        except subprocess.TimeoutExpired as error:
            raise ProfileError("游戏读取角色超时。") from error
        stdout = run.stdout.decode("utf-8", errors="replace")
        stderr = run.stderr.decode("utf-8", errors="replace")
        if run.returncode != 0 or "COMPAT_SMOKE_OK" not in stdout or stderr.strip():
            raise ProfileError("游戏未能读取转换后的角色：" + (stderr or stdout)[-1200:])
        _, checked = save_import.read_save(test_save)
        if len(checked["roles"]) != len(candidate["roles"]):
            raise ProfileError("游戏未能保留全部角色，已停止导入。可能有职业不受当前游戏版本支持；现有联机存档未修改。")
        for original, migrated in zip(candidate["roles"], checked["roles"]):
            for key in ("name", "career", "level", "exp", "gold", "coupons"):
                if key in original and original[key] != migrated.get(key):
                    raise ProfileError(f"游戏改变了角色的 {key}，已停止导入；现有联机存档未修改。")
        changes = _role_changes(candidate["roles"], checked["roles"])
        if changes:
            comparison = json.dumps([candidate["roles"], checked["roles"]],
                                    ensure_ascii=False, sort_keys=True, separators=(",", ":"))
            fingerprint = hashlib.sha256(comparison.encode("utf-8")).hexdigest()
            if fingerprint != approved_adjustment_hash:
                raise RoleAdjustmentRequired(changes, fingerprint)
        if previous_bytes is not None:
            if not final_save.exists() or final_save.read_bytes() != previous_bytes:
                raise ProfileError("验证期间联机存档发生变化，已停止操作。")
            backup_hash = hashlib.sha256(previous_bytes).hexdigest()
            backup = destination / ".state" / "import_backups" / backup_hash / "offline_roles.json"
            backup.parent.mkdir(parents=True, exist_ok=True)
            if not backup.exists():
                with tempfile.NamedTemporaryFile(mode="wb", dir=backup.parent,
                                                 prefix=".backup-", delete=False) as stream:
                    stream.write(previous_bytes)
                    temporary_backup = Path(stream.name)
                os.replace(temporary_backup, backup)
            if hashlib.sha256(backup.read_bytes()).hexdigest() != backup_hash:
                raise ProfileError("旧联机存档备份校验失败，已停止操作。")
        elif final_save.exists():
            raise ProfileError("验证期间联机存档已创建，已停止覆盖。")
        os.replace(test_save, final_save)
    try:
        _write_json(stage / "converted.json", {"schema": 1, "converted_at": datetime.now(timezone.utc).isoformat(),
                                               "save_path": str(final_save), "configuration_id": launch["configuration_id"],
                                               "source_sha256": manifest["source_sha256"], "mode": mode})
    except OSError:
        pass  # The verified player save is already committed; staging metadata is optional.
    return final_save


def run_shared_scene(launch: dict, launch_path: Path, destination: Path, room_code: str,
                     room_token: str, gateway: str) -> int:
    """Run the isolated game with a room transport; caller keeps the GUI lobby alive."""
    destination = destination.resolve()
    save = Path(launch["save_path"]).resolve()
    if destination not in save.parents or not save.is_file():
        raise ProfileError("请先导入并转换一个角色。")
    if not room_code or not room_token or not gateway.startswith(("https://", "http://")):
        raise ProfileError("房间连接信息不完整。")
    engine = Path(json.loads((destination / "local.json").read_text(encoding="utf-8"))["engine"])
    if not engine.is_file():
        raise ProfileError("Godot 引擎不存在。")
    args = [str(engine), "--path", str(destination / "runtime"),
            "--log-file", str(launch_path.parent / "shared_scene.log"), "--",
            "--compat-config=" + str(launch_path), "--save-path=" + str(save),
            "--mp-room=" + room_code, "--mp-token=" + room_token,
            "--mp-gateway=" + gateway]
    env = dict(os.environ)
    env["APPDATA"] = str(destination / ".state" / "user")
    flags = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0
    compat = _compat_at(destination)
    with compat.profile_guard(compat.save_lock_path(launch)):
        process = subprocess.Popen(args, cwd=destination, env=env, creationflags=flags)
        return process.wait()


def run_solo_scene(launch: dict, launch_path: Path, destination: Path) -> int:
    """Run the isolated game in single-player practice mode (no relay, spawns a dummy)."""
    destination = destination.resolve()
    save = Path(launch["save_path"]).resolve()
    if destination not in save.parents or not save.is_file():
        raise ProfileError("请先导入并转换一个角色。")
    engine = Path(json.loads((destination / "local.json").read_text(encoding="utf-8"))["engine"])
    if not engine.is_file():
        raise ProfileError("Godot 引擎不存在。")
    args = [str(engine), "--path", str(destination / "runtime"),
            "--log-file", str(launch_path.parent / "solo_scene.log"), "--",
            "--compat-config=" + str(launch_path), "--save-path=" + str(save),
            "--mp-solo=1"]
    env = dict(os.environ)
    env["APPDATA"] = str(destination / ".state" / "user")
    flags = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0
    compat = _compat_at(destination)
    with compat.profile_guard(compat.save_lock_path(launch)):
        process = subprocess.Popen(args, cwd=destination, env=env, creationflags=flags)
        return process.wait()
