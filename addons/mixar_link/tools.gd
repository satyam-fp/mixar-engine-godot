@tool
extends RefCounted
## The MCP tools Mixar calls. Every tool returns an MCP CallToolResult:
## `content` (a JSON text block, plus an image block for captures),
## `structuredContent` (the same data) and `isError`.
##
## Positions in and out are in Blender's frame (Z up, metres), the frame
## Mixar works in: Blender (x, y, z) is Godot (x, z, -y), and a yaw about
## Blender's Z is the same angle about Godot's Y.

const ADAPTER_VERSION := "0.1.0"
const MIXAR_DIR := "res://mixar"
const IMPORT_TIMEOUT_MS := 120000
const PLAY_TIMEOUT_MS := 20000
const FRAME_TIMEOUT_MS := 8000
const SKIP_EXTENSIONS := ["blend", "blend1"]
const TEMPLATES := {"third_person": "res://addons/mixar_link/templates/third_person/"}
const SCRIPT_DIR := "res://mixar/scripts"
const BUILD_DIR := "res://mixar_build"
const PLAYTEST_MAX_MS := 120000
const BUILD_TIMEOUT_MS := 300000
## The input map the templates' scripts read (physical keys).
const INPUT_ACTIONS := {
	"move_forward": [KEY_W, KEY_UP], "move_back": [KEY_S, KEY_DOWN],
	"move_left": [KEY_A, KEY_LEFT], "move_right": [KEY_D, KEY_RIGHT],
	"jump": [KEY_SPACE], "camera_left": [KEY_Q], "camera_right": [KEY_E],
}

var plugin: EditorPlugin
var debugger: EditorDebuggerPlugin
var log_buffer: Logger


func _init(p_plugin: EditorPlugin, p_debugger: EditorDebuggerPlugin, p_log: Logger) -> void:
	plugin = p_plugin
	debugger = p_debugger
	log_buffer = p_log


# ---------------------------------------------------------------------------
# Catalogue
# ---------------------------------------------------------------------------

func list_tools() -> Array:
	var vec3 := {"type": "array", "items": {"type": "number"}, "minItems": 3, "maxItems": 3}
	return [
		_tool("status", "The engine, project, open scene, main scene and whether the game runs.", {}),
		_tool("import_package", "Copy a Mixar export package folder into res://mixar/<folder>/ and import it.",
			{"source_dir": {"type": "string"}, "folder": {"type": "string"}}, ["source_dir", "folder"]),
		_tool("new_scene", "Create res://mixar/levels/<name>.tscn (Node3D root; with_defaults adds a sun, sky and camera; template third_person adds a player, game manager and HUD plus the input map; ground adds a 60 m floor), open it, optionally set it as the main scene.",
			{"name": {"type": "string"}, "set_main": {"type": "boolean"}, "with_defaults": {"type": "boolean"},
			 "overwrite": {"type": "boolean"}, "template": {"type": "string", "enum": ["", "third_person"]},
			 "ground": {"type": "boolean"}, "player_position": vec3}, ["name"]),
		_tool("open_scene", "Open an existing scene in the editor.", {"scene": {"type": "string"}}, ["scene"]),
		_tool("place", "Instance a scene (an imported package's main file) into the open scene at a Blender-frame position and yaw, then save.",
			{"scene": {"type": "string"}, "name": {"type": "string"}, "position": vec3,
			 "yaw_deg": {"type": "number"}, "parent": {"type": "string"}}, ["scene"]),
		_tool("scene_tree", "The open scene's own nodes (not the inside of instanced scenes): path, type, Blender-frame position.",
			{"max_nodes": {"type": "integer"}}),
		_tool("save_scene", "Save the open scene.", {}),
		_tool("play", "Run the game from the editor (scene: main | current | a res:// path) and wait until it connects.",
			{"scene": {"type": "string"}}),
		_tool("stop", "Stop the running game.", {}),
		_tool("capture", "A frame of the running game (source game) or of the editor's 3D viewport (source editor).",
			{"source": {"type": "string", "enum": ["game", "editor"]}, "max_width": {"type": "integer"}}),
		_tool("log", "Editor and game log lines after `since` (a sequence number from an earlier call).",
			{"since": {"type": "integer"}, "max_lines": {"type": "integer"}, "errors_only": {"type": "boolean"}}),
		_tool("playtest", "Run scripted steps in the running game: {hold: action, seconds}, {press: action}, {wait: s}, {walk_to: [x,y,z] Blender frame, timeout}, {state: true}; returns each step's result and the game state after it.",
			{"steps": {"type": "array", "items": {"type": "object"}}}, ["steps"]),
		_tool("write_script", "Write a GDScript under res://mixar/scripts/ after compiling it; a compile error is returned, not written.",
			{"path": {"type": "string"}, "source": {"type": "string"}}, ["path", "source"]),
		_tool("add_node", "Add a node of a built-in type (optionally with a script) to the open scene, with undo, then save.",
			{"parent": {"type": "string"}, "type": {"type": "string"}, "name": {"type": "string"},
			 "script": {"type": "string"}, "position": vec3}, ["type", "name"]),
		_tool("set_property", "Set one property of a node in the open scene (Godot units and axes; arrays become vectors/colors), with undo, then save.",
			{"node": {"type": "string"}, "property": {"type": "string"}, "value": {}}, ["node", "property", "value"]),
		_tool("build_web", "Export the project for the web (HTML5) into res://mixar_build/web/; needs Godot's export templates installed.",
			{}),
		_tool("build_info", "The last web build's files and its absolute folder (for the Mixar desktop to upload a share).",
			{}),
	]


func _tool(name: String, description: String, props: Dictionary, required: Array = []) -> Dictionary:
	var schema := {"type": "object", "properties": props}
	if not required.is_empty():
		schema["required"] = required
	return {"name": name, "description": description, "inputSchema": schema}


func call_tool(name: String, args: Dictionary) -> Dictionary:
	var result
	match name:
		"status": result = _status()
		"import_package": result = await _import_package(args)
		"new_scene": result = _new_scene(args)
		"open_scene": result = _open_scene(args)
		"place": result = _place(args)
		"scene_tree": result = _scene_tree(args)
		"save_scene": result = _save_scene()
		"play": result = await _play(args)
		"stop": result = await _stop()
		"capture": result = await _capture(args)
		"log": result = _log(args)
		"playtest": result = await _playtest(args)
		"write_script": result = _write_script(args)
		"add_node": result = _add_node(args)
		"set_property": result = _set_property(args)
		"build_web": result = await _build_web()
		"build_info": result = _build_info()
		_: return _err("Unknown tool: " + name)
	if typeof(result) != TYPE_DICTIONARY:
		return _err("%s failed inside Godot; see the Output panel." % name)
	return result


# ---------------------------------------------------------------------------
# Tools
# ---------------------------------------------------------------------------

func _status() -> Dictionary:
	var root := EditorInterface.get_edited_scene_root()
	return _ok({
		"engine": "godot",
		"version": Engine.get_version_info().string,
		"project_name": String(ProjectSettings.get_setting("application/config/name", "")),
		"edited_scene": root.scene_file_path if root else "",
		"main_scene": String(ProjectSettings.get_setting("application/run/main_scene", "")),
		"playing": EditorInterface.is_playing_scene(),
		"game_connected": debugger.connected(),
		"adapter_version": ADAPTER_VERSION,
		"mixar_folder": MIXAR_DIR,
		"log_seq": log_buffer.latest(),
	})


func _import_package(args: Dictionary):
	var src := String(args.get("source_dir", ""))
	var folder := String(args.get("folder", ""))
	if not _safe_name(folder):
		return _err("folder must be a plain name (letters, digits, . _ - and spaces).")
	if src == "" or not DirAccess.dir_exists_absolute(src):
		return _err("The package folder was not found.")
	var manifest_text := FileAccess.get_file_as_string(src.path_join("manifest.json"))
	var manifest = JSON.parse_string(manifest_text) if manifest_text != "" else null
	if typeof(manifest) != TYPE_DICTIONARY:
		return _err("The folder has no readable manifest.json; it is not a Mixar package.")
	var main := _main_file(manifest)
	if main == "":
		return _err("The manifest names no glb, gltf or fbx file.")
	var dest_res := MIXAR_DIR.path_join(folder)
	var dest := ProjectSettings.globalize_path(dest_res)
	DirAccess.make_dir_recursive_absolute(dest)
	var copied := _copy_tree(src, dest)
	if copied < 0:
		return _err("Copying the package into the project failed.")
	var fs := EditorInterface.get_resource_filesystem()
	var tree := plugin.get_tree()
	var t0 := Time.get_ticks_msec()
	fs.scan()
	await tree.process_frame
	var main_res := dest_res.path_join(main)
	while Time.get_ticks_msec() - t0 < IMPORT_TIMEOUT_MS:
		if not fs.is_scanning() and ResourceLoader.exists(main_res):
			break
		await tree.process_frame
	var imported := ResourceLoader.exists(main_res)
	var engine: Dictionary = manifest.engine if typeof(manifest.get("engine")) == TYPE_DICTIONARY else {}
	var data := {
		"folder": dest_res, "main_scene": main_res if imported else "", "imported": imported,
		"files_copied": copied, "seconds": snappedf((Time.get_ticks_msec() - t0) / 1000.0, 0.1),
		"engine_target": String(engine.get("target", "")),
		"tagged_objects": (engine.get("objects", []) as Array).size(),
		"collision_nodes": int(engine.get("collision_nodes", 0)),
	}
	if not imported:
		return _err("The package was copied but %s did not import within %d s; read log for the importer's errors." % [
			main_res, IMPORT_TIMEOUT_MS / 1000], data)
	return _ok(data)


func _new_scene(args: Dictionary):
	var name := String(args.get("name", "Level"))
	if not _safe_name(name) or name.contains(" "):
		return _err("name must be a plain name without spaces.")
	var path := MIXAR_DIR.path_join("levels").path_join(name + ".tscn")
	if FileAccess.file_exists(path) and not bool(args.get("overwrite", false)):
		return _err("%s exists; open_scene it, or pass overwrite=true." % path)
	var template := String(args.get("template", ""))
	if template != "" and not TEMPLATES.has(template):
		return _err("Unknown template '%s' (templates: %s)." % [template, ", ".join(TEMPLATES.keys())])
	var root := Node3D.new()
	root.name = name
	if bool(args.get("with_defaults", true)):
		var sun := DirectionalLight3D.new()
		sun.name = "Sun"
		sun.rotation_degrees = Vector3(-50, -30, 0)
		sun.shadow_enabled = true
		var env := WorldEnvironment.new()
		env.name = "Environment"
		var environment := Environment.new()
		var sky := Sky.new()
		sky.sky_material = ProceduralSkyMaterial.new()
		environment.background_mode = Environment.BG_SKY
		environment.sky = sky
		environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
		env.environment = environment
		var defaults: Array = [sun, env]
		if template == "":  # a template's player brings its own camera
			var cam := Camera3D.new()
			cam.name = "Camera"
			cam.position = Vector3(0, 6, 12)
			cam.rotation_degrees = Vector3(-26.57, 0, 0)  # looking at the origin
			cam.current = true
			defaults.append(cam)
		for n in defaults:
			root.add_child(n)
			n.owner = root
	if bool(args.get("ground", false)):
		var ground := StaticBody3D.new()
		ground.name = "Ground"
		var shape := CollisionShape3D.new()
		shape.name = "Collision"
		var box := BoxShape3D.new()
		box.size = Vector3(60, 0.2, 60)
		shape.shape = box
		shape.position.y = -0.1
		var mesh := MeshInstance3D.new()
		mesh.name = "Mesh"
		var plane := PlaneMesh.new()
		plane.size = Vector2(60, 60)
		mesh.mesh = plane
		root.add_child(ground)
		ground.owner = root
		for n in [shape, mesh]:
			ground.add_child(n)
			n.owner = root
	if template != "":
		var dir: String = TEMPLATES[template]
		var player := CharacterBody3D.new()
		player.name = "Player"
		player.set_script(load(dir + "player.gd"))
		player.position = _to_godot(args.get("player_position", [0, 0, 1]) if typeof(args.get("player_position")) == TYPE_ARRAY else [0, 0, 1])
		var game := Node.new()
		game.name = "Game"
		game.set_script(load(dir + "game.gd"))
		var hud := CanvasLayer.new()
		hud.name = "HUD"
		hud.set_script(load(dir + "hud.gd"))
		for n in [player, game, hud]:
			root.add_child(n)
			n.owner = root
		_ensure_input_map()
	var packed := PackedScene.new()
	packed.pack(root)
	root.free()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	if ResourceSaver.save(packed, path) != OK:
		return _err("Saving %s failed." % path)
	EditorInterface.get_resource_filesystem().update_file(path)
	EditorInterface.open_scene_from_path(path)
	var set_main := bool(args.get("set_main", false))
	if set_main:
		ProjectSettings.set_setting("application/run/main_scene", path)
		ProjectSettings.save()
	return _ok({"scene": path, "main_scene": set_main, "template": template,
		"input_actions": INPUT_ACTIONS.keys() if template != "" else []})


func _open_scene(args: Dictionary):
	var path := String(args.get("scene", ""))
	if not path.begins_with("res://") or not FileAccess.file_exists(path):
		return _err("No such scene: " + path)
	EditorInterface.open_scene_from_path(path)
	return _ok({"scene": path})


func _place(args: Dictionary):
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return _err("No scene is open; call new_scene or open_scene first.")
	var path := String(args.get("scene", ""))
	if not path.begins_with("res://") or not ResourceLoader.exists(path):
		return _err("No such resource: " + path + " (import_package returns main_scene).")
	var packed = load(path)
	if not packed is PackedScene:
		return _err(path + " is not a scene.")
	var parent: Node = root
	var parent_path := String(args.get("parent", ""))
	if parent_path != "":
		parent = root.get_node_or_null(NodePath(parent_path))
		if parent == null:
			return _err("No node at " + parent_path)
	var inst: Node = packed.instantiate()
	if String(args.get("name", "")) != "":
		inst.name = String(args.name)
	var position: Array = args.get("position", [0, 0, 0]) if typeof(args.get("position")) == TYPE_ARRAY else [0, 0, 0]
	if inst is Node3D:
		inst.position = _to_godot(position)
		inst.rotation.y = deg_to_rad(float(args.get("yaw_deg", 0.0)))
	var undo := plugin.get_undo_redo()
	undo.create_action("Mixar: place " + String(inst.name))
	undo.add_do_method(parent, "add_child", inst, true)
	undo.add_do_method(inst, "set_owner", root)
	undo.add_do_reference(inst)
	undo.add_undo_method(parent, "remove_child", inst)
	undo.commit_action()
	EditorInterface.save_scene()
	return _ok({"node": String(root.get_path_to(inst)), "type": inst.get_class(),
		"position": _to_blender((inst as Node3D).position) if inst is Node3D else null,
		"scene": root.scene_file_path})


func _scene_tree(args: Dictionary):
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return _err("No scene is open.")
	var limit := clampi(int(args.get("max_nodes", 200)), 1, 2000)
	var nodes: Array = []
	var queue: Array = [root]
	var total := 0
	while not queue.is_empty():
		var node: Node = queue.pop_front()
		total += 1
		if nodes.size() < limit:
			var entry := {"path": String(root.get_path_to(node)), "type": node.get_class(),
				"children": node.get_child_count()}
			if node is Node3D:
				entry["position"] = _to_blender(node.global_position if node.is_inside_tree() else node.position)
			if node != root and node.scene_file_path != "":
				entry["instance_of"] = node.scene_file_path
			nodes.append(entry)
		for child in node.get_children():
			if child.owner == root:
				queue.append(child)
	return _ok({"scene": root.scene_file_path, "nodes": nodes, "total": total, "truncated": total > nodes.size()})


func _save_scene():
	if EditorInterface.get_edited_scene_root() == null:
		return _err("No scene is open.")
	return _ok({"saved": EditorInterface.save_scene() == OK})


func _play(args: Dictionary):
	var tree := plugin.get_tree()
	if EditorInterface.is_playing_scene():
		EditorInterface.stop_playing_scene()
		var t_stop := Time.get_ticks_msec()
		while EditorInterface.is_playing_scene() and Time.get_ticks_msec() - t_stop < 5000:
			await tree.process_frame
	var which := String(args.get("scene", "main"))
	match which:
		"main":
			if String(ProjectSettings.get_setting("application/run/main_scene", "")) == "":
				return _err("The project has no main scene; new_scene(set_main=true) or play a res:// path.")
			EditorInterface.play_main_scene()
		"current":
			if EditorInterface.get_edited_scene_root() == null:
				return _err("No scene is open.")
			EditorInterface.play_current_scene()
		_:
			if not which.begins_with("res://") or not FileAccess.file_exists(which):
				return _err("No such scene: " + which)
			EditorInterface.play_custom_scene(which)
	var since: int = log_buffer.latest()
	var t0 := Time.get_ticks_msec()
	while not debugger.connected() and Time.get_ticks_msec() - t0 < PLAY_TIMEOUT_MS:
		await tree.process_frame
	var data := {"playing": EditorInterface.is_playing_scene(), "game_connected": debugger.connected(),
		"scene": which, "log_seq": since}
	if not debugger.connected():
		return _err("The game did not connect within %d s; read log from log_seq." % (PLAY_TIMEOUT_MS / 1000), data)
	return _ok(data)


func _stop():
	var tree := plugin.get_tree()
	if EditorInterface.is_playing_scene():
		EditorInterface.stop_playing_scene()
	var t0 := Time.get_ticks_msec()
	while EditorInterface.is_playing_scene() and Time.get_ticks_msec() - t0 < 5000:
		await tree.process_frame
	return _ok({"playing": EditorInterface.is_playing_scene()})


func _capture(args: Dictionary):
	var max_width := clampi(int(args.get("max_width", 1280)), 64, 3840)
	if String(args.get("source", "game")) == "editor":
		var viewport := EditorInterface.get_editor_viewport_3d(0)
		var image: Image = viewport.get_texture().get_image() if viewport else null
		if image == null or image.is_empty():
			return _err("The editor viewport has no image (a headless editor draws nothing).")
		if image.get_width() > max_width:
			image.resize(max_width, maxi(1, image.get_height() * max_width / image.get_width()),
				Image.INTERPOLATE_BILINEAR)
		return _image({"source": "editor", "width": image.get_width(), "height": image.get_height()},
			image.save_jpg_to_buffer(0.85))
	var request: int = debugger.request("capture", [max_width])
	if request < 0:
		return _err("The game is not running; call play first.")
	var frame = await _reply(request, FRAME_TIMEOUT_MS)
	if frame == null:
		return _err("The game sent no frame within %d s." % (FRAME_TIMEOUT_MS / 1000))
	var jpeg: PackedByteArray = frame[1]
	if jpeg.is_empty():
		return _err("The game's viewport has no image (a headless game draws nothing).")
	return _image({"source": "game", "width": int(frame[2]), "height": int(frame[3])}, jpeg)


func _log(args: Dictionary):
	var batch: Dictionary = log_buffer.since(int(args.get("since", 0)),
		clampi(int(args.get("max_lines", 200)), 1, 1000), bool(args.get("errors_only", false)))
	return _ok(batch)


func _playtest(args: Dictionary):
	var steps = args.get("steps")
	if typeof(steps) != TYPE_ARRAY or steps.is_empty() or steps.size() > 50:
		return _err("steps must be a list of 1 to 50 steps.")
	var budget := 5000.0
	for step in steps:
		if typeof(step) == TYPE_DICTIONARY:
			budget += 500.0 + 1000.0 * (float(step.get("seconds", 0)) + float(step.get("wait", 0))
				+ (float(step.get("timeout", 15)) if step.has("walk_to") else 0.0))
	var request: int = debugger.request("playtest", [steps])
	if request < 0:
		return _err("The game is not running; call play first.")
	var reply = await _reply(request, mini(int(budget), PLAYTEST_MAX_MS))
	if reply == null:
		return _err("The playtest sent no result in time; read log.")
	return _ok({"steps": reply[1], "final_state": reply[2]})


func _write_script(args: Dictionary):
	var path := String(args.get("path", ""))
	if not path.begins_with(SCRIPT_DIR + "/") or not path.ends_with(".gd") or path.contains(".."):
		return _err("Scripts live under %s/ and end in .gd." % SCRIPT_DIR)
	var source := String(args.get("source", ""))
	var mark: int = log_buffer.latest()
	var probe := GDScript.new()
	probe.source_code = source
	if probe.reload() != OK:
		var errors: Array = []
		for line in log_buffer.since(mark, 20, true).lines:
			errors.append(line.text)
		return _err("The script does not compile; nothing was written.", {"errors": errors})
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return _err("Cannot write " + path)
	file.store_string(source)
	file.close()
	if ResourceLoader.has_cached(path):
		var cached: GDScript = load(path)
		cached.source_code = source
		cached.reload(true)
	EditorInterface.get_resource_filesystem().update_file(path)
	return _ok({"path": path, "lines": source.count("\n") + 1})


func _add_node(args: Dictionary):
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return _err("No scene is open.")
	var type := String(args.get("type", ""))
	if not ClassDB.class_exists(type) or not ClassDB.is_parent_class(type, "Node") or not ClassDB.can_instantiate(type) \
			or ClassDB.is_parent_class(type, "EditorPlugin"):
		return _err("'%s' is not a node type that can be added." % type)
	var name := String(args.get("name", ""))
	if not _safe_name(name) or name.contains(" ") or name.contains("."):
		return _err("name must be a plain node name.")
	var parent := _scene_node(String(args.get("parent", ".")))
	if parent == null:
		return _err("No parent node at " + String(args.get("parent", ".")))
	var node: Node = ClassDB.instantiate(type)
	node.name = name
	var script_path := String(args.get("script", ""))
	if script_path != "":
		if not script_path.begins_with("res://") or not ResourceLoader.exists(script_path):
			node.free()
			return _err("No such script: " + script_path)
		var script: Script = load(script_path)
		if not ClassDB.is_parent_class(type, script.get_instance_base_type()):
			node.free()
			return _err("%s extends %s, which a %s is not." % [script_path, script.get_instance_base_type(), type])
		node.set_script(script)
	if node is Node3D and typeof(args.get("position")) == TYPE_ARRAY:
		node.position = _to_godot(args.position)
	var undo := plugin.get_undo_redo()
	undo.create_action("Mixar: add " + name)
	undo.add_do_method(parent, "add_child", node, true)
	undo.add_do_method(node, "set_owner", root)
	undo.add_do_reference(node)
	undo.add_undo_method(parent, "remove_child", node)
	undo.commit_action()
	EditorInterface.save_scene()
	return _ok({"node": String(root.get_path_to(node)), "type": type})


func _set_property(args: Dictionary):
	var path := String(args.get("node", ""))
	var node := _scene_node(path)
	if node == null:
		return _err("No node at " + path)
	var prop := String(args.get("property", ""))
	if prop == "" or not (prop in node):
		return _err("%s (%s) has no property '%s'." % [path, node.get_class(), prop])
	var current = node.get(prop)
	var value = _coerce(args.get("value"), current)
	if value is String and value.begins_with("res://") and (prop == "script" or current == null or current is Resource):
		if not ResourceLoader.exists(value):
			return _err("No such resource: " + value)
		value = load(value)
	var undo := plugin.get_undo_redo()
	undo.create_action("Mixar: set %s.%s" % [node.name, prop])
	undo.add_do_property(node, prop, value)
	undo.add_undo_property(node, prop, current)
	undo.commit_action()
	EditorInterface.save_scene()
	return _ok({"node": path, "property": prop, "value": var_to_str(node.get(prop)).left(200)})


func _build_web():
	var v := Engine.get_version_info()
	var folder := "%d.%d.%s" % [v.major, v.minor, v.status] if v.patch == 0 else "%d.%d.%d.%s" % [v.major, v.minor, v.patch, v.status]
	var templates := EditorInterface.get_editor_paths().get_data_dir().path_join("export_templates").path_join(folder)
	if not (FileAccess.file_exists(templates.path_join("web_nothreads_release.zip"))
			or FileAccess.file_exists(templates.path_join("web_release.zip"))):
		return _err("Godot's web export templates (%s) are not installed: Editor > Manage Export Templates > Download and Install, then build_web again." % folder)
	_ensure_web_preset()
	var build := ProjectSettings.globalize_path(BUILD_DIR)
	var out := build.path_join("web")
	DirAccess.make_dir_recursive_absolute(out)
	FileAccess.open(build.path_join(".gdignore"), FileAccess.WRITE).close()  # never imported
	EditorInterface.save_all_scenes()
	var started := Time.get_unix_time_from_system()
	var t0 := Time.get_ticks_msec()
	var pid := OS.create_process(OS.get_executable_path(), ["--headless", "--path",
		ProjectSettings.globalize_path("res://"), "--export-release", "Web", out.path_join("index.html")])
	if pid <= 0:
		return _err("Could not start the export.")
	var tree := plugin.get_tree()
	while OS.is_process_running(pid) and Time.get_ticks_msec() - t0 < BUILD_TIMEOUT_MS:
		await tree.process_frame
	if OS.is_process_running(pid):
		OS.kill(pid)
		return _err("The web export did not finish within %d s." % (BUILD_TIMEOUT_MS / 1000))
	var index := out.path_join("index.html")
	if not FileAccess.file_exists(index) or FileAccess.get_modified_time(index) < int(started):
		return _err("The web export wrote no index.html; read log for the exporter's errors.")
	var files: Array = []
	var total := 0
	for f in DirAccess.get_files_at(out):
		files.append(f)
		total += FileAccess.get_file_as_bytes(out.path_join(f)).size()
	return _ok({"folder": BUILD_DIR + "/web", "entry": "index.html", "files": files, "bytes": total,
		"seconds": snappedf((Time.get_ticks_msec() - t0) / 1000.0, 0.1)})


func _build_info():
	var out := ProjectSettings.globalize_path(BUILD_DIR.path_join("web"))
	if not FileAccess.file_exists(out.path_join("index.html")):
		return _err("There is no web build yet; call build_web first.")
	var files: Array = []
	for f in DirAccess.get_files_at(out):
		files.append({"name": f, "bytes": FileAccess.get_file_as_bytes(out.path_join(f)).size()})
	return _ok({"dir": out, "files": files})


func _ensure_web_preset() -> void:
	var cfg := ConfigFile.new()
	cfg.load("res://export_presets.cfg")
	var index := 0
	while cfg.has_section("preset.%d" % index):
		if cfg.get_value("preset.%d" % index, "name", "") == "Web":
			return
		index += 1
	var section := "preset.%d" % index
	cfg.set_value(section, "name", "Web")
	cfg.set_value(section, "platform", "Web")
	cfg.set_value(section, "runnable", true)
	cfg.set_value(section, "export_filter", "all_resources")
	cfg.set_value(section, "exclude_filter", "mixar_build/*")
	cfg.set_value(section, "export_path", BUILD_DIR.trim_prefix("res://").path_join("web/index.html"))
	# No threads: plays from any static host, without cross-origin isolation headers.
	cfg.set_value(section + ".options", "variant/thread_support", false)
	cfg.set_value(section + ".options", "vram_texture_compression/for_desktop", true)
	cfg.set_value(section + ".options", "vram_texture_compression/for_mobile", false)
	cfg.save("res://export_presets.cfg")


func _ensure_input_map() -> void:
	var changed := false
	for action in INPUT_ACTIONS:
		var key: String = "input/" + action
		if ProjectSettings.has_setting(key):
			continue
		var events: Array = []
		for code in INPUT_ACTIONS[action]:
			var event := InputEventKey.new()
			event.physical_keycode = code
			events.append(event)
		ProjectSettings.set_setting(key, {"deadzone": 0.2, "events": events})
		changed = true
	if changed:
		ProjectSettings.save()


func _reply(request: int, timeout_ms: int):
	var tree := plugin.get_tree()
	var t0 := Time.get_ticks_msec()
	var reply = debugger.take(request)
	while reply == null and Time.get_ticks_msec() - t0 < timeout_ms:
		await tree.process_frame
		reply = debugger.take(request)
	return reply


func _scene_node(path: String) -> Node:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return null
	return root if path in ["", "."] else root.get_node_or_null(NodePath(path))


static func _coerce(value, current):
	match typeof(current):
		TYPE_VECTOR3:
			if typeof(value) == TYPE_ARRAY and value.size() == 3:
				return Vector3(float(value[0]), float(value[1]), float(value[2]))
		TYPE_VECTOR2:
			if typeof(value) == TYPE_ARRAY and value.size() == 2:
				return Vector2(float(value[0]), float(value[1]))
		TYPE_COLOR:
			if typeof(value) == TYPE_ARRAY and value.size() >= 3:
				return Color(float(value[0]), float(value[1]), float(value[2]), float(value[3]) if value.size() > 3 else 1.0)
			if typeof(value) == TYPE_STRING:
				return Color.from_string(value, current)
		TYPE_INT:
			return int(value)
		TYPE_FLOAT:
			return float(value)
		TYPE_BOOL:
			return bool(value)
		TYPE_STRING_NAME:
			return StringName(String(value))
		TYPE_NODE_PATH:
			return NodePath(String(value))
	return value


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _ok(data: Dictionary) -> Dictionary:
	return {"content": [{"type": "text", "text": JSON.stringify(data)}], "structuredContent": data,
		"isError": false}


func _err(message: String, data := {}) -> Dictionary:
	var payload := data.duplicate()
	payload["error"] = message
	return {"content": [{"type": "text", "text": message}], "structuredContent": payload, "isError": true}


func _image(data: Dictionary, jpeg: PackedByteArray) -> Dictionary:
	return {"content": [{"type": "text", "text": JSON.stringify(data)},
		{"type": "image", "data": Marshalls.raw_to_base64(jpeg), "mimeType": "image/jpeg"}],
		"structuredContent": data, "isError": false}


static func _to_godot(p: Array) -> Vector3:
	var v := [0.0, 0.0, 0.0]
	for i in mini(3, p.size()):
		v[i] = float(p[i])
	return Vector3(v[0], v[2], -v[1])


static func _to_blender(v: Vector3) -> Array:
	return [snappedf(v.x, 0.0001), snappedf(-v.z, 0.0001), snappedf(v.y, 0.0001)]


static func _safe_name(name: String) -> bool:
	if name == "" or name.length() > 96 or name.begins_with(".") or name.contains(".."):
		return false
	for ch in name:
		if not (ch.is_valid_identifier() or ch in "0123456789.- "):
			return false
	return true


static func _main_file(manifest: Dictionary) -> String:
	for entry in manifest.get("files", []):
		var file := String(entry.get("file", "")) if typeof(entry) == TYPE_DICTIONARY else ""
		if not file.contains("/") and file.get_extension().to_lower() in ["glb", "gltf", "fbx"]:
			return file
	return ""


## Copies every file under `src` into `dest` (Blender sources skipped);
## the number copied, or -1 on a failure.
static func _copy_tree(src: String, dest: String) -> int:
	var dir := DirAccess.open(src)
	if dir == null:
		return -1
	var count := 0
	DirAccess.make_dir_recursive_absolute(dest)
	for sub in dir.get_directories():
		var n := _copy_tree(src.path_join(sub), dest.path_join(sub))
		if n < 0:
			return -1
		count += n
	for file in dir.get_files():
		if file.get_extension().to_lower() in SKIP_EXTENSIONS:
			continue
		if DirAccess.copy_absolute(src.path_join(file), dest.path_join(file)) != OK:
			return -1
		count += 1
	return count
