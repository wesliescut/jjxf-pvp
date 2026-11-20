extends "res://scripts/game_world.gd"

# PvP uses the original Player, HUD, arena map, and patched SliceRun. No city
# initialization, training menu, or training dummy is started here.

var opponent
var remote_actor: Node2D
var remote_visual
var remote_visual_run: Node
var remote_visual_target: Node2D
var remote_action = preload("res://scripts/flash/action_player.gd").new()
var remote_skill: int = 0
var remote_stage: int = -1
var remote_action_serial: int = -1
var remote_action_seen_msec: int = 0
var remote_clock: float = 0.0
var remote_target_position: Vector2 = Vector2.ZERO
var remote_reaction_state: String = ""
var remote_reaction_motion: int = 0
var remote_caught_motion: int = 0
var remote_caught_last_msec: int = 0
var remote_caught_reflected_parts: Array = []
var last_caught_pose: Dictionary = {}
var remote_avatar_key: String = ""
var hit_request_id: int = 0
var last_peer_hit_id: int = 0
var round_id: int = 0
var round_finished: bool = false
var round_started_msec: int = 0
var peer_departed: bool = false
var result_label: Label
var opponent_hp_label: Label
const DamageCalculator = preload("res://scripts/flash/damage_calculator.gd")
const BUILD_TAG: String = "PVP v45 · 一键部署中继"

# Two-player transport notes.
# The single player game never had to answer "where was the other body when I
# pressed attack". Nothing below changes combat data, hitboxes, damage,
# reactions or action timelines: it only decides *when* and *at which position*
# the original hit tests are evaluated.
#  * RENDER_DELAY_MS: the remote body is drawn from buffered snapshots so the
#    body a player sees is exactly the body that player locally hits.
#  * REWIND_MS: the host re-runs the same hit test over its own recent
#    positions, so a guest hit is judged where the guest saw it, not where the
#    host already moved to.
const RENDER_DELAY_MS: int = 100
const REWIND_MS: int = 260
var peer_samples: Array = []
var local_history: Array = []
var local_history_msec: int = 0
var trace_file: FileAccess = null

# Control skills in the two packs are implemented as "catch the target body":
# the attacker's action emits catchTarget / targetBinding / throwTarget frame
# scripts. In PvP the target is a real player, so the defender replays the very
# same frame scripts from the attacker's action and applies the catch to itself.
# It only starts when this player actually took a hit from that skill, so a
# whiffed grab never locks anybody.
const GRAB_MAX_MS: int = 2600
var grab_active: bool = false
var grab_armed_skill: int = 0
var grab_armed_msec: int = 0
var grab_pending_skill: int = 0
var grab_pending_msec: int = 0
var grab_offset: Vector3 = Vector3.ZERO
var remote_grab_binding: Vector3 = Vector3.ZERO
var grab_until_msec: int = 0
var grab_pose_motion: int = 0
var grab_pose_last_msec: int = 0
var grab_reflected_parts: Array = []
var grab_remote_pin: int = 0
var last_opponent_caught: bool = false
var caught_release_started_msec: int = 0
# Bounded window for the caught/throw pose rendering. Relying on the sticky
# last_opponent_caught flag meant one missed release froze the opponent body (and
# with it every local hit test) until the next round.
var caught_visual_until_msec: int = 0
# Get-up protection ("起身保护"): the pack grants QUICK_GRACE = 45 ticks (1.5s at
# 30Hz) of invulnerability after a quick recovery, plus the whole get_up pose.
# That lives only on the victim's own reaction object, so derive it on the
# attacker from the synced reaction_state and treat it as a no-hit window.
const PEER_PROTECT_GRACE_MS: int = 1500
# One round lasts five minutes, like the original arena timer.
const ROUND_LIMIT_MS: int = 300000
var round_limit_until_msec: int = 0
var self_bar = null
var foe_bar = null
var timer_label: Label
var timer_back: ColorRect
# In-match chat: Enter opens the line, Enter sends, Esc leaves it.
const CHAT_MAX_LEN: int = 120
var chat_open: bool = false
var chat_input: LineEdit
var chat_log: Label
var chat_lines: Array = []
var chat_log_until_msec: int = 0
var peer_protect_until_msec: int = 0
var peer_mp_value: int = 0
var peer_was_getting_up: bool = false
var state_starve_traced_msec: int = 0
var local_throw_until_msec: int = 0
# PvP reuses the original defeat panel (same art and layout) but replaces its
# buttons: the host starts the next round, the guest only marks itself ready.
var result_panel: Control
var result_button_primary: TextureButton
var result_button_label: Label
var guest_ready: bool = false
# Guest -> host control events ride on the existing hit_request channel with a
# reserved id range, because the relay only lets the host send combat results.
const CONTROL_ID_BASE: int = 1000000
var control_counter: int = 0
var last_peer_control_id: int = 0

func _ready() -> void:
	process_physics_priority = 100
	if Game.role().is_empty():
		get_tree().change_scene_to_file("res://scenes/role_select.tscn")
		return
	%HUD.world = self
	audio = Audio
	loading = preload("res://scripts/flash/scene_loading.gd").new()
	loading.name = "SceneLoading"
	add_child(loading)
	slice_run = preload("res://_multiplayer/pvp_run.gd").new()
	slice_run.name = "SliceRun"
	add_child(slice_run)
	var overlay = preload("res://scripts/slice_overlay.gd").new()
	overlay.name = "HUDOverlay"
	add_child(overlay)
	result_label = Label.new()
	result_label.position = Vector2(300, 75)
	result_label.size = Vector2(340, 45)
	result_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	result_label.add_theme_font_size_override("font_size", 24)
	result_label.hide()
	get_node("CanvasLayer").add_child(result_label)
	opponent_hp_label = Label.new()
	opponent_hp_label.anchor_left = 1.0
	opponent_hp_label.anchor_right = 1.0
	opponent_hp_label.offset_left = -380
	opponent_hp_label.offset_right = -24
	opponent_hp_label.offset_top = 48
	opponent_hp_label.offset_bottom = 82
	opponent_hp_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	opponent_hp_label.add_theme_font_size_override("font_size", 23)
	get_node("CanvasLayer").add_child(opponent_hp_label)
	var build_label := Label.new()
	build_label.name = "BuildTag"
	build_label.text = BUILD_TAG
	build_label.position = Vector2(12, 8)
	build_label.add_theme_font_size_override("font_size", 16)
	get_node("CanvasLayer").add_child(build_label)
	slice_run.settings.scene_id = 0
	var paths: Dictionary = {}
	collect_paths(slice_run.scene_definition(), paths)
	if not await loading.prepare(paths.keys(), "加载双人擂台…", true):
		push_error("PVP_ARENA_ASSET_LOAD_FAILED")
		return
	if not slice_run.begin_pvp():
		push_error("PVP_ORIGINAL_COMBAT_BEGIN_FAILED")
		await loading.finish()
		return
	await loading.finish()
	%Player.position = current_map.safe_position(Vector2(780, 390) if PeerSync.my_role == "host" else Vector2(1100, 500))
	%Player.get_node("Visual").facing_left = PeerSync.my_role == "guest"
	reset_original_camera(Game.slice_data.rooms[str(slice_run.room_id)])
	PeerSync.peer_state_received.connect(_on_peer_state)
	PeerSync.peer_disconnected.connect(_on_peer_left)
	PeerSync.combat_received.connect(_on_combat)
	PeerSync.hit_request_received.connect(_on_hit_request)
	PeerSync.round_received.connect(_on_round)
	PeerSync.chat_received.connect(_on_chat_received)
	if PeerSync.solo:
		var dummy_avatar: Dictionary = Game.role().duplicate(true)
		dummy_avatar.combat_attrs = Game.character_attributes()
		_on_peer_state({"avatar": dummy_avatar, "x": 1100.0, "y": 500.0, "ready": true, "motion": 3})
		_begin_round(1)
	if not PeerSync.round_state.is_empty():
		_on_round(PeerSync.round_state)
	if not PeerSync.peer_state.is_empty():
		_on_peer_state(PeerSync.peer_state)
	_setup_result_panel()
	_setup_hp_bars()
	_setup_chat_ui()
	_dump_motion_catalog()
	print("PVP_ORIGINAL_COMBAT_CORE_READY")


func _setup_hp_bars() -> void:
	# Two arena plates drawn by pvp_hp_bar.gd: the local player top-left and the
	# opponent top-right, with the round timer between them. The monster boss bar is
	# no longer borrowed here.
	opponent_hp_label.visible = false
	var bar_script = preload("res://_multiplayer/pvp_hp_bar.gd")
	self_bar = bar_script.new()
	self_bar.side = "left"
	self_bar.position = Vector2(10, 6)
	get_node("CanvasLayer").add_child(self_bar)
	foe_bar = bar_script.new()
	foe_bar.side = "right"
	foe_bar.position = Vector2(630, 6)
	get_node("CanvasLayer").add_child(foe_bar)
	timer_back = ColorRect.new()
	timer_back.color = Color(0.05, 0.15, 0.28, 0.82)
	timer_back.position = Vector2(420, 2)
	timer_back.size = Vector2(100, 26)
	timer_back.mouse_filter = Control.MOUSE_FILTER_IGNORE
	get_node("CanvasLayer").add_child(timer_back)
	timer_label = Label.new()
	timer_label.position = Vector2(420, 1)
	timer_label.size = Vector2(100, 28)
	timer_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	timer_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	timer_label.add_theme_font_override("font", load("res://assets/fonts/bitsumishi.ttf"))
	timer_label.add_theme_font_size_override("font_size", 22)
	timer_label.add_theme_color_override("font_outline_color", Color.BLACK)
	timer_label.add_theme_constant_override("outline_size", 3)
	timer_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	timer_label.text = "5:00"
	get_node("CanvasLayer").add_child(timer_label)


func _setup_chat_ui() -> void:
	var canvas: Node = get_node("CanvasLayer")
	chat_log = Label.new()
	chat_log.position = Vector2(230, 404)
	chat_log.size = Vector2(480, 70)
	chat_log.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	chat_log.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	chat_log.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	chat_log.add_theme_font_size_override("font_size", 15)
	chat_log.add_theme_color_override("font_outline_color", Color.BLACK)
	chat_log.add_theme_constant_override("outline_size", 3)
	chat_log.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chat_log.text = ""
	canvas.add_child(chat_log)
	chat_input = LineEdit.new()
	chat_input.position = Vector2(230, 478)
	chat_input.size = Vector2(480, 32)
	chat_input.max_length = CHAT_MAX_LEN
	chat_input.placeholder_text = "输入消息，回车发送，Esc 退出"
	chat_input.add_theme_font_size_override("font_size", 16)
	chat_input.add_theme_color_override("font_placeholder_color", Color(0.8, 0.9, 1.0, 0.65))
	chat_input.visible = false
	chat_input.text_submitted.connect(_on_chat_submit)
	canvas.add_child(chat_input)


func _open_chat() -> void:
	if chat_input == null or chat_open:
		return
	chat_open = true
	chat_input.visible = true
	chat_input.text = ""
	chat_input.grab_focus()
	chat_input.caret_column = 0
	chat_log_until_msec = Time.get_ticks_msec() + 12000


func _close_chat() -> void:
	chat_open = false
	if chat_input != null:
		chat_input.release_focus()
		chat_input.visible = false


func _on_chat_submit(text: String) -> void:
	var clean: String = text.strip_edges()
	_close_chat()
	if clean.is_empty():
		return
	if clean.length() > CHAT_MAX_LEN:
		clean = clean.substr(0, CHAT_MAX_LEN)
	PeerSync.send_chat(clean)
	_append_chat(str(Game.role().get("name", "我")), clean)


func _on_chat_received(value: Dictionary) -> void:
	var text: String = str(value.get("text", "")).strip_edges()
	if text.is_empty():
		return
	var who: String = str(PeerSync.peer_state.get("avatar", {}).get("name", "对方"))
	if who.is_empty():
		who = "对方"
	_append_chat(who, text)


func _append_chat(who: String, text: String) -> void:
	if chat_log == null:
		return
	chat_lines.append("%s：%s" % [who, text])
	while chat_lines.size() > 4:
		chat_lines.pop_front()
	chat_log.text = "\n".join(chat_lines)
	chat_log_until_msec = Time.get_ticks_msec() + 12000


func _update_chat_visibility() -> void:
	if chat_log == null:
		return
	if chat_open:
		return
	if not chat_log.text.is_empty() and Time.get_ticks_msec() > chat_log_until_msec:
		chat_log.text = ""
		chat_lines.clear()


func _hide_monster_bar() -> void:
	# The original monster boss bar still pops up when the proxy takes damage; the
	# arena plates replace it, so keep it hidden.
	var overlay: Node = get_node_or_null("HUDOverlay")
	if overlay == null:
		return
	var panel = overlay.get("blood_panel")
	if panel is CanvasItem and (panel as CanvasItem).visible:
		(panel as CanvasItem).hide()


func _status_ids_with_mp() -> Array:
	# The relay forwards "statuses" as numeric ids, so current MP rides along in a
	# reserved entry ("9999" + 8 digits). This keeps the opponent MP readable without
	# another relay deployment; receivers strip the entry before using statuses.
	var ids: Array = []
	for key in slice_run.source_status.active.keys():
		ids.append(str(key))
	ids.append("9999" + "%08d" % clampi(int(slice_run.mp), 0, 99999999))
	return ids


func _hide_roles_button() -> void:
	# The arena has no role-list flow: the original HUD button would save and drop the
	# player out of the match, so keep it hidden while the PvP scene is active.
	var hud: Node = %HUD
	if hud == null:
		return
	var button: Node = hud.find_child("ReturnRolesButton", true, false)
	if button is CanvasItem and (button as CanvasItem).visible:
		(button as CanvasItem).hide()


func _update_hp_bars() -> void:
	_hide_monster_bar()
	_hide_roles_button()
	if self_bar != null:
		var me: Dictionary = Game.role()
		var my_name: String = str(me.get("name", "我"))
		if my_name.is_empty():
			my_name = "我"
		var host_side: bool = PeerSync.my_role == "host"
		self_bar.role_tag = "房主" if host_side else "客人"
		self_bar.slot_tag = "1P" if host_side else "2P"
		self_bar.set_values(my_name, int(me.get("level", 1)),
			int(slice_run.hp), int(slice_run.max_hp), int(slice_run.mp), int(slice_run.max_mp))
	if foe_bar != null:
		if not is_instance_valid(opponent):
			foe_bar.visible = false
			return
		foe_bar.visible = true
		var avatar: Dictionary = PeerSync.peer_state.get("avatar", {})
		var who: String = str(avatar.get("name", "对手"))
		if who.is_empty():
			who = "对手"
		var host_side: bool = PeerSync.my_role == "host"
		foe_bar.role_tag = "客人" if host_side else "房主"
		foe_bar.slot_tag = "2P" if host_side else "1P"
		var foe_mp: int = peer_mp_value
		foe_bar.set_values(who, int(avatar.get("level", 1)),
			int(opponent.hp), int(opponent.max_hp), foe_mp, int(slice_run.max_mp))


func _update_round_timer() -> void:
	if timer_label == null:
		return
	var fighting: bool = round_id > 0 and not round_finished and str(slice_run.status) == "battle"
	if fighting and round_limit_until_msec == 0:
		round_limit_until_msec = Time.get_ticks_msec() + ROUND_LIMIT_MS
	if round_limit_until_msec == 0:
		timer_label.text = "5:00"
		return
	var remain: int = maxi(0, round_limit_until_msec - Time.get_ticks_msec())
	timer_label.text = "%d:%02d" % [remain / 60000, (remain / 1000) % 60]
	if remain <= 0 and fighting and PeerSync.my_role == "host":
		# Time up: the side with the larger remaining HP ratio takes the round.
		var mine: float = float(slice_run.hp) / maxf(1.0, float(slice_run.max_hp))
		var theirs: float = 0.0
		if is_instance_valid(opponent):
			theirs = float(opponent.hp) / maxf(1.0, float(opponent.max_hp))
		_trace("round_timeout", {"mine": snappedf(mine, 0.001), "theirs": snappedf(theirs, 0.001)})
		_finish_round("host" if mine >= theirs else "guest")


func _dump_motion_catalog() -> void:
	# Dumps the player motion catalog and the humanoid monster's motion catalog so
	# the victim pose can be chosen from real ids instead of guessed.
	var motions: Dictionary = Game.slice_data.get("motions", {}) if Game.slice_data is Dictionary else {}
	var parts: Array = []
	for key in motions.keys():
		var entry = motions[key]
		var frames: Array = []
		if entry is Dictionary:
			frames = entry.get("frames", [])
		elif entry is Array:
			frames = entry
		parts.append("%s(%d)" % [str(key), frames.size()])
	_trace("player_motions", {"count": motions.size(), "list": " ".join(parts)})
	var gameplay = Game.gameplay_data
	var monster_motions: Dictionary = {}
	if gameplay is Dictionary:
		var all_motions = gameplay.get("monster_motions", {})
		if all_motions is Dictionary:
			var entry20603 = all_motions.get("20603", {})
			if entry20603 is Dictionary:
				monster_motions = entry20603
	var mon_parts: Array = []
	for key in monster_motions.keys():
		var entry = monster_motions[key]
		var frames: Array = []
		if entry is Dictionary:
			frames = entry.get("frames", [])
		elif entry is Array:
			frames = entry
		mon_parts.append("%s(%d)" % [str(key), frames.size()])
	_trace("monster_motions_20603", {"count": monster_motions.size(), "list": " ".join(mon_parts)})


func _process(_delta: float) -> void:
	if current_map == null:
		return
	%Player.input_enabled = not round_finished and not grab_active and not chat_open and not slice_run.has_meta("jjxf_fatal_pending") and slice_run.hp > 0 and not loading.busy and not %HUD.modal_open() and slice_run.status == "battle"
	%HUD.set_hint(Controls.combat_hint() + " · 同方向连按跑动")
	_update_hp_bars()
	_update_round_timer()
	_update_chat_visibility()
	if is_instance_valid(opponent):
		opponent_hp_label.text = "对方 HP %d/%d" % [int(opponent.hp), int(opponent.max_hp)]
	else:
		opponent_hp_label.text = "等待对方加入"
	if PeerSync.my_role == "guest" and round_id > 0 and not round_finished and is_instance_valid(opponent):
		# The guest owns the caught state of the host body on its own screen; it is
		# the attacker in that case, so it announces the transition to the host.
		_update_catch_control(bool(opponent.caught))
	if PeerSync.my_role == "host" and round_id > 0 and not round_finished and is_instance_valid(opponent):
		# The host owns the caught state of the guest body. Announce transitions so
		# the guest locks and releases itself without guessing from frame scripts.
		_update_catch_control(bool(opponent.caught))
		# Ignore the very first moments after a restart: bodies and HP are still
		# being reset on both ends and a leftover zero would end the new round.
		if Time.get_ticks_msec() - round_started_msec < 700:
			return
		if slice_run.hp <= 0:
			slice_run.mark_pvp_fatal_if_needed()
			if slice_run.status == "defeat":
				_finish_round("guest")
		elif opponent.hp <= 0 and (PeerSync.solo or bool(PeerSync.peer_state.get("defeat_ready", false))):
			_finish_round("host")
	elif PeerSync.my_role == "guest" and round_id > 0 and not round_finished and slice_run.hp <= 0:
		slice_run.mark_pvp_fatal_if_needed()


func _peer_protected() -> bool:
	return Time.get_ticks_msec() < peer_protect_until_msec


func _local_protected() -> bool:
	# The pack's own definition of get-up protection for this player: quick get_up
	# pose, or the grace counter that follows it. Asking the pack keeps both sides
	# identical instead of re-deriving the rule here.
	return preload("res://scripts/recovery_rules.gd").player_protected(slice_run)


func _revert_protected_hit(amount: int, skill_id: int) -> void:
	# The original game deals no damage and allows no catch while the target is in
	# get-up protection. The attacker side already applied the hit to its proxy, so
	# undo it there and drop any catch, otherwise the proxy HP is authoritative and
	# the protected player still loses health (or gets grabbed).
	if is_instance_valid(opponent):
		opponent.hp = mini(int(opponent.max_hp), int(opponent.hp) + maxi(0, amount))
		if bool(opponent.caught):
			opponent.caught = false
			slice_run.release_caught_targets()
	_trace("revert_protected", {"skill": skill_id, "amount": amount})


func _update_catch_control(caught_now: bool) -> void:
	# The original catch target may briefly clear its flag between action frames.
	# Announce catch immediately, but only announce release after it stays clear.
	if caught_now and _peer_protected():
		caught_now = false
	if caught_now:
		caught_release_started_msec = 0
		caught_visual_until_msec = Time.get_ticks_msec() + 1500
		if not last_opponent_caught:
			last_opponent_caught = true
			if PeerSync.my_role == "host":
				_send_control("caught")
			else:
				_send_peer_control("caught")
	elif last_opponent_caught:
		if caught_release_started_msec == 0:
			caught_release_started_msec = Time.get_ticks_msec()
		elif Time.get_ticks_msec() - caught_release_started_msec >= 120:
			last_opponent_caught = false
			caught_release_started_msec = 0
			# Keep the release/throw pose for a moment, then hand the body back to
			# the normal interpolation no matter what.
			caught_visual_until_msec = Time.get_ticks_msec() + 700
			if PeerSync.my_role == "host":
				_send_control("released")
			else:
				_send_peer_control("released")


func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	_record_local_history()
	_update_remote_body()
	_hide_monster_bar()
	_hide_roles_button()
	_update_remote_caught_visual()
	_update_grab_binding()
	if not is_instance_valid(remote_actor):
		return
	remote_clock += delta * 30.0
	while remote_clock >= 1.0:
		remote_clock -= 1.0
		if is_instance_valid(remote_visual_target):
			remote_visual_target.refresh()
		if remote_action.active:
			remote_action.advance()
		slice_run.advance_remote_visual_interacts()


func _update_grab_binding() -> void:
	if not grab_active:
		return
	if current_map == null or Time.get_ticks_msec() > grab_until_msec:
		_end_grab()
		return
	var visual = %Player.get_node("Visual")
	# The packs drive the caught body's pose through grab_rules.grab_pose(), which
	# is frame-synchronised with the attacker's action: motion 15 (down) during
	# certain frame ranges and motion 13 (held) otherwise. Replicate that same
	# decision here from the attacker's replayed action instead of forcing one pose.
	var pose: Dictionary = PeerSync.peer_state.get("caught_pose", {})
	if pose.is_empty():
		pose = _remote_grab_pose()
	if pose.has("facing_left"):
		visual.facing_left = bool(pose.facing_left)
	_apply_grab_pose(pose, visual)
	var down: bool = not pose.is_empty() and int(pose.motion) == 15
	var facing: int = -1 if (is_instance_valid(remote_visual) and remote_visual.facing_left) else 1
	var ground: Vector2 = remote_target_position + Vector2(grab_offset.x * facing, grab_offset.z)
	if pose.has("x") and pose.has("y"):
		ground = Vector2(float(pose.x), float(pose.y))
	%Player.position = current_map.safe_position(ground)
	var base_height: float = float(remote_actor.jump_height) if is_instance_valid(remote_actor) else 0.0
	var bound_y: float = grab_offset.y * (0.6 if int(PeerSync.peer_state.get("avatar", {}).get("career", 0)) == 330 else 1.0)
	var target_height: int = maxi(0, int(pose.height)) if pose.has("height") else (0 if down else maxi(0, int(base_height + bound_y)))
	%Player.jump_height = target_height
	# Kill any leftover locomotion so the held player cannot slide out of the grab.
	%Player.velocity = Vector2.ZERO


func _reaction_state() -> String:
	# The active reaction object in the PvP/training runner is player_reaction
	# (training_player_reaction); the pack's hit_reaction is only used on the
	# dungeon path, so do not consult it here.
	return str(slice_run.player_reaction.state)


func _remote_action_id() -> int:
	if remote_skill <= 0:
		return 0
	return int(Game.slice_data.skills.get(str(remote_skill), {}).get("action", 0))


func _remote_grab_pose() -> Dictionary:
	# Mirrors grab_rules.grab_pose() using the attacker's replayed action instead of
	# a local monster. The original caught-target loop uses motion 13 even when
	# grab_rules.grab_pose() has no special override for this career or action.
	var peer_avatar: Dictionary = PeerSync.peer_state.get("avatar", {})
	var career: int = int(peer_avatar.get("career", 0))
	var action: int = _remote_action_id()
	if career == 110 and action == 116 and remote_stage == 1:
		return {"motion": 15, "frame": 1, "invert": false}
	if career != 330:
		return {"motion": 13, "frame": -1, "invert": false}
	if action not in [327, 329, 330, 335, 350]:
		return {"motion": 13, "frame": -1, "invert": false}
	var frame: int = int(remote_action.timeline.frame_index)
	var down: bool = (action == 329 and frame >= 6 and frame <= 10) or (action == 335 and frame >= 5 and frame <= 25)
	var invert: bool = (action == 327 and frame in [6, 7, 8, 12, 13, 14, 15, 18, 19]) or (action == 330 and frame in [6, 7, 8, 11, 12, 15, 16, 17, 20, 21, 22, 23, 24]) or (action == 350 and frame >= 15 and frame <= 18)
	return {"motion": 15 if down else 13, "frame": 1 if down else -1, "invert": invert}


func _apply_grab_pose(pose: Dictionary, visual) -> void:
	if not is_instance_valid(visual):
		return
	_restore_grab_reflection()
	if pose.is_empty():
		# Not a scripted grab: the reaction system stays in charge.
		if grab_pose_motion != 0:
			visual.end_action_motion()
			grab_pose_motion = 0
		return
	# Avatar body parts have their own motion 13, even though the player reaction
	# table only lists 11/12/15. Use the original caught pose when it exists.
	var target_motion: int = int(pose.motion)
	if target_motion == 13 and not _avatar_has_grab_motion(visual):
		target_motion = 12
	var pin_frame: int = int(pose.get("frame", -1)) if target_motion != 12 else 0
	if target_motion != grab_pose_motion:
		grab_pose_motion = target_motion
		grab_pose_last_msec = Time.get_ticks_msec()
		visual.begin_action_motion(target_motion, maxi(0, pin_frame))
		_trace("grab_pose", {"motion": target_motion,
			"career": int(PeerSync.peer_state.get("avatar", {}).get("career", 0)),
			"action": _remote_action_id(), "skill": remote_skill, "stage": remote_stage,
			"frame": int(remote_action.timeline.frame_index)})
	if pin_frame >= 0:
		visual.control_action_timeline("gotoAndStop", pin_frame)
	elif Time.get_ticks_msec() - grab_pose_last_msec >= 33:
		grab_pose_last_msec = Time.get_ticks_msec()
		visual.advance_action_motion()
	if bool(pose.get("invert", false)):
		_reflect_grab_parts(visual)


func _avatar_has_grab_motion(visual) -> bool:
	for part in visual.parts:
		if str(part.get("source_key", "")).begins_with("player_") and not part.get("motions", {}).get("13", []).is_empty():
			return true
	return false


func _restore_grab_reflection() -> void:
	for saved in grab_reflected_parts:
		if is_instance_valid(saved.sprite):
			saved.sprite.transform = saved.transform
	grab_reflected_parts.clear()


func _reflect_grab_parts(visual) -> void:
	var bounds: Rect2 = Rect2()
	for part in visual.parts:
		var sprite: Sprite2D = part.sprite
		if not is_instance_valid(sprite) or not sprite.visible or sprite.texture == null:
			continue
		var rect: Rect2 = sprite.transform * sprite.get_rect()
		bounds = rect if grab_reflected_parts.is_empty() else bounds.merge(rect)
		grab_reflected_parts.append({"sprite": sprite, "transform": sprite.transform})
	if grab_reflected_parts.is_empty():
		return
	var reflection := Transform2D(Vector2.RIGHT, Vector2.UP, Vector2(0, bounds.get_center().y * 2))
	for saved in grab_reflected_parts:
		saved.sprite.transform = reflection * saved.transform


func _note_grab_candidate(skill_id: int) -> void:
	# Only a hit that actually resolved may turn into a catch.
	if skill_id <= 0:
		return
	grab_pending_skill = skill_id
	grab_pending_msec = Time.get_ticks_msec() + 1200
	_trace("grab_hit", {"skill": skill_id, "armed": grab_armed_skill})
	if grab_armed_skill == skill_id and Time.get_ticks_msec() <= grab_armed_msec:
		_begin_grab()


func _begin_grab() -> void:
	if grab_active or current_map == null:
		return
	if slice_run.has_meta("jjxf_fatal_launched"):
		return
	grab_active = true
	grab_offset = remote_grab_binding
	grab_armed_skill = 0
	grab_pending_skill = 0
	grab_until_msec = Time.get_ticks_msec() + GRAB_MAX_MS
	slice_run.action_player.stop()
	slice_run.clear_action_inputs()
	slice_run.clear_interact_attacks()
	%Player.action_locked = true
	%Player.input_enabled = false
	%Player.velocity = Vector2.ZERO
	%Player.reset_jump()
	%Player.position = current_map.safe_position(remote_target_position + Vector2(grab_offset.x, grab_offset.z))
	_trace("grab_begin", {"offset_x": grab_offset.x, "offset_z": grab_offset.z})


func _end_grab() -> void:
	if not grab_active:
		return
	_restore_grab_reflection()
	grab_active = false
	grab_offset = Vector3.ZERO
	remote_grab_binding = Vector3.ZERO
	grab_pending_skill = 0
	grab_armed_skill = 0
	%Player.action_locked = slice_run.has_meta("jjxf_fatal_pending")
	if grab_pose_motion != 0 and is_instance_valid(%Player.get_node("Visual")):
		%Player.get_node("Visual").end_action_motion()
	grab_pose_motion = 0
	# Do not stomp a knockdown / get-up pose that the reaction system is still
	# playing; only fall back to idle when this player is genuinely free.
	if is_instance_valid(%Player.get_node("Visual")) and _reaction_state().is_empty() and not slice_run.has_meta("jjxf_fatal_pending"):
		%Player.get_node("Visual").set_motion(3, bool(%Player.get_node("Visual").facing_left))
	_trace("grab_end", {"reaction": _reaction_state()})


func _throw_grabbed(args: Dictionary) -> void:
	# The sender has already run the original throw_caught_targets(). Use its
	# resulting target position and the same launch/movement values here.
	if slice_run.has_meta("jjxf_fatal_launched"):
		_end_grab()
		return
	var facing: int = int(args.get("direction", 1))
	var origin: Vector2 = remote_target_position
	var base_height: float = float(remote_actor.jump_height) if is_instance_valid(remote_actor) else 0.0
	var point: Vector2 = current_map.safe_position(origin + Vector2(float(args.get("offsetX", 0)) * facing, float(args.get("offsetZ", 0))))
	if args.has("target_x") and args.has("target_y"):
		point = current_map.safe_position(Vector2(float(args.target_x), float(args.target_y)))
	var height: int = maxi(0, int(base_height + int(args.get("offsetY", 0))))
	if args.has("target_height"):
		height = maxi(0, int(args.target_height))
	_end_grab()
	%Player.position = point
	%Player.jump_height = height
	if slice_run.has_meta("jjxf_fatal_pending"):
		_trace("grab_throw_fatal", {"x": int(args.get("x", 0)), "y": int(args.get("y", 0))})
		return
	var power_x: int = int(args.get("x", 0))
	var power_y: int = int(args.get("y", 0))
	var reaction = slice_run.player_reaction
	reaction.reset()
	%Player.position = point
	%Player.jump_height = height
	reaction.accept({"power_x": power_x, "power_y": power_y, "air_power_x": power_x,
		"air_power_y": power_y, "random_dy": 0, "freeze": 0, "attack_type": 0}, facing)
	# The monster throw always starts an airborne movement, even when a skill's
	# power_y is below the normal knockdown threshold.
	if str(reaction.state) != "float":
		reaction.state = "float"
		reaction.height = height
		reaction.float_pose_index = 2
		reaction.float_launch_speed = maxi(power_y, 60)
		reaction.play_motion(12, 2)
	reaction.velocity = maxi(power_y, 60)
	if reaction.get("knockdown") != null:
		reaction.knockdown = true
	reaction.rebound = false
	%Player.action_locked = true
	%Player.input_enabled = false
	reaction.movement.execute({"x": mini(power_x, 1500) * int(args.get("mult", 3))}, facing, {}, 0)
	if reaction.has_method("hold_float_pose"):
		reaction.hold_float_pose()
	elif reaction.has_method("hold_training_float_pose"):
		reaction.hold_training_float_pose()
	reaction.render_height()
	_trace("grab_throw", {"x": power_x, "y": power_y, "mult": int(args.get("mult", 3)),
		"point": point, "height": height})


func _record_local_history() -> void:
	if current_map == null:
		return
	var player: Node2D = %Player
	var now: int = Time.get_ticks_msec()
	if not local_history.is_empty() and now - local_history_msec < 16:
		return
	local_history_msec = now
	local_history.append({"x": player.position.x, "y": player.position.y,
		"height": float(player.jump_height), "msec": now})
	while local_history.size() > 2 and now - int(local_history[0].msec) > REWIND_MS:
		local_history.pop_front()


func _update_remote_body() -> void:
	if peer_samples.is_empty():
		return
	# Watchdog: the peer body can only follow snapshots. If they stop arriving while
	# a round is running, the position (and every local hit test) silently freezes.
	var newest_sample: int = int(peer_samples[peer_samples.size() - 1].msec)
	var now_msec: int = Time.get_ticks_msec()
	if now_msec - newest_sample > 700 and round_id > 0 and not round_finished and now_msec - state_starve_traced_msec > 1000:
		state_starve_traced_msec = now_msec
		_trace("state_starved", {"age_ms": now_msec - newest_sample,
			"round": round_id, "grab": grab_active, "caught": bool(opponent.caught)})
	var target: int = Time.get_ticks_msec() - RENDER_DELAY_MS
	while peer_samples.size() >= 2 and int(peer_samples[1].msec) <= target:
		peer_samples.pop_front()
	var point: Vector2
	var height: float
	if peer_samples.size() == 1 or int(peer_samples[0].msec) >= target:
		point = Vector2(float(peer_samples[0].x), float(peer_samples[0].y))
		height = float(peer_samples[0].get("height", 0.0))
	else:
		var a: Dictionary = peer_samples[0]
		var b: Dictionary = peer_samples[1]
		var span: float = maxf(1.0, float(int(b.msec) - int(a.msec)))
		var t: float = clampf(float(target - int(a.msec)) / span, 0.0, 1.0)
		point = Vector2(float(a.x), float(a.y)).lerp(Vector2(float(b.x), float(b.y)), t)
		height = lerpf(float(a.get("height", 0.0)), float(b.get("height", 0.0)), t)
	remote_target_position = point
	# The original combat runner moves a caught target through targetBinding.
	# Replacing that target with a delayed peer snapshot erased both the binding
	# position and its airborne/grounded pose on the attacker's screen.
	if is_instance_valid(opponent) and (opponent.caught or _local_throw_active() or Time.get_ticks_msec() < caught_visual_until_msec):
		if is_instance_valid(remote_actor):
			remote_actor.position = opponent.position
			remote_actor.jump_height = int(opponent.air_height)
			remote_visual.position.y = -int(opponent.air_height)
		return
	# The body that is drawn and the body that is hit are the same object position.
	if is_instance_valid(opponent):
		opponent.position = point
		opponent.air_height = int(height)
	if is_instance_valid(remote_actor):
		remote_actor.position = point
		remote_actor.jump_height = int(height)
		if is_instance_valid(remote_visual):
			remote_visual.position.y = -height


func _original_target_pose() -> Dictionary:
	if not is_instance_valid(opponent):
		return {}
	if opponent.caught:
		var original: Dictionary = preload("res://scripts/grab_rules.gd").grab_pose(opponent)
		var motion: int = int(original.get("motion", opponent.motion))
		var frame: int = int(original.get("frame", opponent.animation_frame_ref))
		# Repeated hits can briefly replace the proxy's held pose with motion 11.
		# The original binding restores 13 on the next tick, so rendering both
		# produces the visible 11↔13 twitch on the attacker's screen.
		if original.is_empty() and motion in [3, 11]:
			motion = int(last_caught_pose.get("motion", 13))
			if motion not in [13, 15]:
				motion = 13
			frame = 1 if motion == 15 else -1
		elif motion == 15 and frame < 0:
			frame = 1
		last_caught_pose = {"motion": motion, "frame": frame,
			"invert": bool(original.get("invert", false)),
			"facing_left": bool(opponent.left),
			"x": float(opponent.position.x), "y": float(opponent.position.y),
			"height": float(opponent.air_height)}
		return last_caught_pose
	if _local_throw_active() and str(PeerSync.peer_state.get("reaction_state", "")).is_empty():
		return {"motion": int(opponent.motion), "frame": int(opponent.animation_frame_ref),
			"invert": false, "facing_left": bool(opponent.left),
			"x": float(opponent.position.x), "y": float(opponent.position.y),
			"height": float(opponent.air_height)}
	return last_caught_pose if Time.get_ticks_msec() < caught_visual_until_msec and not _local_throw_active() else {}


func _local_throw_active() -> bool:
	return Time.get_ticks_msec() < local_throw_until_msec and is_instance_valid(opponent) and (opponent.airborne or opponent.lie_ticks > 0 or opponent.dead)


func _update_remote_caught_visual() -> void:
	if not is_instance_valid(remote_visual):
		return
	var pose: Dictionary = _original_target_pose()
	_restore_remote_caught_reflection()
	if pose.is_empty():
		if remote_caught_motion != 0:
			if remote_reaction_state.is_empty() and not remote_action.active:
				remote_visual.end_action_motion()
			remote_caught_motion = 0
		last_caught_pose = {}
		return
	if remote_action.active:
		remote_action.stop()
	var motion: int = int(pose.get("motion", 13))
	if opponent.caught:
		remote_visual.facing_left = bool(opponent.left)
	if motion == 13 and not _avatar_has_grab_motion(remote_visual):
		motion = 12
	var frame: int = int(pose.get("frame", -1))
	if motion != remote_caught_motion or not remote_visual.external_clock:
		remote_caught_motion = motion
		remote_caught_last_msec = Time.get_ticks_msec()
		remote_visual.begin_action_motion(motion, maxi(0, frame))
		_trace("remote_caught_pose", {"motion": motion, "frame": frame,
			"skill": int(slice_run.current_skill)})
	if frame >= 0:
		remote_visual.control_action_timeline("gotoAndStop", frame)
	elif Time.get_ticks_msec() - remote_caught_last_msec >= 33:
		remote_caught_last_msec = Time.get_ticks_msec()
		remote_visual.advance_action_motion()
	if bool(pose.get("invert", false)):
		_reflect_remote_caught_parts()


func _restore_remote_caught_reflection() -> void:
	for saved in remote_caught_reflected_parts:
		if is_instance_valid(saved.sprite):
			saved.sprite.transform = saved.transform
	remote_caught_reflected_parts.clear()


func _reflect_remote_caught_parts() -> void:
	var bounds: Rect2 = Rect2()
	for part in remote_visual.parts:
		var sprite: Sprite2D = part.sprite
		if not is_instance_valid(sprite) or not sprite.visible or sprite.texture == null:
			continue
		var rect: Rect2 = sprite.transform * sprite.get_rect()
		bounds = rect if remote_caught_reflected_parts.is_empty() else bounds.merge(rect)
		remote_caught_reflected_parts.append({"sprite": sprite, "transform": sprite.transform})
	if remote_caught_reflected_parts.is_empty():
		return
	var reflection := Transform2D(Vector2.RIGHT, Vector2.UP, Vector2(0, bounds.get_center().y * 2))
	for saved in remote_caught_reflected_parts:
		saved.sprite.transform = reflection * saved.transform


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var key := event as InputEventKey
	if chat_open:
		if key.physical_keycode == KEY_ESCAPE or key.keycode == KEY_ESCAPE:
			_close_chat()
			get_viewport().set_input_as_handled()
		return
	if key.physical_keycode == KEY_ENTER or key.keycode == KEY_ENTER \
			or key.physical_keycode == KEY_KP_ENTER or key.keycode == KEY_KP_ENTER:
		if not round_finished and not loading.busy:
			_open_chat()
			get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if chat_open:
		return
	if round_finished and PeerSync.my_role == "host" and event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_R:
		_begin_round(round_id + 1)
		get_viewport().set_input_as_handled()


func snapshot() -> Dictionary:
	var player: CharacterBody2D = %Player
	var visual: Node2D = player.get_node("Visual")
	# The PvP run extends training_run. Its active victim clock is player_reaction;
	# hit_reaction belongs to the dungeon path and stays empty here.
	var reaction = slice_run.player_reaction
	var reaction_state: String = str(reaction.state)
	var reaction_frame: int = int(reaction.movie.timeline.frame_index)
	if reaction_state == "float":
		reaction_frame = int(reaction.float_pose_index)
	elif reaction_state == "lie":
		reaction_frame = 1
	elif reaction_state in ["stiff", "hurt"]:
		reaction_frame = 0
	return {"x": player.position.x, "y": player.position.y, "height": float(player.jump_height),
		"ready": current_map != null and not loading.busy and slice_run.active,
		"defeat_ready": slice_run.status == "defeat",
		"hp_self": int(slice_run.hp),
		"hp_peer": int(opponent.hp) if is_instance_valid(opponent) else 500000,
		"mp_self": int(slice_run.mp),
		"facing_left": bool(visual.facing_left), "motion": clampi(int(visual.motion), 0, 10000),
		"skill": int(slice_run.current_skill), "stage": clampi(int(slice_run.combo), 0, 10),
		"action": int(slice_run.action_serial),
		"action_frame": clampi(int(slice_run.action_player.timeline.frame_index), 0, 1000),
		"reaction_state": reaction_state,
		"reaction_frame": clampi(reaction_frame, 0, 1000),
		"statuses": _status_ids_with_mp(),
		"caught_pose": _original_target_pose(),
		"grab_binding": {"x": float(slice_run.target_binding.get("x", 0)),
			"y": float(slice_run.target_binding.get("y", 0)),
			"z": float(slice_run.target_binding.get("z", 0))} if not slice_run.target_binding.is_empty() else {}}


func _on_peer_state(value: Dictionary) -> void:
	if current_map == null:
		return
	var avatar: Dictionary = value.get("avatar", {})
	if avatar.is_empty():
		return
	var binding: Dictionary = value.get("grab_binding", {})
	if not binding.is_empty():
		remote_grab_binding = Vector3(float(binding.get("x", 0)), float(binding.get("y", 0)), float(binding.get("z", 0)))
		if grab_active:
			grab_offset = remote_grab_binding
	peer_samples.append({"msec": Time.get_ticks_msec(),
		"x": float(value.get("x", 0)), "y": float(value.get("y", 0)),
		"height": float(value.get("height", 0))})
	while peer_samples.size() > 12:
		peer_samples.pop_front()
	if not is_instance_valid(opponent):
		var target = preload("res://_multiplayer/pvp_target.gd").new()
		target.spec = Game.slice_data.monsters["20603"].duplicate(true)
		target.spec.level = int(avatar.get("level", 1))
		target.monster_id = 20603
		target.run = slice_run
		target.position = Vector2(float(value.get("x", 0)), float(value.get("y", 0)))
		current_map.add_child(target)
		target.hit_resolved.connect(_on_opponent_hit)
		target.set_peer_attributes(avatar.get("combat_attrs", {}), int(avatar.get("level", 1)))
		slice_run.monsters.append(target)
		opponent = target
		if PeerSync.solo:
			return
		remote_actor = preload("res://_multiplayer/pvp_remote_actor.gd").new()
		remote_actor.name = "RemoteFighter"
		remote_actor.position = target.position
		remote_target_position = target.position
		add_child(remote_actor)
		remote_visual = preload("res://scripts/avatar_view.gd").new()
		remote_visual.name = "Visual"
		remote_actor.add_child(remote_visual)
		remote_visual.scale = Vector2.ONE * (160.0 / 151.0)
		remote_visual_run = preload("res://_multiplayer/pvp_visual_run.gd").new()
		remote_visual_run.name = "RemoteVisualRun"
		remote_visual_run.world = self
		remote_visual_run.player = remote_actor
		remote_visual_run.action_player = remote_action
		remote_visual_run.combat_random = slice_run.combat_random
		remote_visual_run.source_status = opponent.skill_status
		remote_visual_run.arena_run = slice_run
		add_child(remote_visual_run)
		remote_visual_target = preload("res://_multiplayer/pvp_visual_target.gd").new()
		remote_visual_target.name = "RemoteVisualTarget"
		add_child(remote_visual_target)
		remote_visual_target.configure(%Player, slice_run)
		remote_visual_run.monsters = [remote_visual_target]
		slice_run.visual_run = remote_visual_run
		remote_action.state_started.connect(_on_remote_action_state)
		remote_action.frame_ready.connect(_on_remote_action_frame)
		remote_action.script_requested.connect(_on_remote_action_script)
		remote_action.timeline_command.connect(_on_remote_timeline_command)
		remote_action.finished.connect(_on_remote_action_finished)
	# HP is only synced while a round is actually being fought. Applying a stale
	# "hp_peer = 0" from the previous round is what killed a guest right after the
	# host started the next one.
	if PeerSync.my_role == "guest" and round_id > 0 and not round_finished and str(slice_run.status) == "battle":
		if value.has("hp_self"):
			opponent.hp = clampi(int(value.hp_self), 0, opponent.max_hp)
		if value.has("hp_peer") and int(value.hp_peer) != slice_run.hp:
			slice_run.hp = clampi(int(value.hp_peer), 0, slice_run.max_hp)
			slice_run.state_changed.emit()
	var statuses: Array = []
	for entry in value.get("statuses", []):
		var text: String = str(entry)
		if text.begins_with("9999") and text.length() == 12:
			peer_mp_value = int(text.substr(4))
			continue
		statuses.append(text)
	# Once the relay is redeployed it forwards a real mp_self field; prefer it and
	# keep the statuses sentinel as the fallback for older deployments.
	if value.has("mp_self"):
		peer_mp_value = clampi(int(value.mp_self), 0, 99999999)
	for key in opponent.skill_status.active.keys():
		if key not in statuses:
			opponent.skill_status.active.erase(key)
	for key in statuses:
		if not opponent.skill_status.active.has(str(key)):
			opponent.skill_status.add(str(key))
	var key: String = JSON.stringify(avatar)
	if key != remote_avatar_key and not (remote_visual.external_clock and remote_visual.action_parts_clock):
		remote_avatar_key = key
		remote_visual.configure(avatar)
		var career: int = int(avatar.get("career", 0))
		var motions: Dictionary = Game.slice_data.motions.duplicate()
		motions.merge(Game.career_combat.get("career_motions", {}).get(str(Game.base_career(career)), {}), true)
		remote_action.configure(Game.flash_actions, motions)
		remote_visual_run.attack_model = DamageCalculator.from_equipment_attributes(
			avatar.get("combat_attrs", {}), int(avatar.get("level", 1)))
	remote_visual.facing_left = bool(value.get("facing_left", false))
	var skill_id: int = int(value.get("skill", 0))
	remote_visual_run.current_skill = skill_id
	var stage: int = int(value.get("stage", 0))
	var serial: int = int(value.get("action", 0))
	# Track the opponent's get-up protection before anything can return early.
	var peer_reaction_state: String = str(value.get("reaction_state", ""))
	var now_protect: int = Time.get_ticks_msec()
	if peer_reaction_state == "get_up":
		peer_protect_until_msec = now_protect + PEER_PROTECT_GRACE_MS
	elif peer_was_getting_up:
		peer_protect_until_msec = maxi(peer_protect_until_msec, now_protect + PEER_PROTECT_GRACE_MS)
	peer_was_getting_up = peer_reaction_state == "get_up"
	if opponent.caught or (Time.get_ticks_msec() < caught_visual_until_msec and not _local_throw_active()):
		if remote_action.active:
			remote_action.stop()
		remote_reaction_state = ""
		_update_remote_caught_visual()
		return
	var reaction_state: String = str(value.get("reaction_state", ""))
	if reaction_state in ["stiff", "hurt", "float", "lie", "get_up"]:
		if remote_action.active:
			remote_action.stop()
		grab_remote_pin = 0
		var reaction_motion: int = 12 if reaction_state == "float" else (15 if reaction_state in ["lie", "get_up"] else 11)
		var reaction_frame: int = int(value.get("reaction_frame", 0))
		# Motion 15 is "lie down (0-1) + get up (2-...)". Following the reported
		# frame replays the whole clip and loops it, which looked like the loser
		# doing sit-ups. A lying body is a resting pose: pin the lying frame and let
		# the state change (get_up) end it. Same for the stiff/held pose at frame 0.
		if reaction_state == "lie":
			reaction_frame = 1
		elif reaction_state in ["stiff", "hurt"]:
			reaction_frame = 0
		elif reaction_state == "get_up":
			reaction_frame = maxi(2, reaction_frame)
		if remote_reaction_state != reaction_state or remote_reaction_motion != reaction_motion or not remote_visual.external_clock:
			remote_visual.begin_action_motion(reaction_motion, reaction_frame)
			remote_reaction_motion = reaction_motion
		else:
			remote_visual.control_action_timeline("gotoAndStop", reaction_frame)
		remote_reaction_state = reaction_state
		return
	if not remote_reaction_state.is_empty():
		remote_visual.end_action_motion()
		remote_reaction_state = ""
		remote_reaction_motion = 0
	if skill_id > 0:
		remote_action_seen_msec = Time.get_ticks_msec()
	# A multi-stage original skill may end one local replay state before the next
	# network snapshot arrives. Resume its next stage instead of leaving the
	# opponent in the fallback standing pose for the rest of that skill.
	if skill_id > 0 and (serial != remote_action_serial or (not remote_action.active and stage != remote_stage)):
		var spec: Dictionary = Game.slice_data.skills.get(str(skill_id), {})
		if not spec.is_empty():
			remote_skill = skill_id
			remote_action.facing = -1 if remote_visual.facing_left else 1
			var speed: int = int(avatar.get("combat_attrs", {}).get("2018", 100))
			if remote_action.begin(int(avatar.get("career", 0)), int(spec.get("action", 0)), speed):
				if stage > 0:
					remote_action.set_state(stage)
				remote_stage = stage
				remote_action_serial = serial
			else:
				remote_skill = 0
	elif skill_id > 0 and serial == remote_action_serial and stage != remote_stage and remote_action.active:
		remote_action.set_state(stage)
		remote_stage = stage
	elif skill_id == 0 and remote_skill != 0:
		remote_action.stop()
		remote_visual.end_action_motion()
		remote_skill = 0
		remote_stage = -1
	if remote_action.active and remote_visual.external_clock:
		var frame: int = int(value.get("action_frame", -1))
		if frame >= 0 and absi(int(remote_action.timeline.frame_index) - frame) > 1:
			remote_visual.control_action_timeline("gotoAndPlay", frame)
	if not remote_action.active:
		var fallback_motion: int = int(value.get("motion", 3))
		# The victim's grab pose arrives as a plain motion id (12 held / 15 lying)
		# because the grab does not use a player reaction state. Motion 15 contains
		# the whole 躺下→起身 clip, so following it loops the body -- pin the pose.
		# Motion 11 is the flinch: after a stiff state ends the id can still be 11 for
		# a moment, and playing it as a normal motion loops the flinch (抽搐).
		if fallback_motion in [11, 12, 15]:
			var fallback_frame: int = 1 if fallback_motion == 15 else 0
			if grab_remote_pin != fallback_motion:
				grab_remote_pin = fallback_motion
				remote_visual.begin_action_motion(fallback_motion, fallback_frame)
			remote_visual.control_action_timeline("gotoAndStop", fallback_frame)
		else:
			if grab_remote_pin != 0:
				grab_remote_pin = 0
				remote_visual.end_action_motion()
			remote_visual.set_motion(fallback_motion, remote_visual.facing_left)
	if PeerSync.my_role == "host" and (round_id == 0 or peer_departed) and bool(value.get("ready", false)):
		_begin_round(round_id + 1)


func _on_peer_left() -> void:
	_end_grab()
	_close_chat()
	_restore_remote_caught_reflection()
	remote_caught_motion = 0
	last_caught_pose = {}
	local_throw_until_msec = 0
	peer_samples.clear()
	local_history.clear()
	last_opponent_caught = false
	caught_release_started_msec = 0
	caught_visual_until_msec = 0
	peer_mp_value = 0
	peer_protect_until_msec = 0
	peer_was_getting_up = false
	last_peer_control_id = 0
	if is_instance_valid(opponent):
		slice_run.monsters.erase(opponent)
		opponent.queue_free()
	opponent = null
	if is_instance_valid(remote_actor):
		remote_actor.queue_free()
	remote_actor = null
	if is_instance_valid(remote_visual_run):
		remote_visual_run.queue_free()
	remote_visual_run = null
	if is_instance_valid(remote_visual_target):
		remote_visual_target.queue_free()
	remote_visual_target = null
	slice_run.visual_run = null
	remote_visual = null
	remote_action.stop()
	remote_reaction_state = ""
	remote_reaction_motion = 0
	slice_run.clear_remote_visual_interacts()
	remote_skill = 0
	remote_stage = -1
	remote_action_serial = -1
	remote_action_seen_msec = 0
	remote_avatar_key = ""
	round_finished = true
	peer_departed = true
	if is_instance_valid(result_label):
		result_label.text = "对方已离开房间"
		result_label.show()


func _begin_round(id: int) -> void:
	if current_map == null or id <= round_id:
		return
	round_id = id
	round_finished = false
	round_started_msec = Time.get_ticks_msec()
	round_limit_until_msec = 0
	_close_chat()
	guest_ready = false
	_apply_result_button_state()
	peer_departed = false
	# A new round starts from a clean timeline; otherwise the buffered bodies
	# would interpolate back to where they stood before the reset.
	if not PeerSync.solo:
		peer_samples.clear()
	local_history.clear()
	_end_grab()
	_restore_remote_caught_reflection()
	remote_caught_motion = 0
	last_caught_pose = {}
	local_throw_until_msec = 0
	last_opponent_caught = false
	caught_release_started_msec = 0
	caught_visual_until_msec = 0
	peer_mp_value = 0
	peer_protect_until_msec = 0
	peer_was_getting_up = false
	last_peer_control_id = 0
	result_label.hide()
	slice_run.reset_player()
	%Player.position = current_map.safe_position(Vector2(780, 390) if PeerSync.my_role == "host" else Vector2(1100, 500))
	if is_instance_valid(opponent):
		opponent.reset_for_round(current_map.safe_position(
			Vector2(1100, 500) if PeerSync.my_role == "host" else Vector2(780, 390)))
	slice_run.clear_remote_visual_interacts()
	remote_action.stop()
	remote_skill = 0
	remote_stage = -1
	slice_run.start_countdown()
	if PeerSync.my_role == "host":
		PeerSync.send_round({"type": "round", "id": round_id, "phase": "start"})


func _finish_round(winner: String) -> void:
	if round_finished:
		return
	round_finished = true
	%Player.input_enabled = false
	%Player.action_locked = true
	slice_run.action_player.stop()
	slice_run.clear_interact_attacks()
	slice_run.clear_remote_visual_interacts()
	remote_action.stop()
	result_label.text = ("胜利" if winner == PeerSync.my_role else "失败") + (" · 房主按 R 再开一局" if PeerSync.my_role == "host" else " · 等待房主再开一局")
	result_label.show()
	if PeerSync.my_role == "host":
		PeerSync.send_round({"type": "round", "id": round_id, "phase": "end", "winner": winner})


func _on_round(value: Dictionary) -> void:
	var id: int = int(value.get("id", 0))
	if str(value.get("phase", "")) == "start":
		_begin_round(id)
	elif str(value.get("phase", "")) == "end" and id == round_id:
		_finish_round(str(value.get("winner", "")))


func _on_remote_action_state(stage: int, motion_id: int, frame_ref: int) -> void:
	remote_stage = stage
	if is_instance_valid(remote_visual):
		remote_visual.begin_action_motion(motion_id, frame_ref, remote_action.attack_speed)
	_apply_remote_functions(remote_skill, stage, 3)


func _on_remote_action_frame(_packet: Dictionary) -> void:
	if is_instance_valid(remote_visual):
		remote_visual.advance_action_motion()


func _on_remote_timeline_command(command: String, frame_ref: int) -> void:
	if is_instance_valid(remote_visual):
		remote_visual.control_action_timeline(command, frame_ref)


func _on_remote_action_script(command: String, args: Dictionary) -> void:
	if command == "createEffect" and is_instance_valid(remote_actor):
		preload("res://scripts/slice_effect.gd").spawn(remote_actor, args)
	elif command == "createInteract" and is_instance_valid(remote_actor):
		var avatar: Dictionary = PeerSync.peer_state.get("avatar", {})
		var model: Dictionary = DamageCalculator.from_equipment_attributes(avatar.get("combat_attrs", {}), int(avatar.get("level", 1)))
		slice_run.spawn_remote_visual_interact(args, remote_skill, remote_stage,
			remote_actor.position, float(remote_actor.jump_height), remote_action.facing, remote_actor, model)
	elif command == "playSound" and is_instance_valid(remote_actor):
		audio.play_script(args, remote_actor)
	elif command == "applyFunction":
		_apply_remote_functions(remote_skill, remote_stage, 2 if str(args.get("argStr", "")) == "start" else 1)
	elif command == "catchTarget":
		# The attacker's action says "this frame catches the target". The catch is
		# armed here and only fires when the matching hit really resolves: on a
		# network the frame script is replayed before the hit message arrives, so
		# both orders have to work.
		if int(args.get("argStr", 0)) > 0:
			var armed: int = remote_skill if remote_skill > 0 else grab_pending_skill
			grab_armed_skill = armed
			grab_armed_msec = Time.get_ticks_msec() + 1500
			_trace("grab_arm", {"skill": armed, "pending": grab_pending_skill})
			if grab_pending_skill > 0 and grab_pending_skill == armed and Time.get_ticks_msec() <= grab_pending_msec:
				_begin_grab()
	elif command == "targetBinding":
		# Keep the last binding even if it arrives before the catch activates.
		if int(args.get("release", 0)) == 1:
			grab_offset = Vector3.ZERO
		else:
			grab_offset = Vector3(float(args.get("x", 0)), float(args.get("y", 0)), float(args.get("z", 0)))
	elif command == "throwTarget":
		# The attacker's original runner sends the resolved throw, including the
		# actual target position. Its replay can run early or late on this client.
		pass


func _apply_remote_functions(skill_id: int, stage: int, phase: int) -> void:
	if not is_instance_valid(opponent) or skill_id <= 0:
		return
	var fields: Array = Game.career_combat.fields.get(str(skill_id), [])
	if stage < 0 or stage >= fields.size():
		return
	var phases: Array = fields[stage].get("functions", [])
	if phase >= phases.size():
		return
	for key in str(phases[phase]).split(",", false):
		var function: Dictionary = Game.career_combat.functions.get(key, {})
		for effect in function.get("effects", []):
			if int(effect.get("data_type", 0)) == 4:
				opponent.skill_status.add(str(effect.get("data_1", 0)))


func _on_remote_action_finished(_next_vkey: int) -> void:
	remote_skill = 0
	# Keep the completed stage number until the peer reports the next one.
	# Clearing it here made a still-active skill restart its same stage on every
	# 20 Hz state packet, overriding the correct animation with its first frame.
	# An action replay can finish before the delayed release/control packet arrives.
	# The caught player is released by targetBinding/throwTarget or the authoritative
	# control event, with GRAB_MAX_MS as a final timeout.
	if is_instance_valid(remote_visual):
		remote_visual.end_action_motion()


func _on_opponent_hit(amount: int, remaining_hp: int, reaction: Dictionary, direction: int, skill_id: int, stage: int) -> void:
	if round_finished:
		return
	if _peer_protected():
		_revert_protected_hit(amount, skill_id)
		return
	if PeerSync.my_role == "guest":
		hit_request_id += 1
		PeerSync.send_hit_request({"type": "hit_request", "id": hit_request_id,
			"skill": skill_id, "stage": stage,
			"action": int(slice_run.action_serial),
			"x": %Player.position.x, "y": %Player.position.y,
			"height": int(%Player.jump_height),
			"facing_left": bool(%Player.get_node("Visual").facing_left)})
		_trace("send_request", {"id": hit_request_id, "skill": skill_id, "stage": stage,
			"x": snappedf(%Player.position.x, 0.1), "y": snappedf(%Player.position.y, 0.1),
			"seen_x": snappedf(remote_target_position.x, 0.1),
			"seen_y": snappedf(remote_target_position.y, 0.1)})
		return
	if PeerSync.my_role != "host":
		return
	var spec: Dictionary = Game.slice_data.skills.get(str(skill_id), {})
	reaction = reaction.duplicate()
	if not spec.is_empty() and stage < spec.get("hits", []).size():
		reaction.attack_type = int(spec.hits[stage].get("attack", 0))
	# Carry the skill identity inside the reaction object so the victim applies the
	# same skill functions locally. The relay already validates and forwards this
	# object, so no protocol change is needed.
	reaction["skill"] = skill_id
	reaction["stage"] = stage
	# The host owns the caught state of the guest body; tell the guest explicitly
	# instead of relying on frame script replay timing.
	if is_instance_valid(opponent) and bool(opponent.caught):
		reaction["control"] = "caught"
	PeerSync.send_combat({"type": "combat", "id": maxi(1, slice_run.ticks),
		"target": "guest", "reaction": reaction,
		"attacker_x": %Player.position.x, "attacker_y": %Player.position.y,
		"attacker_height": int(%Player.jump_height),
		"hp_host": int(slice_run.hp), "hp_guest": remaining_hp,
		"impulse": direction, "knockdown": false, "power": int(reaction.get("power_y", 0)),
		"power_x": int(reaction.get("power_x", 0)), "freeze": int(reaction.get("freeze", 0)),
		"damage": amount})


func _on_hit_request(value: Dictionary) -> void:
	if PeerSync.my_role != "host" or round_finished or slice_run.status != "battle":
		return
	var id: int = int(value.get("id", 0))
	if id >= CONTROL_ID_BASE:
		# Control event from the guest: 1 = caught, 0 = released, 2 = thrown.
		if id <= last_peer_control_id:
			return
		last_peer_control_id = id
		if int(value.get("stage", 0)) == 1 and (_peer_protected() or _local_protected()):
			_trace("refuse_control_protected", {"id": id,
				"peer": _peer_protected(), "local": _local_protected()})
			return
		if int(value.get("stage", 0)) == 2:
			_throw_grabbed(value.get("throw_args", {}))
		elif int(value.get("stage", 0)) == 1:
			_note_grab_candidate(int(value.get("skill", 0)))
			_begin_grab()
		else:
			_end_grab()
		return
	if id <= last_peer_hit_id:
		_trace("reject_duplicate", {"id": id, "last": last_peer_hit_id})
		return
	last_peer_hit_id = id
	if _peer_protected():
		_trace("reject_peer_protected", {"id": id, "skill": int(value.get("skill", 0))})
		return
	var peer: Dictionary = PeerSync.peer_state
	var avatar: Dictionary = peer.get("avatar", {})
	var skill_id: int = int(value.get("skill", 0))
	var stage: int = int(value.get("stage", 0))
	var spec: Dictionary = Game.slice_data.skills.get(str(skill_id), {})
	if avatar.is_empty() or spec.is_empty() or spec.get("hits", []).is_empty():
		_trace("reject_no_spec", {"id": id, "skill": skill_id, "avatar": not avatar.is_empty()})
		return
	var projectile_active: bool = slice_run.remote_visual_interacts.any(func(attack): return is_instance_valid(attack) and not attack.ended and int(attack.skill_id) == skill_id)
	var action_matches: bool = int(value.get("action", -1)) == remote_action_serial and \
		Time.get_ticks_msec() - remote_action_seen_msec <= 800
	var peer_skill: int = int(peer.get("skill", 0))
	var recent_action_msec: int = Time.get_ticks_msec() - remote_action_seen_msec
	# A four hit normal-attack combo advances the action serial faster than a
	# state packet can carry it, so demanding an exact serial (or a still-current
	# skill id) dropped the 2nd-4th hits while slower skills always matched. Accept
	# the request while the guest is clearly still inside an action; the hitbox and
	# rewind tests below still screen the actual contact.
	var action_recent: bool = recent_action_msec <= 1200
	if peer_skill != skill_id and not action_matches and not projectile_active and not action_recent:
		_trace("reject_action_mismatch", {"id": id, "skill": skill_id,
			"peer_skill": peer_skill, "action": int(value.get("action", -1)),
			"remote_serial": remote_action_serial, "recent_ms": recent_action_msec})
		return
	var origin: Vector2 = Vector2(float(value.get("x", 0)), float(value.get("y", 0)))
	var latest: Vector2 = Vector2(float(peer.get("x", 0)), float(peer.get("y", 0)))
	var facing_left: bool = bool(value.get("facing_left", peer.get("facing_left", false)))
	var peer_height: float = float(value.get("height", peer.get("height", 0)))
	if origin.distance_to(latest) > 100.0:
		# The guest's local hit already resolved against the body it could see.
		# Refusing the request here is exactly what turned a 3 hit combo into 1 hit
		# of damage. Trust the guest's latest reported position instead.
		_trace("clamp_origin", {"id": id, "dist": snappedf(origin.distance_to(latest), 0.1)})
		origin = latest
	if not _attacker_view_reaches(avatar, spec, stage, origin, facing_left, peer_height):
		# The guest's own copy of the original combat already resolved this hit with
		# the original hitbox data, so re-testing every frame box here is a second
		# opinion, not the truth. A standing normal attack routinely fails this
		# re-test (depth offset / frame selection) while jump and running attacks
		# pass, which is exactly the pattern of "only standing attacks lose damage".
		# Keep a distance sanity check instead of rejecting outright.
		var gap: float = origin.distance_to(%Player.position)
		if gap > 220.0:
			_trace("reject_out_of_range", {"id": id, "skill": skill_id, "stage": stage,
				"dx": snappedf(origin.x - %Player.position.x, 0.1),
				"dy": snappedf(origin.y - %Player.position.y, 0.1),
				"gap": snappedf(gap, 0.1),
				"history": local_history.size()})
			return
		_trace("lenient_reach", {"id": id, "skill": skill_id, "stage": stage,
			"gap": snappedf(gap, 0.1), "history": local_history.size()})
	# The guest told us where it stood when it swung; keep its buffered body there
	# instead of letting the delayed interpolation keep drawing the older spot.
	if is_instance_valid(remote_actor):
		if peer_samples.is_empty():
			peer_samples.append({"msec": Time.get_ticks_msec(), "x": origin.x,
				"y": origin.y, "height": peer_height})
		else:
			var origin_sample: Dictionary = peer_samples[peer_samples.size() - 1]
			origin_sample["x"] = origin.x
			origin_sample["y"] = origin.y
			origin_sample["height"] = peer_height
	var hit: Dictionary = spec.hits[mini(stage, spec.hits.size() - 1)]
	var attacker: Dictionary = DamageCalculator.from_equipment_attributes(avatar.get("combat_attrs", {}), int(avatar.get("level", 1)))
	if is_instance_valid(opponent):
		attacker = opponent.skill_status.model(attacker)
	var defender: Dictionary = slice_run.source_status.model(DamageCalculator.from_equipment_attributes(Game.character_attributes(), int(Game.role().level)))
	var facing: int = -1 if facing_left else 1
	var target_facing: int = -1 if %Player.get_node("Visual").facing_left else 1
	var result: Dictionary = DamageCalculator.calculate(attacker, defender, hit, facing, target_facing, slice_run.current_skill != 0, slice_run.combat_random.next_float)
	if bool(result.miss):
		_trace("reject_miss", {"id": id, "skill": skill_id, "stage": stage})
		return
	var reactions: Array = Game.career_combat.fields.get(str(skill_id), slice_run.reaction_data.skills.get(str(skill_id), []))
	var reaction: Dictionary = reactions[stage] if stage < reactions.size() else {}
	reaction = reaction.duplicate()
	reaction.attack_type = int(hit.get("attack", 0))
	if is_instance_valid(opponent) and bool(opponent.caught):
		reaction["control"] = "caught"
	var before_hp: int = int(slice_run.hp)
	slice_run.receive_monster_hit(int(result.damage), reaction, facing)
	slice_run.apply_skill_functions(skill_id, stage, 0, %Player)
	# If the original reaction gate swallows this hit, the guest sees "my attack
	# did nothing". Record that instead of hiding it.
	_trace("accept_hit", {"id": id, "skill": skill_id, "stage": stage,
		"calc": int(result.damage), "hp_before": before_hp, "hp_after": int(slice_run.hp),
		"invincible": int(slice_run.invincible),
		"reaction": str(slice_run.player_reaction.state)})
	# Only a hit that actually took health may become a catch. While this player is
	# in get-up protection the pack swallows the damage, so the grab must not start
	# either -- otherwise the protected side still gets locked.
	if int(slice_run.hp) < before_hp and not _local_protected():
		_note_grab_candidate(skill_id)
	PeerSync.send_combat({"type": "combat", "id": maxi(1, slice_run.ticks),
		"target": "host", "reaction": reaction,
		"attacker_x": origin.x, "attacker_y": origin.y,
		"attacker_height": int(value.get("height", 0)),
		"hp_host": int(slice_run.hp), "hp_guest": int(opponent.hp) if is_instance_valid(opponent) else 500000,
		"impulse": facing, "knockdown": false, "power": int(reaction.get("power_y", 0)),
		"power_x": int(reaction.get("power_x", 0)), "freeze": int(reaction.get("freeze", 0)),
		"damage": int(result.damage)})


func _peer_hitbox_reaches(avatar: Dictionary, spec: Dictionary, stage: int, origin: Vector2,
		facing_left: bool, peer_height: float, target_x: float, target_y: float,
		target_height: float) -> bool:
	var career: int = int(avatar.get("career", 0))
	var state: Dictionary = Game.flash_actions.state(career, int(spec.get("action", 0)), stage)
	var motions: Dictionary = Game.slice_data.motions.duplicate()
	motions.merge(Game.career_combat.get("career_motions", {}).get(str(Game.base_career(career)), {}), true)
	var motion: Dictionary = motions.get(str(int(state.get("motion_id", -1))), {})
	var facing: int = -1 if facing_left else 1
	var x: float = (target_x - origin.x) * facing
	var z: float = absf(target_y - origin.y)
	var relative_air: float = peer_height - target_height
	for frame in motion.get("frames", []):
		for area in frame.get("areas", []):
			if str(area.get("type", "")) == "ac" and x + 20 >= float(area.get("x", 0)) and x - 20 <= float(area.get("x", 0)) + float(area.get("w", 0)) and z <= float(area.get("dz", 0)) + 5 and relative_air >= float(area.get("y", 0)) and relative_air - 160.0 <= float(area.get("y", 0)) + float(area.get("h", 0)):
				return true
	# createInteract attacks travel independently of the player action frame.
	for attack in slice_run.remote_visual_interacts:
		if not is_instance_valid(attack) or attack.ended or int(attack.skill_id) != int(spec.get("id", 0)):
			continue
		var frames: Array = attack.timeline.frames
		if frames.is_empty():
			continue
		for offset in [-3, -2, -1, 0, 1]:
			var frame_index: int = int(attack.timeline.frame_index) + offset
			if frame_index < 0 or frame_index >= frames.size():
				continue
			for area in frames[frame_index].get("areas", []):
				if str(area.get("type", "")) != "ac":
					continue
				var shot_x: float = (target_x - attack.position.x) * int(attack.facing)
				var shot_z: float = absf(target_y - attack.position.y)
				var shot_air: float = float(attack.height) - target_height
				if shot_x + 35 >= float(area.get("x", 0)) and shot_x - 35 <= float(area.get("x", 0)) + float(area.get("w", 0)) and shot_z <= float(area.get("dz", 0)) + 20 and shot_air >= float(area.get("y", 0)) - 35 and shot_air - 160.0 <= float(area.get("y", 0)) + float(area.get("h", 0)) + 35:
					return true
	return false


func peer_height_from_snapshot() -> float:
	return float(PeerSync.peer_state.get("height", 0))


func _attacker_view_reaches(avatar: Dictionary, spec: Dictionary, stage: int, origin: Vector2,
		facing_left: bool, peer_height: float) -> bool:
	# Same original hit test, evaluated at the attacker's point of view.
	# First try the current position (the common, zero-latency case).
	if _peer_hitbox_reaches(avatar, spec, stage, origin, facing_left, peer_height,
			%Player.position.x, %Player.position.y, float(%Player.jump_height)):
		return true
	# Over the internet the guest was aiming at a body that is now up to
	# REWIND_MS old. Re-run the identical test against the positions this player
	# actually held during that window, so the hit lands where it was seen.
	for sample in local_history:
		if _peer_hitbox_reaches(avatar, spec, stage, origin, facing_left, peer_height,
				float(sample.x), float(sample.y), float(sample.height)):
			return true
	return false


func _setup_result_panel() -> void:
	# Reuse the original defeat window (same art, same layout) but take over its
	# caption and its buttons. The single player "重新挑战" re-enters the training
	# scene with default values, which is exactly what must not happen in PvP.
	var overlay: Node = get_node_or_null("HUDOverlay")
	if overlay == null:
		return
	result_panel = overlay.find_child("Defeat", true, false) as Control
	if result_panel == null:
		_trace("result_panel_missing", {})
		return
	for child in result_panel.get_children():
		if child is Label:
			(child as Label).text = "本局结束"
	var buttons: Array = []
	for child in result_panel.get_children():
		if child is TextureButton:
			buttons.append(child)
	if buttons.is_empty():
		return
	result_button_primary = buttons[0] as TextureButton
	_rewire_button(result_button_primary, "", _on_result_button)
	for sub in result_button_primary.get_children():
		if sub is Label:
			result_button_label = sub as Label
			break
	# "返回城镇" makes no sense in a duel: quit the program instead. The same is
	# applied to the in battle exit button of the original HUD.
	if buttons.size() > 1:
		_rewire_button(buttons[1] as TextureButton, "退出游戏", _quit_game)
	var exit_button = overlay.get("exit_button")
	if exit_button is TextureButton:
		_rewire_button(exit_button as TextureButton, "退出游戏", _quit_game)
	_apply_result_button_state()
	_trace("result_panel_ready", {"role": PeerSync.my_role})


func _rewire_button(button: TextureButton, caption: String, callback: Callable) -> void:
	if button == null:
		return
	for connection in button.pressed.get_connections():
		button.pressed.disconnect(connection.callable)
	button.pressed.connect(callback)
	if caption.is_empty():
		return
	for child in button.get_children():
		if child is Label:
			(child as Label).text = caption
			break


func _quit_game() -> void:
	_trace("quit_game", {"role": PeerSync.my_role})
	get_tree().quit()


func _apply_result_button_state() -> void:
	if result_button_label == null or result_button_primary == null:
		return
	if PeerSync.my_role == "host":
		result_button_label.text = "开始下一局"
		result_button_primary.disabled = false
	else:
		result_button_label.text = "已准备，等待房主" if guest_ready else "重新准备"
		result_button_primary.disabled = guest_ready


func _on_result_button() -> void:
	if PeerSync.my_role == "host":
		# Only the host starts a round; this is the same path as the R key.
		_begin_round(round_id + 1)
		return
	# The guest never starts a round by itself: it marks ready and waits.
	guest_ready = true
	_apply_result_button_state()
	_trace("guest_ready", {"round": round_id})


func announce_original_throw(args: Dictionary, target: Node, mult: int) -> void:
	if not is_instance_valid(target):
		return
	local_throw_until_msec = Time.get_ticks_msec() + 1800
	var direction: int = slice_run.action_player.facing * int(args.get("dirValue", 1))
	var resolved: Dictionary = {"x": int(args.get("x", 0)), "y": int(args.get("y", 0)),
		"offsetX": int(args.get("offsetX", 0)), "offsetY": int(args.get("offsetY", 0)),
		"offsetZ": int(args.get("offsetZ", 0)), "direction": clampi(direction, -1, 1),
		"mult": mult, "target_x": float(target.position.x),
		"target_y": float(target.position.y), "target_height": int(target.air_height)}
	if PeerSync.my_role == "host":
		_send_control("thrown", resolved)
	else:
		_send_peer_control("thrown", resolved)
	_trace("send_original_throw", resolved)


func _send_peer_control(kind: String, throw_args: Dictionary = {}) -> void:
	if PeerSync.my_role != "guest":
		return
	control_counter += 1
	var skill_id: int = int(slice_run.current_skill)
	if skill_id <= 0:
		skill_id = 1
	PeerSync.send_hit_request({"type": "hit_request",
		"id": CONTROL_ID_BASE + control_counter,
		"skill": skill_id, "stage": 1 if kind == "caught" else (2 if kind == "thrown" else 0), "action": 0,
		"x": %Player.position.x, "y": %Player.position.y,
		"height": int(%Player.jump_height),
		"facing_left": bool(%Player.get_node("Visual").facing_left),
		"throw_args": throw_args})
	_trace("send_peer_control", {"kind": kind, "skill": skill_id})


func _send_control(kind: String, throw_args: Dictionary = {}) -> void:
	if PeerSync.my_role != "host" or not is_instance_valid(opponent):
		return
	PeerSync.send_combat({"type": "combat", "id": maxi(1, slice_run.ticks),
		"target": "guest", "reaction": {"control": kind, "throw_args": throw_args},
		"attacker_x": %Player.position.x, "attacker_y": %Player.position.y,
		"attacker_height": int(%Player.jump_height),
		"hp_host": int(slice_run.hp), "hp_guest": int(opponent.hp),
		"impulse": 1, "knockdown": false, "power": 0, "power_x": 0,
		"freeze": 0, "damage": 0})
	_trace("send_control", {"kind": kind})


func _trace(tag: String, data: Dictionary) -> void:
	var line: String = "PVP_TRACE %s %s" % [tag, JSON.stringify(data)]
	print(line)
	if trace_file == null:
		trace_file = FileAccess.open("user://pvp_hit_trace.log", FileAccess.WRITE)
	if trace_file != null:
		trace_file.store_line(line)
		trace_file.flush()


func _on_combat(value: Dictionary) -> void:
	if PeerSync.my_role != "guest" or round_finished:
		return
	if str(value.get("target", "")) == "host":
		if is_instance_valid(opponent):
			opponent.hp = clampi(int(value.get("hp_host", opponent.hp)), 0, opponent.max_hp)
		return
	if str(value.get("target", "")) != "guest":
		return
	if value.has("attacker_x") and value.has("attacker_y"):
		var impact_origin := Vector2(float(value.attacker_x), float(value.attacker_y))
		var impact_height := float(value.get("attacker_height", 0))
		# Align the buffered body with the position the host held at impact, so the
		# delayed interpolation stops drawing the spot the host already left.
		if peer_samples.is_empty():
			peer_samples.append({"msec": Time.get_ticks_msec(), "x": impact_origin.x,
				"y": impact_origin.y, "height": impact_height})
		else:
			var last: Dictionary = peer_samples[peer_samples.size() - 1]
			last["x"] = impact_origin.x
			last["y"] = impact_origin.y
			last["height"] = impact_height
	var amount: int = maxi(0, int(value.get("damage", 0)))
	var reaction: Dictionary = value.get("reaction", {})
	var control: String = str(reaction.get("control", ""))
	if control == "released":
		_end_grab()
		return
	if control == "thrown":
		_throw_grabbed(reaction.get("throw_args", {}))
		return
	var skill_id: int = int(reaction.get("skill", 0))
	var stage: int = int(reaction.get("stage", 0))
	# A catch may be attached to the damaging hit, not just to a separate
	# zero-damage control packet. Keep its original reaction and skill effects.
	if control == "caught" and skill_id <= 0 and amount <= 0:
		# Same rule as the host side: get-up protection also refuses the lock.
		if not _local_protected():
			_begin_grab()
		else:
			_trace("refuse_grab_protected", {"source": "control"})
		return
	var before_hp: int = int(slice_run.hp)
	slice_run.receive_monster_hit(amount, reaction, int(value.get("impulse", 1)))
	# The attacker's skill functions are applied by the victim exactly as the
	# original combat applies them to a hit target, so control effects land on
	# both ends instead of only on the host.
	if skill_id > 0:
		slice_run.apply_skill_functions(skill_id, stage, 0, %Player)
	# The host is authoritative if status effects altered the received damage.
	slice_run.hp = clampi(int(value.get("hp_guest", slice_run.hp)), 0, slice_run.max_hp)
	slice_run.state_changed.emit()
	_trace("recv_combat", {"damage": amount, "skill": skill_id, "stage": stage,
		"hp_before": before_hp, "hp_after": int(slice_run.hp),
		"reaction": str(slice_run.player_reaction.state)})
	# Get-up protection on this side also refuses the catch, both because the pack
	# swallowed the damage and because the lock itself must not take hold.
	if not _local_protected():
		_note_grab_candidate(skill_id)
		if str(reaction.get("control", "")) == "caught":
			_begin_grab()
	elif str(reaction.get("control", "")) == "caught":
		_trace("refuse_grab_protected", {"source": "combat", "skill": skill_id})
