extends Node2D

# A read-only target for remote projectile visuals. It mirrors the local
# fighter so homing createInteract animations can use their original tracking.
var fighter: CharacterBody2D
var combat_run: Node
var dead: bool = false
var air_height: int = 0
var spec: Dictionary = {"height": 160}
var skill_status: RefCounted


func configure(actor: CharacterBody2D, run: Node) -> void:
	fighter = actor
	combat_run = run
	skill_status = run.source_status
	refresh()


func refresh() -> void:
	if not is_instance_valid(fighter):
		return
	position = fighter.position
	air_height = int(fighter.jump_height)
	dead = int(combat_run.hp) <= 0
