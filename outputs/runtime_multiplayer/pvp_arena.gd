extends Node2D
## Practice-arena movement prototype. Combat is still separate work.

const WIDTH: float = 1880.0
const HEIGHT: float = 600.0
const CELL: float = 20.0
const VIEW_WIDTH: float = 940.0
const SPEED: float = 210.0
const JUMP_DURATION: float = 0.67
const JUMP_HEIGHT: float = 100.0
const RUN_MULTIPLIER: float = 1.5
const DOUBLE_TAP_MS: int = 200
const MAX_HP: int = 500000
const MAX_MP: int = 6000
const HOST_SPAWN: Vector2 = Vector2(780, 390)
const GUEST_SPAWN: Vector2 = Vector2(1100, 500)
const DamageCalculator = preload("res://scripts/flash/damage_calculator.gd")
const ScriptMovement = preload("res://scripts/flash/script_movement.gd")
const TextureCache = preload("res://scripts/texture_cache.gd")
## Knockup/knockdown tuning — matches combat_core player_hit_reaction.gd + recovery_rules.gd
const KNOCKDOWN_POWER_Y: int = 2000
const KNOCKDOWN_AIR_POWER_Y: int = 1000
const HURT_TICKS: int = 8
const DOWN_TICKS: int = 60
const REACTION_GRAVITY: int = -200
const REBOUND_MIN: float = 0.3
const REBOUND_MAX: float = 0.4
const CHAIN_LIMIT: int = 2
const CHAIN_RESET_MS: int = 5000
const CHAIN_GUARD_MS: int = 2600
## Skill casting guard: damage still applies, but the caster takes no stagger.
const SKILL_GUARD_TICKS: int = 30
## interact types that travel as a projectile vs follow the caster (skill_interact.gd)
const PROJECTILE_TYPES: Array = [3, 6, 7, 13, 17, 18, 19, 22, 20007, 20008, 20014, 30001, 40001, 20004]
const SUMMON_TYPES: Array = [14, -41001, 20001, 20003, 20009, 20010]

var walk_data: String = ""
var parallax_art: Array = []
var foreground_layer: Node2D
var fighters: Node2D
var camera: Camera2D
var local_actor: Node2D
var local_visual: Node2D
var local_shadow: Polygon2D
var local_name: Label
var remote_actor: Node2D
var remote_visual: Node2D
var remote_shadow: Polygon2D
var remote_name: Label
var target_position: Vector2 = Vector2.ZERO
var remote_avatar_fingerprint: String = ""
var remote_combat_attrs: Dictionary = {}
var remote_level: int = 1
var remote_career: int = 100
var remote_motions: Dictionary = {}
var local_jumping: bool = false
var local_jump_elapsed: float = 0.0
var remote_jumping: bool = false
var remote_jump_elapsed: float = 0.0
var last_direction_action: String = ""
var last_direction_ms: int = -1000
var run_action: String = ""
var running_latched: bool = false
var run_idle_elapsed: float = 0.0
var attacking: bool = false
var attack_frame_elapsed: float = 0.0
var attack_stage: int = 0
var air_attack: bool = false
var remote_attacking: bool = false
var remote_attack_frame_elapsed: float = 0.0
var remote_attack_stage: int = -1
var remote_air_attack: bool = false
var active_skill_id: int = 0
var remote_skill_id: int = 0
var local_skill_fallback: bool = false
var remote_skill_fallback: bool = false
var local_skill_elapsed: float = 0.0
var remote_skill_elapsed: float = 0.0
var local_skill_duration: float = 0.0
var remote_skill_duration: float = 0.0
var local_mp: int = MAX_MP
var mp_label: Label
var cooldowns: Dictionary = {}
var local_reaction_clock: float = 0.0
var remote_reaction_clock: float = 0.0
var local_action: RefCounted
var remote_action: RefCounted
var combo_timeline: RefCounted = preload("res://scripts/flash/frame_timeline.gd").new()
var combo_hit_count: int = 0
var local_hit_window: bool = false
var remote_hit_window: bool = false
var local_hp: int = MAX_HP
var remote_hp: int = MAX_HP
var local_hp_label: Label
var remote_hp_label: Label
var attack_hit_done: bool = false
var remote_hit_done: bool = false
var combat_id: int = 0
var last_combat_id: int = 0
var local_reaction_time: float = 0.0
var remote_reaction_time: float = 0.0
var local_reaction_kind: String = ""
var remote_reaction_kind: String = ""
var local_reaction_total: float = 0.0
var remote_reaction_total: float = 0.0
var local_impulse: int = 1
var remote_impulse: int = 1
var hp_art: TextureRect
var mp_art: TextureRect
var hp_frames: Array = []
var mp_frames: Array = []
var local_react: Dictionary = {}
var remote_react: Dictionary = {}
var local_chain: Dictionary = {}
var remote_chain: Dictionary = {}
var battle_ticks: int = 0
var battle_tick_clock: float = 0.0
var local_skill_guard_tick: int = -99999
var remote_skill_guard_tick: int = -99999
var projectiles: Array = []
var summons: Array = []
var script_movement = preload("res://scripts/flash/script_movement.gd").new()
var arena_effects: Array = []
var local_buff: Dictionary = {}
var remote_buff: Dictionary = {}
var orb_tex: Texture2D
var dummy_respawn_elapsed: float = 0.0
var dummy_attack_enabled: bool = false
var dummy_attack_elapsed: float = 0.0
var solo_hint: Label


func _ready() -> void:
	_build_stage()
	orb_tex = _make_orb_texture()
	fighters = Node2D.new()
	fighters.y_sort_enabled = true
	add_child(fighters)
	local_actor = Node2D.new()
	local_actor.name = "LocalFighter"
	fighters.add_child(local_actor)
	local_shadow = _shadow()
	local_actor.add_child(local_shadow)
	local_visual = load("res://scripts/avatar_view.gd").new()
	local_actor.add_child(local_visual)
	local_visual.scale = Vector2.ONE * (160.0 / 151.0)
	local_visual.configure(_safe_appearance(Game.role()))
	local_name = _name_label(str(Game.role().get("name", "玩家")), Color(1.0, 0.8, 0.45))
	local_actor.add_child(local_name)
	remote_actor = Node2D.new()
	remote_actor.name = "RemoteFighter"
	remote_actor.visible = false
	fighters.add_child(remote_actor)
	remote_shadow = _shadow()
	remote_actor.add_child(remote_shadow)
	remote_visual = load("res://scripts/avatar_view.gd").new()
	remote_actor.add_child(remote_visual)
	remote_visual.scale = Vector2.ONE * (160.0 / 151.0)
	remote_name = _name_label("对方玩家", Color(0.5, 0.85, 1.0))
	remote_actor.add_child(remote_name)
	local_action = load("res://scripts/flash/action_player.gd").new()
	local_action.configure(Game.flash_actions, Game.slice_data.motions)
	local_action.state_started.connect(_on_local_action_state)
	local_action.frame_event.connect(_on_local_action_event)
	local_action.finished.connect(_on_local_action_finished)
	local_action.script_requested.connect(_on_local_action_script)
	remote_action = load("res://scripts/flash/action_player.gd").new()
	remote_action.configure(Game.flash_actions, Game.slice_data.motions)
	remote_action.frame_event.connect(_on_remote_action_event)
	remote_action.script_requested.connect(_on_remote_action_script)
	add_child(foreground_layer)
	camera = Camera2D.new()
	camera.limit_left = 0
	camera.limit_right = int(WIDTH)
	camera.limit_top = 0
	camera.limit_bottom = int(HEIGHT) + 60
	add_child(camera)
	camera.make_current()
	_build_hud()
	_set_spawn()
	PeerSync.role_ready.connect(_set_spawn)
	PeerSync.peer_state_received.connect(_on_peer_state)
	PeerSync.peer_disconnected.connect(_on_peer_left)
	PeerSync.combat_received.connect(_on_combat)
	if not PeerSync.peer_state.is_empty():
		_on_peer_state(PeerSync.peer_state)
	print("PVP_ARENA_READY")


func _build_stage() -> void:
	foreground_layer = Node2D.new()
	var decoded: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://data/training_arena.json"))
	if not decoded is Dictionary or not decoded.get("room") is Dictionary:
		push_error("PvP arena could not load the original practice room")
		return
	var room: Dictionary = decoded.room
	walk_data = str(room.get("walk_data", ""))
	var background_layer := Node2D.new()
	add_child(background_layer)
	for value in room.get("art", []):
		if not value is Dictionary:
			continue
		var item: Dictionary = value
		var texture: Texture2D = load("res://" + str(item.get("path", ""))) as Texture2D
		if texture == null:
			continue
		var sprite := Sprite2D.new()
		sprite.centered = false
		sprite.texture = texture
		sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		sprite.position = Vector2(float(item.get("x", 0)), float(item.get("z", 0)))
		for property in item.get("properties", []):
			match str(property.get("type", "")):
				"FlipX":
					sprite.scale.x = float(property.get("value", -1))
				"MoveFollowCameraX":
					parallax_art.append({"sprite": sprite, "start": float(property.get("start", 0)),
						"end": float(property.get("end", 0)), "axis": "x"})
				"MoveFollowCameraY":
					parallax_art.append({"sprite": sprite, "start": float(property.get("start", 0)),
						"end": float(property.get("end", 0)), "axis": "y"})
		if str(item.get("layer", "")) == "ForegroundLayer":
			foreground_layer.add_child(sprite)
		else:
			background_layer.add_child(sprite)
	if walk_data.length() != int(WIDTH / CELL) * int(HEIGHT / CELL):
		push_error("PvP arena walk grid does not match original room dimensions")
	print("PVP_PRACTICE_STAGE_READY")


func _build_hud() -> void:
	var hud := CanvasLayer.new()
	hud.layer = 20
	hud.follow_viewport_enabled = false
	add_child(hud)
	var bottom := TextureRect.new()
	bottom.texture = load("res://assets/ui/original/hud_progress/bottom.png")
	bottom.position = Vector2(0, 435)
	bottom.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(bottom)
	var vitals: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/hud_progress_ui.json"))
	_hud_art(hud, vitals.vitals_base)
	hp_frames.clear()
	mp_frames.clear()
	for frame in vitals.hp_frames:
		hp_frames.append({"texture": load("res://" + str(frame.path)), "rect": frame.rect})
	for frame in vitals.mp_frames:
		mp_frames.append({"texture": load("res://" + str(frame.path)), "rect": frame.rect})
	hp_art = _hud_art(hud, vitals.hp_frames.back())
	mp_art = _hud_art(hud, vitals.mp_frames.back())
	_hud_art(hud, vitals.vitals_glass)
	local_hp_label = _hud_label(hud, "HP %d/%d" % [local_hp, MAX_HP], Vector2(103, 462), 13)
	local_hp_label.add_theme_color_override("font_color", Color(1.0, 0.83, 0.72))
	mp_label = _hud_label(hud, "MP %d/%d" % [local_mp, MAX_MP], Vector2(103, 481), 13)
	mp_label.add_theme_color_override("font_color", Color(0.65, 0.88, 1.0))
	var bar: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/skill_bar_ui.json"))
	for field in bar.get("graphics", {}).values():
		_hud_art(hud, field)
	for index in mini(Game.SKILL_SLOT_COUNT, bar.slots.size()):
		var skill_id := Game.skill_in_slot(index)
		var icon_path := str(Game.skill_data.icons.get(str(skill_id / 100), ""))
		var slot: Dictionary = bar.slots[index]
		var point := Vector2(float(slot.position[0]), float(slot.position[1]))
		if not icon_path.is_empty():
			var icon := TextureRect.new()
			icon.texture = load("res://" + icon_path)
			icon.position = point
			icon.size = Vector2(float(slot.size[0]), float(slot.size[1]))
			icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
			hud.add_child(icon)
		_hud_label(hud, Controls.slot_key(index), point + Vector2(20, 25), 11)
	var backing := ColorRect.new()
	backing.color = Color(0.02, 0.04, 0.08, 0.64)
	backing.position = Vector2.ZERO
	backing.size = Vector2(940, 78)
	hud.add_child(backing)
	remote_hp_label = _hud_label(hud, "对方 HP %d/%d" % [remote_hp, MAX_HP], Vector2(720, 10), 13)
	var title := Label.new()
	title.text = "双人 PvP · 技能动作与受击测试"
	title.position = Vector2(25, 10)
	title.add_theme_font_size_override("font_size", 22)
	hud.add_child(title)
	var note := Label.new()
	note.text = "双击方向奔跑；%s 跳跃；%s 普攻；按下方技能键测试已装备技能" % [Controls.key_name("jump"), Controls.key_name("attack")]
	note.position = Vector2(25, 44)
	note.add_theme_font_size_override("font_size", 14)
	hud.add_child(note)
	if PeerSync.solo:
		solo_hint = _hud_label(hud, "单人练习：木桩在右侧，按 V 切换反击", Vector2(25, 66), 14)
		solo_hint.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4))


func _hud_art(parent: Node, field: Dictionary) -> TextureRect:
	var art := TextureRect.new()
	art.texture = load("res://" + str(field.path))
	art.position = Vector2(float(field.rect[0]), float(field.rect[1]))
	art.size = Vector2(float(field.rect[2]), float(field.rect[3]))
	art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(art)
	return art


func _hud_label(parent: Node, value: String, point: Vector2, size: int) -> Label:
	var label := Label.new()
	label.text = value
	label.position = point
	label.add_theme_font_size_override("font_size", size)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(label)
	return label


func _shadow() -> Polygon2D:
	var value := Polygon2D.new()
	value.color = Color(0, 0, 0, 0.3)
	value.polygon = PackedVector2Array([Vector2(-20, 0), Vector2(-14, -5), Vector2(14, -5),
		Vector2(20, 0), Vector2(14, 5), Vector2(-14, 5)])
	return value


func _name_label(value: String, color: Color) -> Label:
	var label := Label.new()
	label.text = value.substr(0, 30)
	label.position = Vector2(-100, -190)
	label.size = Vector2(200, 25)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_color_override("font_color", color)
	label.add_theme_font_size_override("font_size", 15)
	return label


func _safe_appearance(value: Dictionary) -> Dictionary:
	var result := {"career": int(value.get("career", 0)),
		"career_wear_level": int(value.get("career_wear_level", 1)),
		"has_join": bool(value.get("has_join", false)),
		"sublime": bool(value.get("sublime", false)),
		"equipment": [], "appearance": {}}
	var equipment: Array = value.get("equipment", []) if value.get("equipment", []) is Array else []
	if equipment.size() == 16:
		result.equipment = equipment.duplicate()
		for slot in [0, 1, 10]:
			if not Game.equipment_data.catalog.has(str(int(result.equipment[slot]))):
				result.equipment[slot] = 0
	var appearance: Dictionary = value.get("appearance", {}) if value.get("appearance", {}) is Dictionary else {}
	for slot in ["0", "1", "10"]:
		if appearance.has(slot) and Game.equipment_data.catalog.has(str(int(appearance[slot]))):
			result.appearance[slot] = int(appearance[slot])
	return result


func _set_spawn() -> void:
	if not is_instance_valid(local_actor):
		return
	var guest := PeerSync.my_role == "guest"
	local_actor.position = GUEST_SPAWN if guest else HOST_SPAWN
	local_visual.set_motion(3, guest)
	local_jumping = false
	local_jump_elapsed = 0.0
	run_action = ""
	running_latched = false
	run_idle_elapsed = 0.0
	attacking = false
	attack_stage = 0
	air_attack = false
	attack_hit_done = false
	local_hit_window = false
	remote_hit_window = false
	local_reaction_time = 0.0
	remote_reaction_time = 0.0
	local_react = {}
	remote_react = {}
	local_chain = {}
	remote_chain = {}
	local_skill_guard_tick = -99999
	remote_skill_guard_tick = -99999
	battle_ticks = 0
	battle_tick_clock = 0.0
	projectiles.clear()
	summons.clear()
	if is_instance_valid(local_buff.get("aura")):
		local_buff.aura.queue_free()
	local_buff = {}
	if is_instance_valid(remote_buff.get("aura")):
		remote_buff.aura.queue_free()
	remote_buff = {}
	local_hp = MAX_HP
	remote_hp = MAX_HP
	local_mp = MAX_MP
	active_skill_id = 0
	remote_skill_id = 0
	local_skill_fallback = false
	remote_skill_fallback = false
	_update_hp_labels()
	_set_actor_height(local_visual, local_name, local_shadow, 0.0)
	if PeerSync.solo:
		_setup_solo_dummy()
	_update_camera()


func _walkable(point: Vector2) -> bool:
	if point.x < 0 or point.y < 0 or point.x >= WIDTH or point.y >= HEIGHT:
		return false
	var column := int(floorf(point.x / CELL))
	var row := int(floorf(point.y / CELL))
	var index := row * int(WIDTH / CELL) + column
	return index >= 0 and index < walk_data.length() and walk_data.substr(index, 1) == "1"


func _move_on_ground(direction: Vector2, delta: float, running: bool) -> void:
	var step := direction * SPEED * (RUN_MULTIPLIER if running else 1.0) * delta
	var next_x := local_actor.position + Vector2(step.x, 0)
	if _walkable(next_x):
		local_actor.position.x = next_x.x
	var next_y := local_actor.position + Vector2(0, step.y)
	if _walkable(next_y):
		local_actor.position.y = next_y.y


func _apply_script_movement() -> void:
	var destination: Vector2 = script_movement.advance(local_actor.position)
	if destination == local_actor.position:
		return
	var next_x := Vector2(destination.x, local_actor.position.y)
	if _walkable(next_x):
		local_actor.position.x = destination.x
	var next_y := Vector2(local_actor.position.x, destination.y)
	if _walkable(next_y):
		local_actor.position.y = destination.y


func _jump_height(elapsed: float) -> float:
	var phase := clampf(elapsed / JUMP_DURATION, 0.0, 1.0)
	return 4.0 * JUMP_HEIGHT * phase * (1.0 - phase)


func _set_actor_height(visual: Node2D, label: Label, shadow: Polygon2D, height: float) -> void:
	visual.position.y = -height
	label.position.y = -190.0 - height
	shadow.scale = Vector2.ONE * clampf(1.0 - height / 200.0, 0.45, 1.0)


func _update_camera() -> void:
	if not is_instance_valid(camera):
		return
	camera.position = Vector2(clampf(local_actor.position.x, VIEW_WIDTH * 0.5,
		WIDTH - VIEW_WIDTH * 0.5), clampf(local_actor.position.y - 100.0, 330.0, 380.0))
	var camera_x := camera.position.x - VIEW_WIDTH * 0.5
	var camera_y := camera.position.y - 280.0
	for entry in parallax_art:
		var sprite: Sprite2D = entry.sprite
		if str(entry.axis) == "x":
			sprite.position.x = camera_x * (float(entry.end) - float(entry.start)) / (WIDTH - VIEW_WIDTH) + float(entry.start)
		else:
			sprite.position.y = camera_y * (float(entry.end) - float(entry.start)) / (HEIGHT - 560.0) + float(entry.start)


func _physics_process(delta: float) -> void:
	battle_tick_clock += delta * 30.0
	while battle_tick_clock >= 1.0:
		battle_tick_clock -= 1.0
		battle_ticks += 1
	for skill in cooldowns.keys():
		cooldowns[skill] = maxf(0.0, float(cooldowns[skill]) - delta)
	local_hit_window = false
	remote_hit_window = false
	if Input.is_action_just_pressed("jump") and not local_jumping and not attacking and local_reaction_time <= 0.0:
		local_jumping = true
		local_jump_elapsed = 0.0
	var direction := Input.get_vector("move_left", "move_right", "move_up", "move_down")
	if direction == Vector2.ZERO:
		run_idle_elapsed += delta
		if run_idle_elapsed > 0.15:
			running_latched = false
			run_action = ""
	else:
		run_idle_elapsed = 0.0
	var running := (InputMap.has_action("run") and Input.is_action_pressed("run")) or running_latched
	if not attacking and local_reaction_time <= 0.0 and local_hp > 0:
		_move_on_ground(direction, delta, running)
	if direction.x != 0:
		local_visual.facing_left = direction.x < 0
	if attacking:
		attack_frame_elapsed += delta * 30.0
		if local_skill_fallback:
			local_skill_elapsed += delta
			if not _is_direction_combo(active_skill_id) and local_skill_elapsed >= 0.16 and local_skill_elapsed <= 0.34:
				local_hit_window = true
		while attack_frame_elapsed >= 1.0:
			attack_frame_elapsed -= 1.0
			if not local_skill_fallback:
				local_action.advance()
			elif _is_direction_combo(active_skill_id):
				_drive_direction_combo()
			if not attacking:
				break
			_apply_script_movement()
			local_visual.advance_action_motion()
		if local_skill_fallback and local_skill_elapsed >= local_skill_duration:
			_on_local_action_finished(-1)
		if local_jumping:
			local_jump_elapsed += delta
			_set_actor_height(local_visual, local_name, local_shadow, _jump_height(local_jump_elapsed))
			if local_jump_elapsed >= JUMP_DURATION:
				local_jumping = false
	elif local_jumping:
		local_jump_elapsed += delta
		var height := _jump_height(local_jump_elapsed)
		_set_actor_height(local_visual, local_name, local_shadow, height)
		local_visual.set_motion(5, local_visual.facing_left)
		if local_jump_elapsed >= JUMP_DURATION:
			local_jumping = false
			_set_actor_height(local_visual, local_name, local_shadow, 0.0)
	elif local_reaction_time <= 0.0:
		local_visual.set_motion((2 if running else 1) if direction != Vector2.ZERO else 3, local_visual.facing_left)
	if remote_actor.visible:
		remote_actor.position = remote_actor.position.lerp(target_position, clampf(delta * 12.0, 0.0, 1.0))
		if remote_jumping:
			remote_jump_elapsed = minf(remote_jump_elapsed + delta, JUMP_DURATION)
			_set_actor_height(remote_visual, remote_name, remote_shadow, _jump_height(remote_jump_elapsed))
		if remote_attacking:
			remote_attack_frame_elapsed += delta * 30.0
			if remote_skill_fallback:
				remote_skill_elapsed += delta
				if remote_skill_elapsed >= 0.16 and remote_skill_elapsed <= 0.34:
					remote_hit_window = true
			while remote_attack_frame_elapsed >= 1.0:
				remote_attack_frame_elapsed -= 1.0
				if not remote_skill_fallback:
					remote_action.advance()
				remote_visual.advance_action_motion()
			if remote_skill_fallback and remote_skill_elapsed >= remote_skill_duration:
				remote_attacking = false
				remote_skill_fallback = false
				remote_visual.end_action_motion()
	_update_reactions(delta)
	_update_effects(delta)
	if PeerSync.solo:
		_update_solo_dummy(delta)
	if PeerSync.my_role == "host" and remote_actor.visible:
		_judge_hits()
	_update_camera()


func snapshot() -> Dictionary:
	return {"x": local_actor.position.x, "y": local_actor.position.y,
		"facing_left": bool(local_visual.facing_left),
		"motion": (10 if active_skill_id > 0 else 9 if air_attack else (4 if attack_stage == 0 else attack_stage + 5)) if attacking else int(local_visual.motion),
		"skill": active_skill_id if attacking else 0, "stage": attack_stage if attacking else 0}


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_pressed() or event.is_echo():
		return
	if PeerSync.solo and event is InputEventKey:
		var key_event := event as InputEventKey
		if key_event.physical_keycode == KEY_V:
			dummy_attack_enabled = not dummy_attack_enabled
			dummy_attack_elapsed = 0.0
			_solo_hint_update()
			get_viewport().set_input_as_handled()
			return
	if event.is_action_pressed("attack"):
		_start_attack()
		get_viewport().set_input_as_handled()
		return
	for index in Game.SKILL_SLOT_COUNT:
		if event.is_action_pressed(Controls.SKILL_ACTIONS[index]):
			_start_skill(index)
			get_viewport().set_input_as_handled()
			return
	for action in ["move_left", "move_right", "move_up", "move_down"]:
		if event.is_action_pressed(action):
			var now := Time.get_ticks_msec()
			if action == last_direction_action and now - last_direction_ms <= DOUBLE_TAP_MS:
				run_action = action
				running_latched = true
			last_direction_action = action
			last_direction_ms = now
			return


func _start_attack() -> void:
	if local_reaction_time > 0.0 or local_hp <= 0:
		return
	if attacking:
		if not air_attack and active_skill_id == 0:
			if _direction_held():
				_start_direction_combo()
			else:
				local_action.input_vkey(11)
		return
	attacking = true
	active_skill_id = 0
	local_skill_fallback = false
	air_attack = local_jumping
	attack_stage = 0
	script_movement.reset()
	var career := int(Game.role().get("career", 100))
	var base := Game.base_career(career)
	var skill_id := int(Game.career_combat.get("normal_skills", {}).get(str(base), 4))
	if air_attack:
		skill_id = _air_skill_for_career(career)
	elif _is_running():
		var strike_id := int(Game.career_combat.get("strike_skills", {}).get(str(base), 0))
		if strike_id > 0 and not Game.slice_data.skills.get(str(strike_id), {}).is_empty() and float(cooldowns.get(strike_id, 0.0)) <= 0.0:
			skill_id = strike_id
			active_skill_id = strike_id
			cooldowns[strike_id] = 1.0
	var spec: Dictionary = Game.slice_data.skills.get(str(skill_id), {})
	if spec.is_empty() or not local_action.begin(career, int(spec.get("action", 0))):
		attacking = false
		air_attack = false
		active_skill_id = 0
		return
	if active_skill_id > 0:
		local_skill_guard_tick = battle_ticks


func _is_running() -> bool:
	return (InputMap.has_action("run") and Input.is_action_pressed("run")) or running_latched


func _direction_held() -> bool:
	return Input.get_vector("move_left", "move_right", "move_up", "move_down").x != 0.0


func _air_skill_for_career(career: int) -> int:
	var skills: Dictionary = Game.career_combat.get("air_skills", {}).get(str(Game.base_career(career)), {})
	for vkey in [17, 24]:
		var skill_id := int(skills.get(str(vkey), 0))
		if skill_id > 0 and Game.slice_data.skills.has(str(skill_id)):
			return skill_id
	return 0


func _direction_combo_skill_id() -> int:
	var career := int(Game.role().get("career", 100))
	var base := Game.base_career(career)
	var combos: Array = Game.career_combat.get("normal_followups", {}).get(str(base), [])
	for value in combos:
		var spec: Dictionary = Game.slice_data.skills.get(str(int(value)), {})
		if spec.get("hits", []).is_empty():
			continue
		# The extension marks native direction combos with learn_type 2 (一键连击).
		if int(spec.get("learn_type", 0)) == 2 or str(spec.get("instruction", "")).contains("方向"):
			return int(value)
	return 0


func _is_direction_combo(skill_id: int) -> bool:
	return skill_id > 0 and skill_id == _direction_combo_skill_id()


func _combo_duration(skill_id: int) -> float:
	var spec: Dictionary = Game.slice_data.skills.get(str(skill_id), {})
	var motion: Dictionary = Game.slice_data.motions.get(str(int(spec.get("action", 0))), {})
	var duration := int(motion.get("duration", 0))
	return float(duration) / 30.0 if duration > 0 else 1.5


func _combo_render_motion(skill_id: int) -> int:
	var spec: Dictionary = Game.slice_data.skills.get(str(skill_id), {})
	var action := int(spec.get("action", 0))
	if _visual_has_motion(local_visual, action):
		return action
	var career := int(Game.role().get("career", 100))
	var base := Game.base_career(career)
	var normal_id := int(Game.career_combat.get("normal_skills", {}).get(str(base), 4))
	var normal_spec: Dictionary = Game.slice_data.skills.get(str(normal_id), {})
	var state: Dictionary = Game.flash_actions.state(career, int(normal_spec.get("action", 0)), 0)
	return int(state.get("motion_id", 4))


func _start_direction_combo() -> void:
	var skill_id := _direction_combo_skill_id()
	if skill_id <= 0:
		return
	var spec: Dictionary = Game.slice_data.skills.get(str(skill_id), {})
	var hits: Array = spec.get("hits", [])
	if hits.is_empty():
		return
	local_action.stop()
	attacking = true
	active_skill_id = skill_id
	air_attack = false
	script_movement.reset()
	local_skill_fallback = true
	local_skill_elapsed = 0.0
	attack_stage = 0
	attack_hit_done = false
	local_skill_duration = _combo_duration(skill_id)
	var motion: Dictionary = Game.slice_data.motions.get(str(int(spec.get("action", 0))), {})
	if motion.get("frames", []).is_empty():
		_on_local_action_finished(-1)
		return
	combo_timeline.configure(motion.frames, 1.0, 0.0)
	combo_hit_count = 0
	local_visual.begin_action_motion(_combo_render_motion(skill_id), 0)
	# Direction combos are normal attacks and have no blanket casting guard.


func _drive_direction_combo() -> void:
	var packet: Dictionary = combo_timeline.step()
	if packet.is_empty():
		return
	var hits: Array = Game.slice_data.skills.get(str(active_skill_id), {}).get("hits", [])
	if not hits.is_empty():
		attack_stage = mini(int(float(packet.index) / maxf(1.0, float(combo_timeline.frames.size())) * hits.size()), hits.size() - 1)
	if str(packet.get("event", "")) == "hit":
		attack_hit_done = false
		local_hit_window = true
		combo_hit_count += 1
	for script in packet.get("scripts", []):
		if script is Dictionary:
			_on_local_action_script(str(script.get("cmd", "")), script.get("args", {}))


func _start_skill(index: int) -> void:
	if attacking or local_jumping or local_reaction_time > 0.0 or local_hp <= 0:
		return
	var skill_id := int(Game.skill_in_slot(index))
	if skill_id <= 0 or not Game.has_skill(skill_id):
		return
	var spec: Dictionary = Game.slice_data.skills.get(str(skill_id), {})
	if spec.is_empty() or spec.get("hits", []).is_empty():
		return
	var cost := int(spec.hits[0].get("mana", 0))
	if local_mp < cost or float(cooldowns.get(skill_id, 0.0)) > 0.0:
		return
	var career := int(Game.role().get("career", 100))
	var state: Dictionary = Game.flash_actions.state(career, int(spec.get("action", 0)), 0)
	var motion_id := int(state.get("motion_id", -1))
	if not _visual_has_motion(local_visual, motion_id):
		return
	local_skill_fallback = not Game.slice_data.motions.has(str(motion_id))
	if local_skill_fallback:
		local_visual.begin_action_motion(motion_id, int(state.get("frame_index", 0)))
		local_skill_elapsed = 0.0
		local_skill_duration = _visual_motion_duration(local_visual, motion_id)
	else:
		if not local_action.begin(career, int(spec.get("action", 0))):
			return
	attacking = true
	air_attack = false
	active_skill_id = skill_id
	script_movement.reset()
	local_skill_guard_tick = battle_ticks
	local_mp -= cost
	cooldowns[skill_id] = maxf(0.0, float(spec.get("cooldown", 0)) / 30.0)
	_update_hp_labels()
	_spawn_skill_effect(skill_id, local_actor.position, local_visual.facing_left, "local")


func _visual_has_motion(visual: Node2D, motion_id: int) -> bool:
	for part in visual.parts:
		if part.motions.has(str(motion_id)):
			return true
	return false


func _visual_motion_duration(visual: Node2D, motion_id: int) -> float:
	var ticks := 0
	for part in visual.parts:
		var frames: Array = part.motions.get(str(motion_id), [])
		var total := 0
		for frame in frames:
			total += maxi(1, int(frame.get("ticks", 1)))
		ticks = maxi(ticks, total)
	return clampf(float(ticks) / 30.0, 0.4, 3.0)


func _attack_state(career: int, stage: int, airborne: bool, selected_skill: int = 0) -> Dictionary:
	var base := Game.base_career(career)
	var skill_id := selected_skill if selected_skill > 0 else int(Game.career_combat.get("normal_skills", {}).get(str(base), 4))
	if airborne and selected_skill == 0:
		skill_id = _air_skill_for_career(career)
	var spec: Dictionary = Game.slice_data.skills.get(str(skill_id), {})
	if spec.is_empty():
		return {}
	var state: Dictionary = Game.flash_actions.state(career, int(spec.get("action", 0)), 0)
	if stage != 0:
		state = Game.flash_actions.state(career, int(spec.get("action", 0)), stage)
	var motions: Dictionary = Game.slice_data.motions if career == int(Game.role().get("career", 100)) else remote_motions
	return state if selected_skill > 0 or motions.has(str(int(state.get("motion_id", -1)))) else {}


func _on_local_action_state(stage: int, motion_id: int, frame_index: int) -> void:
	attack_stage = stage
	attack_hit_done = false
	local_visual.begin_action_motion(motion_id, frame_index)


func _on_local_action_event(event: String, _frame: Dictionary) -> void:
	if event == "hit":
		local_hit_window = true


func _on_remote_action_event(event: String, _frame: Dictionary) -> void:
	if event == "hit":
		remote_hit_window = true


func _on_local_action_script(command: String, args: Dictionary) -> void:
	match command:
		"move":
			var facing := -1 if local_visual.facing_left else 1
			var held := {2: Input.is_action_pressed("move_left"), 3: Input.is_action_pressed("move_right")}
			script_movement.execute(args, facing, held, int(SPEED / 30.0 * 100.0))
		"createEffect":
			_spawn_effect(local_actor, args, "local")
		"createInteract":
			_spawn_interact(args, active_skill_id, "local")


func _on_remote_action_script(command: String, args: Dictionary) -> void:
	match command:
		"createEffect":
			_spawn_effect(remote_actor, args, "remote")
		"createInteract":
			_spawn_interact(args, remote_skill_id, "remote")


func _on_local_action_finished(_next_vkey: int) -> void:
	attacking = false
	active_skill_id = 0
	local_skill_fallback = false
	script_movement.reset()
	local_visual.end_action_motion()


func _on_peer_state(value: Dictionary) -> void:
	if int(value.get("map", -1)) != PeerSync.ARENA_ID:
		return
	target_position = Vector2(float(value.get("x", 0)), float(value.get("y", 0)))
	if not remote_actor.visible:
		remote_actor.position = target_position
		remote_actor.visible = true
		print("PVP_PEER_VISIBLE")
	var avatar: Dictionary = value.get("avatar", {}) if value.get("avatar", {}) is Dictionary else {}
	var fingerprint := JSON.stringify(avatar)
	if not avatar.is_empty() and fingerprint != remote_avatar_fingerprint:
		remote_avatar_fingerprint = fingerprint
		remote_combat_attrs = avatar.get("combat_attrs", {}) if avatar.get("combat_attrs", {}) is Dictionary else {}
		remote_level = int(avatar.get("level", 1))
		remote_career = int(avatar.get("career", 100))
		remote_motions = Game.slice_data.motions.duplicate()
		remote_motions.merge(Game.career_combat.get("career_motions", {}).get(str(Game.base_career(remote_career)), {}), true)
		remote_action.configure(Game.flash_actions, remote_motions)
		remote_visual.configure(_safe_appearance(avatar))
		remote_name.text = str(avatar.get("name", "对方玩家")).substr(0, 30)
	if remote_reaction_time > 0.0:
		return
	var motion := clampi(int(value.get("motion", 3)), 0, 10)
	var incoming_skill := int(value.get("skill", 0)) if motion == 10 else 0
	var new_stage := -1
	if motion == 4 or motion == 9:
		new_stage = 0
	elif motion in [6, 7, 8]:
		new_stage = motion - 5
	elif motion == 10 and incoming_skill > 0:
		new_stage = clampi(int(value.get("stage", 0)), 0, 10)
	var new_air := motion == 9
	if new_stage >= 0 and (not remote_attacking or new_stage != remote_attack_stage or new_air != remote_air_attack or incoming_skill != remote_skill_id):
		var state := _attack_state(int(avatar.get("career", 100)), new_stage, new_air, incoming_skill)
		if not state.is_empty():
			var career := int(avatar.get("career", 100))
			var base := Game.base_career(career)
			var skill_id := incoming_skill if incoming_skill > 0 else int(Game.career_combat.get("normal_skills", {}).get(str(base), 4))
			if new_air and incoming_skill == 0:
				skill_id = _air_skill_for_career(career)
			var spec: Dictionary = Game.slice_data.skills.get(str(skill_id), {})
			remote_skill_fallback = incoming_skill > 0 and not remote_motions.has(str(int(state.motion_id)))
			if remote_skill_fallback:
				remote_skill_elapsed = 0.0
				remote_skill_duration = _visual_motion_duration(remote_visual, int(state.motion_id))
			elif not spec.is_empty():
				remote_action.begin(career, int(spec.get("action", 0)))
				if new_stage > 0:
					remote_action.set_state(new_stage)
			remote_visual.facing_left = bool(value.get("facing_left", false))
			if not remote_attacking and incoming_skill > 0 and not _is_direction_combo(incoming_skill):
				remote_skill_guard_tick = battle_ticks
			remote_attacking = true
			remote_attack_stage = new_stage
			remote_air_attack = new_air
			remote_skill_id = incoming_skill
			remote_attack_frame_elapsed = 0.0
			remote_hit_done = false
			if incoming_skill > 0 and (not remote_attacking or incoming_skill != remote_skill_id):
				_spawn_skill_effect(incoming_skill, target_position, bool(value.get("facing_left", false)), "remote")
			remote_visual.begin_action_motion(int(state.motion_id), int(state.get("frame_index", 0)))
	elif new_stage < 0 and remote_attacking:
		remote_attacking = false
		remote_action.stop()
		remote_attack_stage = -1
		remote_air_attack = false
		remote_skill_id = 0
		remote_skill_fallback = false
		remote_visual.end_action_motion()
	if motion in [5, 9] and not remote_jumping:
		remote_jumping = true
		remote_jump_elapsed = 0.0
	elif motion not in [5, 9] and remote_jumping:
		remote_jumping = false
		_set_actor_height(remote_visual, remote_name, remote_shadow, 0.0)
	if new_stage < 0:
		remote_visual.set_motion(motion, bool(value.get("facing_left", false)))


func _on_peer_left() -> void:
	remote_actor.visible = false
	remote_jumping = false
	remote_jump_elapsed = 0.0
	remote_attacking = false
	remote_attack_stage = -1
	remote_air_attack = false
	remote_skill_id = 0
	remote_visual.end_action_motion()


func _judge_hits() -> void:
	if attacking and local_hit_window and not attack_hit_done:
		if remote_hp > 0 and _in_reach(local_actor.position, target_position, local_visual.facing_left, active_skill_id, attack_stage, air_attack, int(Game.role().get("career", 100))):
			attack_hit_done = true
			_register_hit("guest", attack_stage, air_attack, local_visual.facing_left, active_skill_id)
	if remote_attacking and remote_hit_window and not remote_hit_done:
		if local_hp > 0 and _in_reach(target_position, local_actor.position, remote_visual.facing_left, remote_skill_id, remote_attack_stage, remote_air_attack, remote_career):
			remote_hit_done = true
			_register_hit("host", remote_attack_stage, remote_air_attack, remote_visual.facing_left, remote_skill_id)


func _in_reach(origin: Vector2, target: Vector2, facing_left: bool, skill_id: int, stage: int, airborne: bool, career: int) -> bool:
	var reach: Array = _hit_reach(skill_id, stage, airborne, career)
	var forward := -1.0 if facing_left else 1.0
	var distance := (target.x - origin.x) * forward
	return distance >= -15.0 and distance <= float(reach[0]) and absf(target.y - origin.y) <= float(reach[1])


func _effective_skill_id(career: int, skill_id: int, airborne: bool) -> int:
	if skill_id > 0:
		return skill_id
	var base := Game.base_career(career)
	if airborne:
		return _air_skill_for_career(career)
	return int(Game.career_combat.get("normal_skills", {}).get(str(base), 4))


func _hit_reach(skill_id: int, stage: int, airborne: bool, career: int) -> Array:
	var eff := _effective_skill_id(career, skill_id, airborne)
	var spec: Dictionary = Game.slice_data.skills.get(str(eff), {})
	var hits: Array = spec.get("hits", [])
	if hits.is_empty():
		return [135, 48, 1000]
	var hit: Dictionary = hits[mini(stage, hits.size() - 1)]
	var reach: Array = hit.get("reach", [135, 48, 1000])
	return reach if reach.size() >= 2 else [135, 48, 1000]


func _target_is_local(target: String) -> bool:
	return target == ("host" if PeerSync.my_role != "guest" else "guest")


func _target_react(target: String) -> Dictionary:
	return local_react if _target_is_local(target) else remote_react


func _target_chain(target: String) -> Dictionary:
	return local_chain if _target_is_local(target) else remote_chain


func _target_facing_left(target: String) -> bool:
	return local_visual.facing_left if _target_is_local(target) else remote_visual.facing_left


func _is_down(target: String) -> bool:
	return str(_target_react(target).get("state", "")) in ["lie", "get_up"]


func _is_floating(target: String) -> bool:
	var react: Dictionary = _target_react(target)
	if str(react.get("state", "")) == "float":
		return true
	return local_jumping if _target_is_local(target) else remote_jumping


func _target_guarded(target: String) -> bool:
	var tick := local_skill_guard_tick if _target_is_local(target) else remote_skill_guard_tick
	return battle_ticks - tick < SKILL_GUARD_TICKS


func _compute_damage(skill_id: int, hit: Dictionary, target: String, attacker_facing_left: bool) -> int:
	if int(hit.get("hurt", 0)) == 3:
		return 0
	var local_attrs: Dictionary = Game.character_attributes()
	var attacker_local := not _target_is_local(target)
	var attack_attrs: Dictionary = local_attrs if attacker_local else remote_combat_attrs
	var defend_attrs: Dictionary = remote_combat_attrs if attacker_local else local_attrs
	var attack_level := int(Game.role().get("level", 1)) if attacker_local else remote_level
	var defend_level := remote_level if attacker_local else int(Game.role().get("level", 1))
	if PeerSync.solo:
		attack_attrs = local_attrs
		defend_attrs = local_attrs
		attack_level = int(Game.role().get("level", 1))
		defend_level = attack_level
	var attack_dir := -1 if attacker_facing_left else 1
	var target_dir := -1 if _target_facing_left(target) else 1
	var target_attacking := attacking if _target_is_local(target) else remote_attacking
	var attacker := DamageCalculator.from_equipment_attributes(attack_attrs, attack_level)
	var target_model := DamageCalculator.from_equipment_attributes(defend_attrs, defend_level)
	var result: Dictionary = DamageCalculator.calculate(attacker, target_model, hit, attack_dir, target_dir, target_attacking, randf, true)
	var damage := maxi(0, int(result.get("damage", 0)))
	var buff: Dictionary = local_buff if attacker_local else remote_buff
	if not buff.is_empty():
		damage = int(float(damage) * float(buff.get("factor", 1.3)))
	return damage


func _chain_allows(target: String) -> bool:
	var chain: Dictionary = _target_chain(target)
	var now := Time.get_ticks_msec()
	var last := int(chain.get("last_ms", -100000))
	if now - last > CHAIN_RESET_MS:
		chain.count = 0
	chain.last_ms = now
	chain.count = int(chain.get("count", 0)) + 1
	if int(chain.count) > CHAIN_LIMIT and now >= int(chain.get("guard_until", 0)):
		chain.guard_until = now + CHAIN_GUARD_MS
		return false
	return true


func _spawn_damage_popup(value: int, point: Vector2, player_hurt: bool) -> void:
	var popup = load("res://scripts/flash/damage_popup.gd").new()
	popup.value = str(value)
	popup.player_hurt = player_hurt
	popup.position = point + Vector2(0, -70)
	fighters.add_child(popup)


func _register_hit(target: String, stage: int, airborne: bool, facing_left: bool, skill_id: int = 0) -> void:
	var career := remote_career if _target_is_local(target) and not PeerSync.solo else int(Game.role().get("career", 100))
	var eff_skill := _effective_skill_id(career, skill_id, airborne)
	var spec: Dictionary = Game.slice_data.skills.get(str(eff_skill), {})
	var hits: Array = spec.get("hits", [])
	if hits.is_empty():
		return
	var hit_index := mini(stage, hits.size() - 1)
	var hit: Dictionary = hits[hit_index]
	var fields: Array = Game.career_combat.get("fields", {}).get(str(eff_skill), [])
	var reaction: Dictionary = fields[mini(hit_index, fields.size() - 1)] if not fields.is_empty() else {}
	if _is_down(target):
		return
	var damage := _compute_damage(eff_skill, hit, target, facing_left)
	if target == "host":
		local_hp = maxi(0, local_hp - damage)
	else:
		remote_hp = maxi(0, remote_hp - damage)
	var impulse := -1 if facing_left else 1
	if _target_guarded(target):
		combat_id += 1
		var guard_event := {"type": "combat", "id": combat_id, "target": target,
			"reaction": "none", "knockdown": false, "power": 0, "power_x": 0, "freeze": 0, "damage": damage,
			"hp_host": local_hp, "hp_guest": remote_hp, "impulse": impulse}
		_apply_combat(guard_event)
		PeerSync.send_combat(guard_event)
		return
	var was_airborne := _is_floating(target)
	var power := int(reaction.get("air_power_y", 0)) if was_airborne else int(reaction.get("power_y", 0))
	var threshold := KNOCKDOWN_AIR_POWER_Y if was_airborne else KNOCKDOWN_POWER_Y
	var knockdown := power >= threshold
	var react_kind := "float" if (knockdown or was_airborne) else "hurt"
	if not _chain_allows(target):
		react_kind = "down"
		power = 0
		knockdown = false
	combat_id += 1
	var event := {"type": "combat", "id": combat_id, "target": target,
		"reaction": react_kind, "knockdown": knockdown, "power": power,
		"power_x": int(reaction.get("power_x", 0)),
		"freeze": int(reaction.get("freeze", 0)),
		"hp_host": local_hp, "hp_guest": remote_hp,
		"impulse": impulse, "damage": damage}
	_apply_combat(event)
	PeerSync.send_combat(event)


func _on_combat(value: Dictionary) -> void:
	var event_id := int(value.get("id", 0))
	if event_id <= last_combat_id:
		return
	last_combat_id = event_id
	_apply_combat(value)


func _apply_combat(value: Dictionary) -> void:
	var am_host := PeerSync.my_role != "guest"
	local_hp = int(value.get("hp_host" if am_host else "hp_guest", MAX_HP))
	remote_hp = int(value.get("hp_guest" if am_host else "hp_host", MAX_HP))
	_update_hp_labels()
	var hit_local := str(value.get("target", "")) == ("host" if am_host else "guest")
	var damage := int(value.get("damage", 0))
	if damage > 0:
		_spawn_damage_popup(damage, local_actor.position if hit_local else remote_actor.position, hit_local)
	if str(value.get("reaction", "hurt")) == "none":
		return
	var start_height := 0.0
	if hit_local:
		if local_jumping:
			start_height = _jump_height(local_jump_elapsed)
		elif not local_react.is_empty() and str(local_react.get("state", "")) == "float":
			start_height = float(local_react.get("height", 0.0))
		attacking = false
		local_action.stop()
		local_jumping = false
		local_visual.end_action_motion()
	else:
		if remote_jumping:
			start_height = _jump_height(remote_jump_elapsed)
		elif not remote_react.is_empty() and str(remote_react.get("state", "")) == "float":
			start_height = float(remote_react.get("height", 0.0))
		remote_attacking = false
		remote_action.stop()
		remote_jumping = false
		remote_visual.end_action_motion()
	_start_reaction("local" if hit_local else "remote", value, start_height)


func _update_hp_labels() -> void:
	if is_instance_valid(local_hp_label):
		local_hp_label.text = "HP %d/%d" % [local_hp, MAX_HP]
	if is_instance_valid(remote_hp_label):
		remote_hp_label.text = "对方 HP %d/%d" % [remote_hp, MAX_HP]
	if is_instance_valid(mp_label):
		mp_label.text = "MP %d/%d" % [local_mp, MAX_MP]
	_apply_vital_frame(hp_art, hp_frames, _vital_frame(local_hp, MAX_HP))
	_apply_vital_frame(mp_art, mp_frames, _vital_frame(local_mp, MAX_MP))


func _vital_frame(current: int, maximum: int) -> int:
	return clampi(ceili(clampf(float(current) / maxi(1, maximum), 0.0, 1.0) * 100.0), 1, 100)


func _apply_vital_frame(art: TextureRect, frames: Array, frame: int) -> void:
	if not is_instance_valid(art) or frames.is_empty():
		return
	var index := clampi(frame - 1, 0, frames.size() - 1)
	var entry: Dictionary = frames[index]
	art.texture = entry.texture
	art.position = Vector2(float(entry.rect[0]), float(entry.rect[1]))
	art.size = Vector2(float(entry.rect[2]), float(entry.rect[3]))


func _begin_reaction_motion(visual: Node2D, kind: String) -> void:
	var motion_id := 11 if kind == "hurt" else 12 if kind == "float" else 15
	visual.begin_action_motion(motion_id, 2 if kind == "float" else 0)


func _start_reaction(which: String, value: Dictionary, start_height: float) -> void:
	var visual: Node2D = local_visual if which == "local" else remote_visual
	var kind := str(value.get("reaction", "hurt"))
	var knockdown := bool(value.get("knockdown", false))
	var power := float(value.get("power", 0.0))
	var power_x := float(value.get("power_x", 0.0))
	var react: Dictionary = {"state": "hurt", "velocity": 0.0, "height": 0.0, "knockdown": false,
		"rebound": false, "ticks": 0, "total_ticks": 0, "impulse": int(value.get("impulse", 1)),
		"knockback": clampf(clampf(power_x, 1500.0, 2000.0) * 0.03, 30.0, 60.0),
		"freeze": int(value.get("freeze", 0)), "elapsed_ticks": 0}
	if kind == "float":
		react.state = "float"
		react.velocity = power
		react.knockdown = knockdown
		react.height = start_height
		_begin_reaction_motion(visual, "float")
	elif kind == "down":
		react.state = "lie"
		react.ticks = DOWN_TICKS
		react.total_ticks = DOWN_TICKS
		_begin_reaction_motion(visual, "lie")
		visual.control_action_timeline("gotoAndStop", 1)
	else:
		react.state = "hurt"
		react.ticks = maxi(4, HURT_TICKS)
		react.total_ticks = react.ticks
		_begin_reaction_motion(visual, "hurt")
	if which == "local":
		local_react = react
		local_reaction_time = 1.0
		local_reaction_clock = 0.0
	else:
		remote_react = react
		remote_reaction_time = 1.0
		remote_reaction_clock = 0.0


func _update_reactions(delta: float) -> void:
	if not local_react.is_empty():
		local_reaction_clock += delta * 30.0
		while local_reaction_clock >= 1.0:
			local_reaction_clock -= 1.0
			_tick_reaction("local")
	if not remote_react.is_empty():
		remote_reaction_clock += delta * 30.0
		while remote_reaction_clock >= 1.0:
			remote_reaction_clock -= 1.0
			_tick_reaction("remote")


func _tick_reaction(which: String) -> void:
	var react: Dictionary = local_react if which == "local" else remote_react
	if react.is_empty():
		return
	var visual: Node2D = local_visual if which == "local" else remote_visual
	if int(react.get("freeze", 0)) > 0:
		react.freeze = int(react.freeze) - 1
		return
	react.elapsed_ticks = int(react.get("elapsed_ticks", 0)) + 1
	match str(react.get("state", "hurt")):
		"hurt":
			react.ticks = int(react.ticks) - 1
			if int(react.ticks) <= 0:
				_end_reaction(which)
				return
		"float":
			react.height = maxf(0.0, float(react.height) + float(react.velocity) * 0.01)
			if float(react.height) <= 0.0:
				react.height = 0.0
				if not bool(react.knockdown):
					_end_reaction(which)
					return
				if not bool(react.rebound):
					react.rebound = true
					react.velocity = -float(react.velocity) * (REBOUND_MIN + randf() * (REBOUND_MAX - REBOUND_MIN))
				else:
					react.state = "lie"
					react.ticks = DOWN_TICKS
					react.total_ticks = DOWN_TICKS
					_begin_reaction_motion(visual, "lie")
					visual.control_action_timeline("gotoAndStop", 1)
			else:
				var rising := float(react.velocity) > 0.0
				react.velocity = float(react.velocity) + REACTION_GRAVITY
				if rising and float(react.velocity) <= 0.0:
					react.velocity = 0.0
		"lie":
			react.ticks = int(react.ticks) - 1
			if int(react.ticks) <= 0:
				react.state = "get_up"
				react.ticks = 16
				visual.control_action_timeline("gotoAndPlay", 2)
		"get_up":
			react.ticks = int(react.ticks) - 1
			if int(react.ticks) <= 0:
				_end_reaction(which)
				return
	if str(react.get("state", "")) != "lie":
		visual.advance_action_motion()
	_apply_reaction_visual(visual, react, which)


func _end_reaction(which: String) -> void:
	var visual: Node2D = local_visual if which == "local" else remote_visual
	var label: Label = local_name if which == "local" else remote_name
	var shadow: Polygon2D = local_shadow if which == "local" else remote_shadow
	if which == "local":
		local_react = {}
		local_reaction_time = 0.0
	else:
		remote_react = {}
		remote_reaction_time = 0.0
	visual.position.x = 0.0
	visual.rotation = 0.0
	visual.modulate = Color.WHITE
	visual.end_action_motion()
	visual.set_motion(3, visual.facing_left)
	_set_actor_height(visual, label, shadow, 0.0)


func _apply_reaction_visual(visual: Node2D, react: Dictionary, which: String) -> void:
	var label: Label = local_name if which == "local" else remote_name
	var shadow: Polygon2D = local_shadow if which == "local" else remote_shadow
	var height := float(react.get("height", 0.0))
	var impulse := int(react.get("impulse", 1))
	var knockback := float(react.get("knockback", 0.0))
	var ticks := int(react.get("elapsed_ticks", 0))
	var kind := str(react.get("state", "hurt"))
	visual.position.x = float(impulse) * knockback * clampf(float(ticks) / 8.0, 0.0, 1.0)
	visual.modulate = Color(1.0, 0.6, 0.6) if (kind in ["hurt", "float"] and ticks % 2 == 0) else Color.WHITE
	_set_actor_height(visual, label, shadow, height)


# --- skill-specific effects: projectile / summon / buff ---

func _make_orb_texture() -> Texture2D:
	var size := 24
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var center := Vector2(float(size - 1) * 0.5, float(size - 1) * 0.5)
	var radius := float(size) * 0.5
	for y in range(size):
		for x in range(size):
			var d := Vector2(float(x), float(y)).distance_to(center)
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, clampf(1.0 - d / radius, 0.0, 1.0)))
	return ImageTexture.create_from_image(img)


func _classify_skill(skill_id: int) -> Dictionary:
	var result := {"buff": false, "projectile": false, "summon": false, "interact_id": 0}
	if skill_id <= 0:
		return result
	var career := int(Game.role().get("career", 100))
	var spec: Dictionary = Game.slice_data.skills.get(str(skill_id), {})
	var action := int(spec.get("action", 0))
	if action <= 0:
		return result
	var state_index := 0
	while state_index <= 32:
		var state: Dictionary = Game.flash_actions.state(career, action, state_index)
		if state.is_empty():
			break
		var motion_id := str(state.get("motion_id", -1))
		if Game.slice_data.motions.has(motion_id):
			var motion = Game.slice_data.motions[motion_id]
			if motion is Dictionary:
				for frame in motion.get("frames", []):
					if not frame is Dictionary:
						continue
					for script in frame.get("scripts", []):
						if not script is Dictionary:
							continue
						var cmd := str(script.get("cmd", ""))
						if cmd == "applyFunction":
							result.buff = true
						elif cmd == "createInteract":
							var args: Dictionary = script.get("args", {}) if script.get("args", {}) is Dictionary else {}
							var iid := int(args.get("id", 0))
							result.interact_id = iid
							var itype := int(Game.career_combat.interacts.get(str(iid), {}).get("type", 0))
							if itype in PROJECTILE_TYPES:
								result.projectile = true
							elif itype in SUMMON_TYPES:
								result.summon = true
		state_index += 1
	return result


func _spawn_skill_effect(skill_id: int, origin: Vector2, facing_left: bool, owner: String) -> void:
	var kind := _classify_skill(skill_id)
	if kind.buff:
		_apply_buff(owner)
	# Projectile and summon creation belongs to the action frame's createInteract script.
	# A visual-only fallback is retained for motions missing from the script catalog.
	if (owner == "local" and local_skill_fallback) or (owner == "remote" and remote_skill_fallback):
		_spawn_interact({"id": int(kind.interact_id)}, skill_id, owner)


func _spawn_interact(args: Dictionary, skill_id: int, owner: String) -> void:
	if int(args.get("clear", 0)) == 1 or skill_id <= 0:
		return
	var interact_id := int(args.get("id", 0))
	var spec: Dictionary = Game.career_combat.get("interacts", {}).get(str(interact_id), {})
	if spec.is_empty():
		return
	var kind := int(spec.get("type", 0))
	var origin: Vector2 = local_actor.position if owner == "local" else remote_actor.position
	var facing_left: bool = local_visual.facing_left if owner == "local" else remote_visual.facing_left
	if kind in PROJECTILE_TYPES:
		_spawn_projectile(skill_id, origin, facing_left, owner, interact_id)
	elif kind in SUMMON_TYPES:
		_spawn_summon(skill_id, origin, facing_left, owner, interact_id)


func _interact_visual(interact_id: int, facing_left: bool) -> Node2D:
	var spec: Dictionary = Game.career_combat.get("interacts", {}).get(str(interact_id), {})
	var node := Node2D.new()
	node.scale = Vector2(-1.0 if facing_left else 1.0, 1.0) * (160.0 / 151.0)
	var layers := []
	var art: Dictionary = spec.get("art", {})
	var default_state := str(int(spec.get("default_state", 1)))
	var state: Dictionary = spec.get("states", {}).get(default_state, {})
	var motion_id := str(int(state.get("motion", 0)))
	for layer in art.get("layers", []):
		if not layer is Dictionary:
			continue
		var frames: Array = layer.get("motions", {}).get(motion_id, [])
		if frames.is_empty():
			continue
		var sprite := Sprite2D.new()
		sprite.centered = false
		sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		node.add_child(sprite)
		layers.append({"sprite": sprite, "frames": frames})
	if layers.is_empty():
		var placeholder := Sprite2D.new()
		placeholder.texture = orb_tex
		placeholder.scale = Vector2(2.0, 2.0)
		node.add_child(placeholder)
	else:
		var duration := 0
		for layer in layers:
			var layer_duration := 0
			for frame in layer.frames:
				layer_duration += maxi(1, int(frame.get("ticks", 1)))
			duration = maxi(duration, layer_duration)
		var effect := {"node": node, "layers": layers, "tick": 0, "elapsed": 0.0,
			"duration": duration, "loop": true}
		arena_effects.append(effect)
		_render_effect(effect)
	return node


func _apply_buff(owner: String) -> void:
	var buff: Dictionary = local_buff if owner == "local" else remote_buff
	if is_instance_valid(buff.get("aura")):
		buff.aura.queue_free()
	var aura := Sprite2D.new()
	aura.texture = orb_tex
	aura.scale = Vector2(5.0, 5.0)
	aura.modulate = Color(1.0, 0.7, 0.25, 0.45)
	aura.z_index = -1
	(local_actor if owner == "local" else remote_actor).add_child(aura)
	buff = {"factor": 1.3, "elapsed": 0.0, "duration": 5.0, "aura": aura}
	if owner == "local":
		local_buff = buff
	else:
		remote_buff = buff


func _spawn_projectile(skill_id: int, origin: Vector2, facing_left: bool, owner: String, interact_id: int) -> void:
	var node := _interact_visual(interact_id, facing_left)
	node.position = origin
	fighters.add_child(node)
	projectiles.append({"node": node, "dir": -1.0 if facing_left else 1.0,
		"speed": 600.0, "skill_id": skill_id, "owner": owner, "life": 2.0})


func _spawn_summon(skill_id: int, origin: Vector2, facing_left: bool, owner: String, interact_id: int) -> void:
	var node := _interact_visual(interact_id, facing_left)
	node.position = origin + Vector2(-60.0 if facing_left else 60.0, 0.0)
	fighters.add_child(node)
	summons.append({"node": node, "owner": owner, "skill_id": skill_id,
		"facing_left": facing_left, "attack_timer": 0.5, "life": 6.0})


func _spawn_effect(actor: Node2D, args: Dictionary, owner: String) -> void:
	if int(args.get("clear", 0)) == 1:
		return
	var id := str(args.get("id", ""))
	if not Game.slice_data.effects.has(id):
		return
	var data: Dictionary = Game.slice_data.effects[id]
	var motion_id := str(args.get("motionID", "0"))
	var visual: Node2D = local_visual if owner == "local" else remote_visual
	var direction := -1.0 if visual.facing_left else 1.0
	var dir_arg := int(args.get("dir", 0))
	if dir_arg == 2:
		direction *= -1.0
	elif dir_arg in [-1, 1]:
		direction = float(dir_arg)
	var node := Node2D.new()
	node.z_index = 2
	var art_scale := absf(visual.scale.y)
	var layers := []
	for layer in data.get("layers", []):
		var frames: Array = layer.get("motions", {}).get(motion_id, [])
		if frames.is_empty():
			continue
		var sprite := Sprite2D.new()
		sprite.centered = false
		sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		node.add_child(sprite)
		layers.append({"sprite": sprite, "frames": frames})
	if layers.is_empty():
		node.free()
		return
	node.position = actor.position + Vector2(float(args.get("x", 0)) * direction,
		float(args.get("z", 0)) - float(args.get("y", 0))) * art_scale
	var mirror := -1.0 if direction < 0.0 else 1.0
	node.scale = Vector2(float(args.get("scaleX", 1)) * mirror, float(args.get("scaleY", 1))) * art_scale
	var angle := float(args.get("rotation", 0))
	node.rotation_degrees = -angle if direction < 0.0 else angle
	fighters.add_child(node)
	var duration := 0
	for layer in layers:
		var d := 0
		for frame in layer.frames:
			d += maxi(1, int(frame.get("ticks", 1)))
		duration = maxi(duration, d)
	arena_effects.append({"node": node, "layers": layers, "tick": 0, "elapsed": 0.0,
		"duration": duration, "loop": bool(data.get("loop", false))})


func _advance_effect(effect: Dictionary, delta: float) -> void:
	var node: Node2D = effect.get("node")
	if not is_instance_valid(node):
		arena_effects.erase(effect)
		return
	effect.elapsed = float(effect.get("elapsed", 0.0)) + delta * 30.0
	while float(effect.elapsed) >= 1.0:
		effect.elapsed = float(effect.elapsed) - 1.0
		effect.tick = int(effect.get("tick", 0)) + 1
		if not bool(effect.get("loop", false)) and int(effect.tick) >= int(effect.get("duration", 1)):
			node.queue_free()
			arena_effects.erase(effect)
			return
	_render_effect(effect)


func _render_effect(effect: Dictionary) -> void:
	var tick := int(effect.get("tick", 0))
	for layer in effect.get("layers", []):
		var sprite: Sprite2D = layer.sprite
		var frames: Array = layer.frames
		if frames.is_empty():
			sprite.hide()
			continue
		var duration := 0
		for frame in frames:
			duration += maxi(1, int(frame.get("ticks", 1)))
		var cursor := tick % maxi(1, duration)
		var rendered := false
		for frame in frames:
			var ft := maxi(1, int(frame.get("ticks", 1)))
			if cursor < ft:
				var path := str(frame.get("path", ""))
				if path.is_empty():
					sprite.hide()
				else:
					sprite.show()
					sprite.texture = TextureCache.fetch(path)
					var translation: Array = frame.get("translation", [0, 0])
					var origin: Array = frame.get("origin", [0, 0])
					var scale: Array = frame.get("scale", [1, 1])
					sprite.position = Vector2(float(translation[0]), float(translation[1])) + Vector2(float(origin[0]), float(origin[1])) * Vector2(float(scale[0]), float(scale[1]))
					sprite.scale = Vector2(float(scale[0]), float(scale[1]))
					sprite.rotation_degrees = float(frame.get("rotation", 0))
					sprite.modulate.a = clampf(float(frame.get("alpha", 1)) + float(frame.get("delta_alpha", 0)) * float(cursor + 1), 0.0, 1.0)
				rendered = true
				break
			cursor -= ft
		if not rendered:
			sprite.hide()


func _update_effects(delta: float) -> void:
	if not local_buff.is_empty():
		local_buff.elapsed = float(local_buff.get("elapsed", 0.0)) + delta
		if float(local_buff.elapsed) >= float(local_buff.get("duration", 5.0)):
			if is_instance_valid(local_buff.get("aura")):
				local_buff.aura.queue_free()
			local_buff = {}
	if not remote_buff.is_empty():
		remote_buff.elapsed = float(remote_buff.get("elapsed", 0.0)) + delta
		if float(remote_buff.elapsed) >= float(remote_buff.get("duration", 5.0)):
			if is_instance_valid(remote_buff.get("aura")):
				remote_buff.aura.queue_free()
			remote_buff = {}
	for effect in arena_effects.duplicate():
		_advance_effect(effect, delta)
	for projectile in projectiles.duplicate():
		_update_projectile(projectile, delta)
	for summon in summons.duplicate():
		_update_summon(summon, delta)


func _update_projectile(projectile: Dictionary, delta: float) -> void:
	var node: Node2D = projectile.get("node")
	if not is_instance_valid(node):
		projectiles.erase(projectile)
		return
	var dir := float(projectile.get("dir", 1.0))
	node.position.x += dir * float(projectile.get("speed", 600.0)) * delta
	projectile.life = float(projectile.get("life", 0.0)) - delta
	var owner: String = str(projectile.get("owner", "local"))
	var target_pos: Vector2 = target_position if owner == "local" else local_actor.position
	var target_name := "guest" if owner == "local" else "host"
	var target_hp := remote_hp if owner == "local" else local_hp
	if float(projectile.life) <= 0.0:
		node.queue_free()
		projectiles.erase(projectile)
		return
	if target_hp <= 0 or PeerSync.my_role != "host":
		return
	if absf(node.position.x - target_pos.x) < 40.0 and absf(node.position.y - target_pos.y) < 60.0:
		_register_hit(target_name, 0, false, dir < 0.0, int(projectile.get("skill_id", 0)))
		node.queue_free()
		projectiles.erase(projectile)


func _update_summon(summon: Dictionary, delta: float) -> void:
	var node: Node2D = summon.get("node")
	if not is_instance_valid(node):
		summons.erase(summon)
		return
	var owner: String = str(summon.get("owner", "local"))
	var owner_pos: Vector2 = local_actor.position if owner == "local" else target_position
	node.position = node.position.lerp(owner_pos + Vector2(0.0, -20.0), clampf(delta * 4.0, 0.0, 1.0))
	summon.attack_timer = float(summon.get("attack_timer", 0.0)) - delta
	summon.life = float(summon.get("life", 0.0)) - delta
	if float(summon.life) <= 0.0:
		node.queue_free()
		summons.erase(summon)
		return
	if float(summon.attack_timer) > 0.0:
		return
	summon.attack_timer = 0.9
	var target_name := "guest" if owner == "local" else "host"
	var target_pos: Vector2 = target_position if owner == "local" else local_actor.position
	var target_hp := remote_hp if owner == "local" else local_hp
	if PeerSync.my_role == "host" and target_hp > 0 and absf(node.position.x - target_pos.x) < 120.0 and absf(node.position.y - target_pos.y) < 80.0:
		_register_hit(target_name, 0, false, bool(summon.get("facing_left", false)), int(summon.get("skill_id", 0)))


# --- single-player practice dummy ---

func _setup_solo_dummy() -> void:
	remote_actor.visible = true
	remote_actor.position = GUEST_SPAWN
	target_position = GUEST_SPAWN
	remote_visual.configure(_safe_appearance(Game.role()))
	remote_visual.facing_left = true
	remote_name.text = "练习木桩"
	remote_hp = MAX_HP
	dummy_respawn_elapsed = 0.0
	dummy_attack_enabled = false
	dummy_attack_elapsed = 0.0
	_solo_hint_update()


func _update_solo_dummy(delta: float) -> void:
	if remote_hp <= 0:
		dummy_respawn_elapsed += delta
		if dummy_respawn_elapsed >= 3.0:
			remote_hp = MAX_HP
			_end_reaction("remote")
			dummy_respawn_elapsed = 0.0
			_update_hp_labels()
	else:
		dummy_respawn_elapsed = 0.0
	if dummy_attack_enabled and remote_hp > 0 and local_hp > 0 and remote_reaction_time <= 0.0:
		dummy_attack_elapsed += delta
		if dummy_attack_elapsed >= 2.0:
			dummy_attack_elapsed = 0.0
			var dummy_facing_left := local_actor.position.x < remote_actor.position.x
			if _in_reach(remote_actor.position, local_actor.position, dummy_facing_left, 4, 0, false, int(Game.role().get("career", 100))):
				_register_hit("host", 0, false, dummy_facing_left, 4)


func _solo_hint_update() -> void:
	if is_instance_valid(solo_hint):
		solo_hint.text = "单人练习：木桩反击 " + ("开启（按 V 关闭）" if dummy_attack_enabled else "关闭（按 V 开启）")
