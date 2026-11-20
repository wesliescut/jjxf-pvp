extends "res://scripts/training_run.gd"

# Keep the complete, patched SliceRun action/skill/hit pipeline. The training
# subclass supplies the original arena room and player reaction clock; PvP does
# not call enter(), summon(), or the training panel.

var remote_visual_interacts: Array = []
var remote_visual_tick: bool = false
var action_serial: int = 0
var current_hit_index: int = 0
var current_hit_attack_type: int = 0
var visual_run: Node


func start_segment(index: int, selected_motion: int, frame_ref: int) -> void:
	if index == 0:
		action_serial += 1
	super.start_segment(index, selected_motion, frame_ref)

func begin_pvp() -> bool:
	settings = DEFAULT_SETTINGS.duplicate(true)
	settings.scene_id = 0
	settings.player_invincible = false
	settings.infinite_mp = false
	settings.no_cooldown = false
	settings.force_hit = false
	settings.force_critical = false
	settings.player_hit_reactions = true
	training_active = true
	if not super.begin(TRAINING_WIRE):
		training_active = false
		return false
	max_hp = 500000
	max_mp = 6000
	hp = max_hp
	mp = max_mp
	world.get_node("CanvasLayer/HUD").refresh()
	return true


func reset_player() -> void:
	super.reset_player()
	recovery_ticks = 0
	hp_recovery_fraction = 0.0
	mp_recovery_fraction = 0.0
	# The training ground hands out a full charge bar on every reset (angry = 1000),
	# which in PvP meant both sides opened each round with an ultimate. A fresh round
	# must start with an empty charge bar, like a fresh arena entry.
	angry = 0
	angry_damage = 0
	charge_input_skill = 0
	state_changed.emit()


func advance_fatal_defeat() -> void:
	# The original fatal launch starts after a control skill releases its victim.
	# Starting it while the PvP grab still owns the body makes the grab overwrite
	# the fatal animation every frame.
	if world != null and world.grab_active:
		return
	super.advance_fatal_defeat()


func mark_pvp_fatal_if_needed() -> void:
	# Host HP reconciliation can set the guest to zero after a locally protected
	# hit. Enter the original fatal pipeline in that case as well.
	if hp > 0 or status != "battle" or has_meta("jjxf_fatal_pending"):
		return
	set_meta("jjxf_fatal_pending", true)
	remove_meta("jjxf_fatal_launched")
	set_meta("jjxf_fatal_lie_ticks", 0)
	set_meta("jjxf_fatal_total_ticks", 0)
	clear_interact_attacks()
	action_player.stop()
	current_skill = 0
	player.action_locked = true


func throw_caught_targets(args: Dictionary) -> void:
	var thrown: Node = null
	for target in caught_targets:
		if is_instance_valid(target) and not target.dead:
			thrown = target
			break
	var action_id: int = int(Game.slice_data.skills.get(str(current_skill), {}).get("action", 0))
	super.throw_caught_targets(args)
	if is_instance_valid(thrown) and world != null and not PeerSync.solo:
		world.announce_original_throw(args, thrown, 2 if action_id == 116 else 3)


func advance_natural_recovery() -> void:
	# Duels have no sustain: HP must only change through combat. The original
	# attribute driven MP recovery is kept untouched, so the only difference from
	# the single player run is the HP part.
	var before_hp: int = hp
	super.advance_natural_recovery()
	hp = before_hp


func recovery_error(_item: Dictionary) -> String:
	# Recovery consumables are disabled on the PvP stage. This is the single entry
	# point the item panel and the shortcut bar both go through, so blocking here
	# keeps the original item logic intact for the normal game.
	return "双人擂台内不能使用恢复类道具。"


func spawn_next_wave() -> void:
	# The opponent is a network controlled player, never a dungeon monster wave.
	if training_active:
		pending_waves.clear()
		wave_pending = false
		return
	super.spawn_next_wave()


func spawn_remote_visual_interact(args: Dictionary, skill_id: int, index: int,
		ground: Vector2, height: float, facing: int, owner: Node2D, attack_model: Dictionary) -> Node2D:
	var definition: Dictionary = Game.career_combat.interacts.get(str(int(args.get("id", 0))), {})
	if definition.is_empty():
		return null
	var attack = preload("res://scripts/flash/skill_interact.gd").new()
	attack.run = visual_run if is_instance_valid(visual_run) else self
	attack.spec = definition
	attack.args = args.duplicate(true)
	attack.skill_id = skill_id
	attack.skill_index = index
	attack.facing = -facing if int(args.get("dir", 0)) == 2 else facing
	attack.position = ground + Vector2(float(args.get("x", 0)) * attack.facing, float(args.get("z", 0)))
	attack.height = height + float(args.get("y", 0))
	if int(args.get("follow", 0)) == 1:
		attack.follower = owner
		attack.follow_offset = Vector3(float(args.get("x", 0)), float(args.get("y", 0)), float(args.get("z", 0)))
	world.current_map.add_child(attack)
	attack.attack_model = attack_model.duplicate(true)
	remote_visual_interacts.append(attack)
	return attack


func advance_remote_visual_interacts() -> void:
	remote_visual_tick = true
	for attack in remote_visual_interacts.duplicate():
		if is_instance_valid(attack) and not attack.is_queued_for_deletion():
			attack.tick()
	remote_visual_tick = false
	remote_visual_interacts = remote_visual_interacts.filter(func(a): return is_instance_valid(a) and not a.is_queued_for_deletion())


func clear_remote_visual_interacts() -> void:
	for attack in remote_visual_interacts:
		if is_instance_valid(attack):
			attack.finish()
	remote_visual_interacts.clear()


func hit_monsters(frame: Dictionary, skill_id: int, index: int, ground: Vector2, height: float, facing: int,
		quota: Dictionary, last_ticks: Dictionary, attack_model: Dictionary = {}, contacts: Variant = null) -> int:
	if remote_visual_tick:
		return 0
	if world.round_finished:
		return 0
	current_hit_index = index
	var spec: Dictionary = Game.slice_data.skills.get(str(skill_id), {})
	if not spec.is_empty() and not spec.get("hits", []).is_empty():
		current_hit_attack_type = int(spec.hits[mini(index, spec.hits.size() - 1)].get("attack", 0))
	var count: int = super.hit_monsters(frame, skill_id, index, ground, height, facing, quota, last_ticks, attack_model, contacts)
	current_hit_index = 0
	current_hit_attack_type = 0
	return count
