"""Convert the known v1.2.1 alternate experience curve to the base v1.45 curve.

The curves are copied from the supplied add-on ZIP and the user's original
mchGame.exe. This module never edits the source single-player save.
"""
from __future__ import annotations

from bisect import bisect_right
from copy import deepcopy

from experience_curve_data import MOD_121_CURVE, ORIGINAL_145_CURVE


def _integer(value: object) -> int | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    number = int(value)
    return number if number == value else None


def level_for(curve: tuple[int, ...], exp: int) -> int:
    return max(1, min(len(curve) - 1, bisect_right(curve, exp) - 1))


def convert_known_mod_role(role: dict, force: bool = False) -> tuple[dict, dict | None]:
    """Return a copy and conversion details only for a proven matching mod save."""
    converted = deepcopy(role)
    level = _integer(role.get("level"))
    exp = _integer(role.get("exp"))
    mode = _integer(role.get("exp_mode"))
    if role.get("_original_curve_import") == "backpack_ui_1.2.1":
        return converted, None
    if not force and mode != 1:
        return converted, None
    if level is None or exp is None or not 1 <= level < len(MOD_121_CURVE) or exp < 0 \
            or exp > MOD_121_CURVE[-1] or level_for(MOD_121_CURVE, exp) != level:
        if force:
            raise ValueError("角色等级与经验值不符合「背包与主界面 1.2.1」曲线，无法安全换算。")
        return converted, None
    if level >= len(ORIGINAL_145_CURVE):
        raise ValueError("扩展包角色等级超过原版本体的 99 级上限，无法保持等级转换。")
    if level == 1 and exp < MOD_121_CURVE[1]:
        target_exp = (exp * ORIGINAL_145_CURVE[1] + MOD_121_CURVE[1] // 2) // MOD_121_CURVE[1]
    elif level == len(ORIGINAL_145_CURVE) - 1:
        target_exp = ORIGINAL_145_CURVE[-1]
    else:
        source_low, source_high = MOD_121_CURVE[level:level + 2]
        target_low, target_high = ORIGINAL_145_CURVE[level:level + 2]
        source_width = source_high - source_low
        target_width = target_high - target_low
        if source_width <= 0 or target_width <= 0:
            raise ValueError("经验曲线数据无效。")
        progress = max(0, exp - source_low)
        target_exp = target_low + (progress * target_width + source_width // 2) // source_width
        target_exp = min(target_exp, target_high - 1)
    converted["exp"] = target_exp
    converted["exp_mode"] = 0  # The fixed multiplayer game uses the base curve.
    converted["_original_curve_import"] = "backpack_ui_1.2.1"
    return converted, {"source_curve": "backpack_ui_1.2.1", "target_curve": "base_1.45",
                       "level": level, "source_exp": exp, "target_exp": target_exp}
