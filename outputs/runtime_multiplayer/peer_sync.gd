extends Node
## PvP arena transport.

signal role_ready
signal peer_state_received(value: Dictionary)
signal peer_disconnected
signal combat_received(value: Dictionary)
signal hit_request_received(value: Dictionary)
signal round_received(value: Dictionary)
signal chat_received(value: Dictionary)

const ARENA_ID: int = 9999
const ARENA_SCENE: String = "res://_multiplayer/pvp_world.tscn"
const LEGACY_SCENE: String = "res://_multiplayer/pvp_arena.tscn"

var socket: WebSocketPeer = WebSocketPeer.new()
var room_code: String = ""
var room_token: String = ""
var gateway: String = ""
var my_role: String = ""
var peer_state: Dictionary = {}
var round_state: Dictionary = {}
var sequence: int = 0
var send_elapsed: float = 0.0
var retry_elapsed: float = 0.0
var arena_requested: bool = false
var solo: bool = false


func _ready() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument == "--mp-solo=1":
			solo = true
		elif argument.begins_with("--mp-room="):
			room_code = argument.trim_prefix("--mp-room=")
		elif argument.begins_with("--mp-token="):
			room_token = argument.trim_prefix("--mp-token=")
		elif argument.begins_with("--mp-gateway="):
			gateway = argument.trim_prefix("--mp-gateway=")
	if solo:
		my_role = "host"
		return
	if room_code.is_empty() or room_token.is_empty() or gateway.is_empty():
		set_process(false)
		return
	connect_room()


func connect_room() -> void:
	var address := gateway.trim_suffix("/").replace("https://", "wss://").replace("http://", "ws://")
	if not address.begins_with("wss://") and not address.begins_with("ws://"):
		return
	socket = WebSocketPeer.new()
	var url := address + "/game?code=" + room_code.uri_encode() + "&token=" + room_token.uri_encode()
	var error := socket.connect_to_url(url)
	if error != OK:
		retry_elapsed = 3.0


func _process(delta: float) -> void:
	# Keep the normal game entry flow: start page -> 开始 -> role select -> game
	# world. Only switch into the arena once the chosen role has entered the game
	# world (scenes/game.tscn), instead of hijacking the start page.
	if solo:
		if not arena_requested and not Game.role().is_empty():
			if _entered_game_world():
				arena_requested = true
				print("PVP_ARENA_SWITCH solo")
				get_tree().change_scene_to_file(ARENA_SCENE)
		return
	socket.poll()
	if socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		while socket.get_available_packet_count() > 0:
			handle_packet(socket.get_packet().get_string_from_utf8())
		if not arena_requested and not my_role.is_empty() and not Game.role().is_empty():
			if _entered_game_world():
				arena_requested = true
				print("PVP_ARENA_SWITCH role=%s" % my_role)
				get_tree().change_scene_to_file(ARENA_SCENE)
		send_elapsed += delta
		if send_elapsed >= 0.05:
			send_elapsed = 0.0
			send_position()
	elif socket.get_ready_state() == WebSocketPeer.STATE_CLOSED:
		retry_elapsed -= delta
		if retry_elapsed <= 0.0:
			retry_elapsed = 3.0
			connect_room()


func _entered_game_world() -> bool:
	var current := get_tree().current_scene
	if current == null:
		return false
	# game.tscn is the world the player lands in after 开始 -> 选角色. Some builds
	# may also drop straight into it, which is fine.
	return current.scene_file_path == "res://scenes/game.tscn"


func send_position() -> void:
	var scene := get_tree().current_scene
	if scene == null or scene.scene_file_path not in [ARENA_SCENE, LEGACY_SCENE] or not scene.has_method("snapshot"):
		return
	var character: Dictionary = Game.role()
	if character.is_empty():
		return
	var snapshot: Dictionary = scene.snapshot()
	var combat_attrs := {}
	var attributes: Dictionary = Game.character_attributes()
	for key in ["2001", "2002", "2003", "2004", "2007", "2008", "2009", "2010", "2011", "2012", "2013", "2015", "2016", "2017", "2018", "2019", "2020"]:
		combat_attrs[key] = clampi(int(attributes.get(key, 0)), 0, 10000000)
	sequence += 1
	var avatar := {"name": str(character.get("name", "")),
		"level": int(character.get("level", 1)), "career": int(character.get("career", 0)),
		"career_wear_level": int(character.get("career_wear_level", 1)),
		"has_join": bool(character.get("has_join", false)),
		"sublime": bool(character.get("sublime", false)),
		"equipment": character.get("equipment", []),
		"appearance": character.get("appearance", {}), "combat_attrs": combat_attrs}
	var payload := {"type": "state", "seq": sequence, "map": ARENA_ID,
		"x": float(snapshot.x), "y": float(snapshot.y),
		"height": float(snapshot.get("height", 0.0)),
		"ready": bool(snapshot.get("ready", false)),
		"defeat_ready": bool(snapshot.get("defeat_ready", false)),
		"hp_self": int(snapshot.get("hp_self", 500000)),
		"hp_peer": int(snapshot.get("hp_peer", 500000)),
		"mp_self": int(snapshot.get("mp_self", 0)),
		"facing_left": bool(snapshot.facing_left), "motion": int(snapshot.motion),
		"skill": int(snapshot.get("skill", 0)), "stage": int(snapshot.get("stage", 0)),
		"action": int(snapshot.get("action", 0)),
		"action_frame": int(snapshot.get("action_frame", 0)),
		"reaction_state": str(snapshot.get("reaction_state", "")),
		"reaction_frame": int(snapshot.get("reaction_frame", 0)),
		"statuses": snapshot.get("statuses", []),
		"caught_pose": snapshot.get("caught_pose", {}),
		"grab_binding": snapshot.get("grab_binding", {}),
		"avatar": avatar}
	socket.send_text(JSON.stringify(payload))


func send_combat(value: Dictionary) -> void:
	if my_role == "host" and socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		socket.send_text(JSON.stringify(value))


func send_hit_request(value: Dictionary) -> void:
	if my_role == "guest" and socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		socket.send_text(JSON.stringify(value))


func send_round(value: Dictionary) -> void:
	if my_role == "host" and socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		socket.send_text(JSON.stringify(value))


func send_chat(text: String) -> void:
	# Both roles may chat; the relay only forwards it to the other player.
	if socket.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	if my_role != "host" and my_role != "guest":
		return
	socket.send_text(JSON.stringify({"type": "chat", "text": text}))


func handle_packet(packet: String) -> void:
	var value = JSON.parse_string(packet)
	if not value is Dictionary:
		return
	match str(value.get("type", "")):
		"ready":
			my_role = str(value.get("role", ""))
			role_ready.emit()
		"peer_left":
			peer_state.clear()
			round_state.clear()
			peer_disconnected.emit()
		"state":
			if str(value.get("role", "")) == my_role or int(value.get("map", -1)) != ARENA_ID:
				return
			peer_state = value
			peer_state_received.emit(peer_state)
		"combat":
			if my_role == "guest":
				combat_received.emit(value)
		"hit_request":
			if my_role == "host":
				hit_request_received.emit(value)
		"round":
			if my_role == "guest":
				round_state = value
				round_received.emit(value)
		"chat":
			chat_received.emit(value)
