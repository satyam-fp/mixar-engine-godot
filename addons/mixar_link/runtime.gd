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
const WAYPOINT_M := 0.5
const STALL_S := 1.5
## The player's capsule, for the navigation mesh playtests route by.
const AGENT_RADIUS := 0.35
const AGENT_HEIGHT := 1.8
const AGENT_CLIMB := 0.35

var _nav_region: NavigationRegion3D

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
	# A window behind another app (or minimised) is not drawn, so
	# frame_post_draw may never come: wait a moment, then draw it ourselves.
	var drawn := [false]
	var mark := func(): drawn[0] = true
	RenderingServer.frame_post_draw.connect(mark, CONNECT_ONE_SHOT)
	for i in 30:
		await get_tree().process_frame
		if drawn[0]:
			break
	if not drawn[0]:
		if RenderingServer.frame_post_draw.is_connected(mark):
			RenderingServer.frame_post_draw.disconnect(mark)
		RenderingServer.force_draw(false)
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
		elif step.has("inspect"):
			result = _inspect(step.inspect)
		elif step.has("prove_loop"):
			result = await _prove_loop(clampf(float(step.get("timeout", 15.0)), 1.0, 60.0))
		elif not step.has("state"):
			result["error"] = "unknown step; use hold, press, wait, walk_to, prove_loop, inspect or state"
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
		return {"error": "the level has no player with an autopilot (use a template)"}
	var route: Array = [target]
	var routed := false
	if player.has_method("uses_navigation") and player.uses_navigation():
		var path := await _route(player.global_position, target)
		if path.is_empty():
			return {"reached": false, "no_path": true,
				"distance_m": snappedf(_distance(player, target), 0.01), "seconds": 0.0}
		route = path
		routed = true
	var t0 := Time.get_ticks_msec()
	var best := INF
	var best_at := t0
	var jumped := false
	var result := {}
	var leg := 0
	player.autopilot = route[0]
	while true:
		await get_tree().physics_frame
		if not is_instance_valid(player):
			return {"error": "the player was removed"}
		var now := Time.get_ticks_msec()
		var left := _distance(player, target)
		if left < REACHED_M:
			result = {"reached": true}
			break
		if leg < route.size() - 1 and _distance(player, route[leg]) < WAYPOINT_M:
			leg += 1
			player.autopilot = route[leg]
		if left < best - 0.05:
			best = left
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
	result["distance_m"] = snappedf(_distance(player, target), 0.01)
	result["seconds"] = snappedf((Time.get_ticks_msec() - t0) / 1000.0, 0.1)
	result["routed"] = routed
	return result


func _distance(player, target: Vector3) -> float:
	if player.has_method("distance_to_target"):
		return player.distance_to_target(target)
	var to: Vector3 = target - player.global_position
	return Vector2(to.x, to.z).length()


## A path over a navigation mesh baked NOW from the level's static colliders
## (so a door that opened since the last bake is open in it); empty when the
## target is not connected to the player.
func _route(from: Vector3, to: Vector3) -> Array:
	var level := get_tree().current_scene
	if level == null:
		return [to]
	if _nav_region == null or not is_instance_valid(_nav_region):
		_nav_region = NavigationRegion3D.new()
		_nav_region.name = "MixarPlaytestNavigation"
		var mesh := NavigationMesh.new()
		mesh.agent_radius = AGENT_RADIUS
		mesh.agent_height = AGENT_HEIGHT
		mesh.agent_max_climb = AGENT_CLIMB
		mesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
		mesh.geometry_source_geometry_mode = NavigationMesh.SOURCE_GEOMETRY_ROOT_NODE_CHILDREN
		mesh.cell_size = 0.25
		mesh.cell_height = 0.25
		_nav_region.navigation_mesh = mesh
		level.add_child(_nav_region)
		await get_tree().physics_frame
	var source := NavigationMeshSourceGeometryData3D.new()
	NavigationServer3D.parse_source_geometry_data(_nav_region.navigation_mesh, source, level)
	NavigationServer3D.bake_from_source_geometry_data(_nav_region.navigation_mesh, source)
	var map := _nav_region.get_navigation_map()
	# The map takes new polygons a sync or two later. A region's very first
	# set does not always take (Godot 4.7), so set again when it has not.
	for attempt in 2:
		var iteration := NavigationServer3D.map_get_iteration_id(map)
		NavigationServer3D.region_set_navigation_mesh(_nav_region.get_rid(), _nav_region.navigation_mesh)
		var synced := false
		for i in 60:
			await get_tree().physics_frame
			if NavigationServer3D.map_get_iteration_id(map) > iteration \
					and NavigationServer3D.map_get_closest_point_owner(map, from).is_valid():
				synced = true
				break
		if synced:
			break
	var start := NavigationServer3D.map_get_closest_point(map, from)
	var end := NavigationServer3D.map_get_closest_point(map, to)
	if Vector2(end.x - to.x, end.z - to.z).length() > 1.0:
		return []  # the target is off the walkable area
	var path := NavigationServer3D.map_get_path(map, start, end, true)
	if path.is_empty() or Vector2(path[-1].x - end.x, path[-1].z - end.z).length() > 0.5:
		return []
	var out: Array = []
	for p in path:
		out.append(p)
	out[-1] = to
	return out


## Every pickup (nearest first), then the goal: what a player has to do to win.
func _prove_loop(timeout_each: float) -> Dictionary:
	var player = get_tree().get_first_node_in_group("mixar_player")
	if player == null:
		return {"error": "the level has no player (use a template)"}
	var visits: Array = []
	var unreached: Array = []
	var remaining: Array = get_tree().get_nodes_in_group("mixar_pickup")
	while true:
		var open_pickups: Array = []
		for n in remaining:
			if is_instance_valid(n) and not n.get("collected") and not unreached.has(String(n.name)):
				open_pickups.append(n)
		remaining = open_pickups
		if remaining.is_empty():
			break
		remaining.sort_custom(func(a, b): return _distance(player, a.global_position) < _distance(player, b.global_position))
		var target: Node3D = remaining[0]
		var name := String(target.name)
		var r := await _walk_to(target.global_position, timeout_each)
		r["target"] = name
		r["collected"] = not is_instance_valid(target) or bool(target.get("collected"))
		visits.append(r)
		if not r.collected:
			unreached.append(name)
	var goal = get_tree().get_first_node_in_group("mixar_goal")
	if goal == null:
		return {"visits": visits, "unreached": unreached, "error": "the level has no goal (mixar_role goal)"}
	await _wait(1.5)  # doors finish opening
	var r := await _walk_to(goal.global_position, timeout_each)
	r["target"] = String(goal.name)
	visits.append(r)
	if not r.get("reached", false):
		unreached.append(String(goal.name))
	var won: bool = bool(_state().get("won", false))
	return {"visits": visits, "unreached": unreached, "won": won}


## {node: "Name" or "Path/To/Node", properties: [...]} → their current values
## (positions in the Blender frame), read in the running game.
func _inspect(spec) -> Dictionary:
	if typeof(spec) != TYPE_DICTIONARY or String(spec.get("node", "")) == "":
		return {"error": "inspect needs {node, properties}"}
	var level := get_tree().current_scene
	var name := String(spec.node)
	var node: Node = level.get_node_or_null(NodePath(name)) if name.contains("/") else level.find_child(name, true, false)
	if node == null and level.name == name:
		node = level
	if node == null:
		return {"error": "no node '%s' in the running game" % name}
	var values := {}
	for prop in spec.get("properties", ["global_position"]):
		var key := String(prop)
		if not (key in node):
			values[key] = "<no such property>"
			continue
		var v = node.get(key)
		if v is Vector3:
			values[key] = C.to_blender(v)
		elif typeof(v) in [TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING, TYPE_STRING_NAME]:
			values[key] = v
		else:
			values[key] = var_to_str(v).left(200)
	return {"node": String(level.get_path_to(node)), "type": node.get_class(), "values": values}


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
