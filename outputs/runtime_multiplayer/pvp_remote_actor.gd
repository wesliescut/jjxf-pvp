extends Node2D

# The original effect renderer expects a fighter parented directly to world.
var jump_height: int = 0
var input_enabled: bool = true
var running: bool = false
var action_locked: bool = false
