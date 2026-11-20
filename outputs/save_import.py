"""Stage a single-player role for a future isolated multiplayer profile.

This module does not claim that the staged data is a playable multiplayer save.
The original save is read only and a byte-for-byte snapshot is retained so that
future conversion can be audited or retried without touching single-player data.
"""
from __future__ import annotations

import hashlib
import json
import os
import shutil
import tempfile
from datetime import datetime, timezone
from pathlib import Path

MAX_SAVE_BYTES = 64 * 1024 * 1024
ALLOWED_EXTENSIONS = frozenset({"jjxf.combat_core", "jjxf.anim_guard"})


class SaveImportError(ValueError):
    pass


def suggest_source(launcher_root: Path | None = None) -> Path:
    if launcher_root:
        settings = launcher_root / ".state" / "player_save.json"
        if settings.is_file():
            try:
                value = json.loads(settings.read_text(encoding="utf-8-sig"))
                path = Path(value["path"])
                if value.get("schema") == 1 and path.is_absolute():
                    return path
            except (OSError, ValueError, KeyError, TypeError):
                pass
    appdata = Path(os.environ.get("APPDATA", Path.home() / "AppData" / "Roaming"))
    return appdata / "Godot" / "app_userdata" / "机甲旋风 · 单机" / "offline_roles.json"


def import_directory() -> Path:
    local = Path(os.environ.get("LOCALAPPDATA", Path.home() / "AppData" / "Local"))
    return local / "JJXF_Internet_Room" / "imports"


def read_save(path: Path) -> tuple[bytes, dict]:
    try:
        size = path.stat().st_size
        if size > MAX_SAVE_BYTES:
            raise SaveImportError("存档超过 64 MB，请检查所选文件。")
        data = path.read_bytes()
    except OSError as error:
        raise SaveImportError(f"无法读取存档：{error}") from error
    if not data or len(data) > MAX_SAVE_BYTES:
        raise SaveImportError("存档为空或超过 64 MB。")
    try:
        value = json.loads(data.decode("utf-8-sig"))
    except (UnicodeError, ValueError) as error:
        raise SaveImportError("这不是可读取的 JSON 存档。") from error
    if not isinstance(value, dict) or value.get("version") != 1 or not isinstance(value.get("roles"), list):
        raise SaveImportError("存档版本或角色列表不兼容。")
    if not all(isinstance(role, dict) and isinstance(role.get("name"), str) for role in value["roles"]):
        raise SaveImportError("角色记录不完整。")
    envelope = value.get("_extensions")
    if envelope is not None and (
        not isinstance(envelope, dict) or envelope.get("schema") != 1
        or not isinstance(envelope.get("states"), dict)
        or not all(isinstance(state, dict) for state in envelope["states"].values())
    ):
        raise SaveImportError("扩展存档结构不完整。")
    return data, value


def role_summaries(value: dict) -> list[str]:
    summaries = []
    for index, role in enumerate(value["roles"]):
        name = role["name"].strip() or "未命名角色"
        level = role.get("level", "?")
        career = role.get("career", "?")
        summaries.append(f"{index + 1}. {name}  等级 {level}  职业 {career}")
    return summaries


def stage_role(source: Path, role_index: int, destination: Path | None = None,
               expected_sha256: str | None = None) -> Path:
    data, value = read_save(source)
    roles = value["roles"]
    if not isinstance(role_index, int) or isinstance(role_index, bool) or not 0 <= role_index < len(roles):
        raise SaveImportError("请选择有效角色。")
    digest = hashlib.sha256(data).hexdigest()
    if expected_sha256 is not None and digest != expected_sha256:
        raise SaveImportError("预览后单机存档发生变化，请重新读取再导入。")
    base = destination or import_directory()
    base.mkdir(parents=True, exist_ok=True)
    temp_path = Path(tempfile.mkdtemp(prefix=".staging-", dir=base))
    final_path = base / (datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + digest[:12] + "-" + str(role_index))
    if final_path.exists():
        final_path = base / (final_path.name + "-" + os.urandom(4).hex())
    try:
        (temp_path / "source_snapshot.json").write_bytes(data)
        if hashlib.sha256((temp_path / "source_snapshot.json").read_bytes()).hexdigest() != digest:
            raise SaveImportError("存档副本校验失败。")
        states = value.get("_extensions", {}).get("states", {})
        manifest = {
            "schema": 1,
            "status": "awaiting_multiplayer_runtime",
            "source_sha256": digest,
            "source_version": 1,
            "role_index": role_index,
            "role_name": roles[role_index]["name"],
            "other_extension_ids": sorted(str(key) for key in states if key not in ALLOWED_EXTENSIONS),
            "created_at": datetime.now(timezone.utc).isoformat(),
        }
        (temp_path / "import.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
        temp_path.rename(final_path)
        return final_path
    except Exception:
        shutil.rmtree(temp_path, ignore_errors=True)
        raise
