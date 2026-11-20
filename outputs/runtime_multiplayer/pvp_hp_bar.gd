extends Control

# Arena style health plate, drawn directly instead of reusing the monster boss bar.
# Layout follows the original arena HUD: head frame on the outer edge, "LV.x 名字"
# on the first line, a long gradient hp bar with current/max numbers, and a thin
# accent bar underneath. side = "left" mirrors the whole plate for the local player.

const TEXT := Color(0.93, 0.97, 1.0, 1.0)
const TEXT_NUM := Color(1.0, 1.0, 1.0, 0.95)
const BORDER := Color(0.58, 0.80, 0.98, 0.9)
const TRACK := Color(0.08, 0.12, 0.18, 0.95)
const FILL_TOP := Color(0.52, 0.88, 1.0, 1.0)
const FILL_MID := Color(0.25, 0.62, 0.98, 1.0)
const FILL_LOW := Color(0.12, 0.34, 0.82, 1.0)
const LAG_COLOR := Color(0.98, 0.99, 1.0, 0.85)
const ACCENT_TOP := Color(0.98, 0.80, 0.32, 1.0)
const ACCENT_LOW := Color(0.72, 0.50, 0.12, 1.0)

var side: String = "left"
var display_name: String = ""
var level: int = 1
var role_tag: String = ""
var slot_tag: String = ""
var current: int = 1
var maximum: int = 1
var current_mp: int = 0
var maximum_mp: int = 0
var show_accent: bool = true
var lag_ratio: float = 1.0
var _font: Font
var _box_head: StyleBoxFlat
var _box_track: StyleBoxFlat
var _box_accent: StyleBoxFlat

func _ready() -> void:
	custom_minimum_size = Vector2(300, 46)
	size = custom_minimum_size
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_font = load("res://assets/fonts/original_text.ttc")
	if _font == null:
		_font = ThemeDB.fallback_font
	_box_head = StyleBoxFlat.new()
	_box_head.bg_color = Color(0.07, 0.11, 0.17, 0.92)
	_box_head.set_corner_radius_all(4)
	_box_head.border_color = BORDER
	_box_head.set_border_width_all(1)
	_box_track = StyleBoxFlat.new()
	_box_track.bg_color = TRACK
	_box_track.set_corner_radius_all(3)
	_box_track.border_color = BORDER
	_box_track.set_border_width_all(1)
	_box_accent = StyleBoxFlat.new()
	_box_accent.bg_color = Color(0.10, 0.09, 0.05, 0.85)
	_box_accent.set_corner_radius_all(2)
	_box_accent.border_color = Color(0.55, 0.42, 0.18, 0.8)
	_box_accent.set_border_width_all(1)

func set_values(who: String, lvl: int, hp: int, max_hp: int, mp: int = 0, max_mp: int = 0) -> void:
	var changed: bool = who != display_name or lvl != level or hp != current \
		or maxi(1, max_hp) != maximum or mp != current_mp or max_mp != maximum_mp
	display_name = who
	level = lvl
	current = hp
	maximum = maxi(1, max_hp)
	current_mp = mp
	maximum_mp = max_mp
	var ratio: float = clampf(float(current) / float(maximum), 0.0, 1.0)
	if lag_ratio < ratio:
		lag_ratio = ratio
	if changed:
		queue_redraw()

func _process(delta: float) -> void:
	var ratio: float = clampf(float(current) / float(maximum), 0.0, 1.0)
	if lag_ratio > ratio:
		lag_ratio = maxf(ratio, lag_ratio - delta * 0.7)
		queue_redraw()

func _draw() -> void:
	if _box_track == null:
		return
	var w: float = size.x
	var mirrored: bool = side == "right"
	var head: Rect2 = Rect2(w - 42, 2, 38, 38) if mirrored else Rect2(4, 2, 38, 38)
	var bar_x: float = 4.0 if mirrored else 48.0
	var bar_w: float = w - 52.0
	var align: int = HORIZONTAL_ALIGNMENT_RIGHT if mirrored else HORIZONTAL_ALIGNMENT_LEFT
	draw_style_box(_box_head, head)
	if not role_tag.is_empty():
		draw_string(_font, Vector2(head.position.x, head.position.y + 16), role_tag,
			HORIZONTAL_ALIGNMENT_CENTER, head.size.x, 11, TEXT)
		draw_string(_font, Vector2(head.position.x, head.position.y + 32), slot_tag,
			HORIZONTAL_ALIGNMENT_CENTER, head.size.x, 14, FILL_TOP)
	var name_text: String = "LV.%d  %s" % [level, display_name]
	draw_string(_font, Vector2(bar_x, 13), name_text, align, bar_w, 13, TEXT)
	var track := Rect2(bar_x, 17, bar_w, 17)
	draw_style_box(_box_track, track)
	var ratio: float = clampf(float(current) / float(maximum), 0.0, 1.0)
	var lag_w: float = bar_w * clampf(lag_ratio, 0.0, 1.0)
	var fill_w: float = bar_w * ratio
	var inner_x: float = track.position.x + 1.0
	var inner_y: float = track.position.y + 1.0
	var inner_h: float = 15.0
	var lag_rect: Rect2
	var fill_rect: Rect2
	if mirrored:
		lag_rect = Rect2(inner_x + bar_w - lag_w, inner_y, lag_w, inner_h)
		fill_rect = Rect2(inner_x + bar_w - fill_w, inner_y, fill_w, inner_h)
	else:
		lag_rect = Rect2(inner_x, inner_y, lag_w, inner_h)
		fill_rect = Rect2(inner_x, inner_y, fill_w, inner_h)
	draw_rect(lag_rect, LAG_COLOR)
	if fill_w > 0.0:
		var top := Rect2(fill_rect.position, Vector2(fill_rect.size.x, 6.0))
		var mid := Rect2(fill_rect.position + Vector2(0, 6), Vector2(fill_rect.size.x, 5.0))
		var low := Rect2(fill_rect.position + Vector2(0, 11), Vector2(fill_rect.size.x, 4.0))
		draw_rect(top, FILL_TOP)
		draw_rect(mid, FILL_MID)
		draw_rect(low, FILL_LOW)
	var numbers: String = "%d/%d" % [current, maximum]
	draw_string(_font, Vector2(track.position.x, track.position.y + 13), numbers,
		HORIZONTAL_ALIGNMENT_CENTER, bar_w, 12, TEXT_NUM)
	if show_accent:
		var accent := Rect2(bar_x, 36, bar_w, 6)
		draw_style_box(_box_accent, accent)
		if maximum_mp > 0:
			var mp_ratio: float = clampf(float(current_mp) / float(maximum_mp), 0.0, 1.0)
			var mp_w: float = (bar_w - 2.0) * mp_ratio
			if mp_w > 0.0:
				var mp_x: float = accent.position.x + 1.0 + ((bar_w - 2.0) - mp_w) if mirrored else accent.position.x + 1.0
				draw_rect(Rect2(mp_x, accent.position.y + 1.0, mp_w, 4.0), ACCENT_TOP)
				draw_rect(Rect2(mp_x, accent.position.y + 3.0, mp_w, 2.0), ACCENT_LOW)
