extends "res://scripts/training_monster.gd"

# A player shaped target for the original SliceRun hit and status functions.
# The inherited target supplies the collision, damage, status and reaction API
# required by hit_monsters() and createInteract. Its monster art is hidden;
# remote player art is rendered by the PvP world from the peer's role data.

signal hit_resolved(amount: int, remaining_hp: int, reaction: Dictionary, direction: int, skill_id: int, stage: int)
const DamageCalculator = preload("res://scripts/flash/damage_calculator.gd")
var hp_recovery: int = 0
var recovery_ticks: int = 0
var recovery_fraction: float = 0.0

func _ready() -> void:
	super._ready()
	instructor_ai = null
	if not PeerSync.solo:
		# The base renderer makes individual sprites visible again on every tick.
		# Keep the hit target active, but hide its entire art subtree in PvP.
		get_node("DepthOrigin/Art").hide()
	configure_training({
		"behavior": 0,
		"armor": 0,
		"hp_mode": 0 if PeerSync.my_role == "guest" else 1,
		"defense_percent": 0,
	})


func set_peer_attributes(values: Dictionary, level: int) -> void:
	attributes = DamageCalculator.from_equipment_attributes(values, level)
	hp_recovery = int(values.get("2015", 0))
	max_hp = 500000
	hp = max_hp
	spec.height = 160


func tick() -> void:
	super.tick()
	# No HP regeneration on the peer body either: the host owns this number and a
	# regenerating value would heal the guest without any combat event.


func reset_for_round(point: Vector2) -> void:
	dead = false
	hp = max_hp
	recovery_ticks = 0
	recovery_fraction = 0.0
	collision_layer = 4
	source_statuses.clear()
	skill_status.active.clear()
	air_height = 0
	air_velocity = 0
	airborne = false
	rebound = false
	stun = 0
	lie_ticks = 0
	getting_up = false
	impact_freeze = 0
	caught = false
	attack_tick = -1
	death_wait = -1
	death_effect_played = false
	death_flash = null
	set_death_flash(false)
	script_movement.reset()
	set_motion("3")
	position = point
	show()
	if PeerSync.solo:
		get_node("DepthOrigin/Art").show()
	else:
		get_node("DepthOrigin/Art").hide()
	render_frame()


func damage(value: int, knockback: Vector2, launch: bool = false, reaction: Dictionary = {}) -> void:
	if dead:
		return
	var before: int = hp
	var skill_id: int = int(get_meta("damage_skill_id", run.current_skill))
	var stage: int = int(run.current_hit_index)
	var protection: Dictionary = skill_status.model({"holdFlag": 0, "holdXRate": 1.0, "beHurtBack": 1})
	var protected: bool = int(protection.get("holdFlag", 0)) > int(run.current_hit_attack_type)
	var previous_armor: int = armor
	if protected:
		armor = 2
	super.damage(value, knockback, launch, reaction)
	armor = previous_armor
	if PeerSync.my_role == "guest":
		hit_resolved.emit(maxi(1, value), hp, reaction, -1 if knockback.x < 0 else 1, skill_id, stage)
	elif hp < before:
		hit_resolved.emit(before - hp, hp, reaction, -1 if knockback.x < 0 else 1, skill_id, stage)
