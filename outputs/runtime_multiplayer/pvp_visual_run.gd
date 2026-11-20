extends Node

# Read-only combat context for the other player's original createInteract
# objects. The original script uses run.player for follow and facing, so it
# must see the remote fighter rather than the local player.
var world: Node2D
var player: Node2D
var action_player: RefCounted
var combat_random: RefCounted
var source_status: RefCounted
var current_skill: int = 0
var monsters: Array = []
var attack_model: Dictionary = {}
var arena_run: Node


func player_attack_model() -> Dictionary:
	return attack_model.duplicate(true)


func spawn_interact(args: Dictionary, skill_id: int, index: int, ground: Vector2,
		height: float, facing: int, _owner_actor: Node2D = null) -> Node2D:
	return arena_run.spawn_remote_visual_interact(args, skill_id, index, ground,
		height, facing, player, attack_model)


func hit_monsters(_frame: Dictionary, _skill_id: int, _index: int, _ground: Vector2,
		_height: float, _facing: int, _quota: Dictionary, _last_ticks: Dictionary,
		_attack_model: Dictionary = {}, _contacts: Variant = null) -> int:
	return 0


func monster_target(_owner_actor: Node2D) -> Node2D:
	return world.get_node("Player")


func monster_attack(_owner_actor: Node, _skill: Dictionary, _frame: Dictionary,
		_aim: Node2D = null, _index: int = 0, _quota: Dictionary = {},
		_last_ticks: Dictionary = {}, _ground: Variant = null, _height: float = -1,
		_facing: int = 0, _model: Dictionary = {}) -> bool:
	return false


func note_unsupported_script(_command: String, _args: Dictionary) -> void:
	pass
