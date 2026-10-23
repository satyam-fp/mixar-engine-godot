extends Node
## Autoload "MixarLink" in the running game. Active only when the game was
## started from the editor (EngineDebugger.is_active()); an exported build
## loads it and does nothing.
##
## It forwards the game's log lines to the editor, answers frame requests with
## a JPEG of the game's viewport, and runs playtests: scripted steps (hold or
## tap an input action, wait, walk the player to a point) with the game
## manager's state after each.

const LogBuffer := preload("res://addons/mixar_link/log_buffer.gd")
const C := preload("res://addons/mixar_link/game/component.gd")
const BATCH := 200
const REACHED_M := 0.6
const STALL_S := 1.5

var _logger: Logger
var _sent := 0


func _ready() -> void:
	if not EngineDebugger.is_active():
		return
	process_mode = Node.PROCESS_MODE_ALWAYS
	_logger = LogBuffer.new()
	_logger.source = "game"
	OS.add_logger(_logger)
	EngineDebugger.register_message_capture("mixar", _on_message)
	# The debugger session is live before any autoload runs; requests sent
	# before this line would be dropped, so the editor waits for it.
	EngineDebugger.send_message("mixar:ready", [])


func _exit_tree() -> void:
	if _logger != null:
		_flush()
		OS.remove_logger(_logger)
		EngineDebugger.unregister_message_capture("mixar")
		_logger = null


func _process(_delta: float) -> void:
	if _logger != null:
		_flush()


func _flush() -> void:
	var batch: Dictionary = _logger.since(_sent, BATCH)
	if not batch.lines.is_empty():
		EngineDebugger.send_message("mixar:log", [batch.lines])
	_sent = batch.next


func _on_message(message: String, data: Array) -> bool:
	match message.trim_prefix("mixar:"):
		"capture":
			_capture(int(data[0]), int(data[1]))
			return true
		"playtest":
			_playtest(int(data[0]), data[1])
			return true
	return false


func _capture(request_id: int, max_width: int) -> void:
	# A headless game never draws, so it never reaches frame_post_draw.
	if DisplayServer.get_name() == "headless":
		EngineDebugger.send_message("mixar:frame", [request_id, PackedByteArray(), 0, 0])
		return
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	if image == null or image.is_empty():
		EngineDebugger.send_message("mixar:frame", [request_id, PackedByteArray(), 0, 0])
		return
	if max_width > 0 and image.get_width() > max_width:
		image.resize(max_width, maxi(1, image.get_height() * max_width / image.get_width()),
			Image.INTERPOLATE_BILINEAR)
	EngineDebugger.send_message("mixar:frame",
		[request_id, image.save_jpg_to_buffer(0.85), image.get_width(), image.get_height()])


# ---------------------------------------------------------------------------
# Playtests
# ---------------------------------------------------------------------------

func _playtest(request_id: int, steps: Array) -> void:
	var results: Array = []
	for step in steps:
		var result := {}
		if typeof(step) != TYPE_DICTIONARY:
			result["error"] = "a step must be an object"
		elif step.has("hold"):
			result = await _hold(String(step.hold), clampf(float(step.get("seconds", 0.5)), 0.0, 30.0))
		elif step.has("press"):
			result = await _hold(String(step.press), 0.0)
		elif step.has("wait"):
			await _wait(clampf(float(step.wait), 0.0, 30.0))
		elif step.has("walk_to"):
			result = await _walk_to(C.to_godot(step.walk_to), clampf(float(step.get("timeout", 15.0)), 1.0, 60.0))
		elif not step.has("state"):
			result["error"] = "unknown step; use hold, press, wait, walk_to or state"
		result["step"] = step
		result["state"] = _state()
		results.append(result)
		if result.has("error"):
			break
	EngineDebugger.send_message("mixar:playtest", [request_id, results, _state()])


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds, true, true).timeout


func _hold(action: String, seconds: float) -> Dictionary:
	if not InputMap.has_action(action):
		return {"error": "no input action '%s' (actions: %s)" % [action, ", ".join(_actions())]}
	Input.action_press(action)
	await get_tree().physics_frame
	await get_tree().physics_frame
	if seconds > 0.0:
		await _wait(seconds)
	Input.action_release(action)
	await get_tree().physics_frame
	return {}


func _walk_to(target: Vector3, timeout: float) -> Dictionary:
	var player = get_tree().get_first_node_in_group("mixar_player")
	if player == null or not ("autopilot" in player):
		return {"error": "the level has no player with an autopilot (use the third_person template)"}
	player.autopilot = target
	var t0 := Time.get_ticks_msec()
	var best := INF
	var best_at := t0
	var jumped := false
	var result := {}
	while true:
		await get_tree().physics_frame
		if not is_instance_valid(player):
			return {"error": "the player was removed"}
		var to: Vector3 = target - player.global_position
		var flat := Vector2(to.x, to.z).length()
		var now := Time.get_ticks_msec()
		if flat < REACHED_M:
			result = {"reached": true}
			break
		if flat < best - 0.05:
			best = flat
			best_at = now
		elif now - best_at > STALL_S * 1000.0:
			if not jumped and player.has_method("jump"):
				player.jump()
				jumped = true
				best_at = now
			else:
				result = {"reached": false, "stuck": true}
				break
		if now - t0 > timeout * 1000.0:
			result = {"reached": false, "timed_out": true}
			break
	player.autopilot = null
	var left: Vector3 = target - player.global_position
	result["distance_m"] = snappedf(Vector2(left.x, left.z).length(), 0.01)
	result["seconds"] = snappedf((Time.get_ticks_msec() - t0) / 1000.0, 0.1)
	return result


func _state() -> Dictionary:
	var game = get_tree().get_first_node_in_group("mixar_game")
	var state: Dictionary = game.get_state() if game and game.has_method("get_state") else {}
	if not state.has("player_position"):
		var player = get_tree().get_first_node_in_group("mixar_player")
		if player is Node3D:
			state["player_position"] = C.to_blender(player.global_position)
	return state


func _actions() -> Array:
	return InputMap.get_actions().filter(func(a): return not String(a).begins_with("ui_"))
