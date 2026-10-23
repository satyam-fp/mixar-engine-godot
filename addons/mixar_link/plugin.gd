@tool
extends EditorPlugin
## Mixar Link: starts the local MCP server, the debugger channel to the
## running game and the editor log buffer, and writes a discovery file
## (~/.mixar/engine-link/godot-<pid>.json: port + token, owner-only) that the
## Mixar desktop app reads to connect.

const Server := preload("res://addons/mixar_link/server.gd")
const Tools := preload("res://addons/mixar_link/tools.gd")
const Debugger := preload("res://addons/mixar_link/debugger.gd")
const LogBuffer := preload("res://addons/mixar_link/log_buffer.gd")
const ImportPlugin := preload("res://addons/mixar_link/import_plugin.gd")
const AUTOLOAD := "MixarLink"
const RUNTIME := "res://addons/mixar_link/runtime.gd"

var _server: Node
var _tools: RefCounted
var _debugger: EditorDebuggerPlugin
var _log: Logger
var _import: EditorScenePostImportPlugin
var _discovery := ""


func _enable_plugin() -> void:
	_install_autoload()


func _disable_plugin() -> void:
	remove_autoload_singleton(AUTOLOAD)


## The runtime autoload loads FIRST, so the game's own autoloads log into it.
func _install_autoload() -> void:
	var key := "autoload/" + AUTOLOAD
	if not ProjectSettings.has_setting(key):
		add_autoload_singleton(AUTOLOAD, RUNTIME)
	var first := ProjectSettings.get_order(key)
	for prop in ProjectSettings.get_property_list():
		var name := String(prop.name)
		if name.begins_with("autoload/") and name != key:
			first = mini(first, ProjectSettings.get_order(name))
	if first < ProjectSettings.get_order(key):
		ProjectSettings.set_order(key, first - 1)
		ProjectSettings.save()


func _enter_tree() -> void:
	_install_autoload()
	_log = LogBuffer.new()
	OS.add_logger(_log)
	_debugger = Debugger.new()
	_debugger.log_buffer = _log
	add_debugger_plugin(_debugger)
	_import = ImportPlugin.new()
	add_scene_post_import_plugin(_import)
	_tools = Tools.new(self, _debugger, _log)
	_server = Server.new()
	_server.name = "MixarLinkServer"
	add_child(_server)
	if _server.start(_tools):
		_discovery = _write_discovery()
		print("[Mixar Link] listening on 127.0.0.1:%d" % _server.port)
	else:
		push_warning("[Mixar Link] no free port between %d and %d; Mixar cannot connect." % [
			Server.PORT_FIRST, Server.PORT_LAST])


func _exit_tree() -> void:
	if _discovery != "":
		DirAccess.remove_absolute(_discovery)
		_discovery = ""
	if _server != null:
		_server.stop()
		_server.queue_free()
		_server = null
	if _debugger != null:
		remove_debugger_plugin(_debugger)
		_debugger = null
	if _import != null:
		remove_scene_post_import_plugin(_import)
		_import = null
	if _log != null:
		OS.remove_logger(_log)
		_log = null
	_tools = null


func _write_discovery() -> String:
	var home := OS.get_environment("HOME")
	if home == "":
		home = OS.get_environment("USERPROFILE")
	if home == "":
		push_warning("[Mixar Link] no home folder; Mixar cannot discover this editor.")
		return ""
	var dir := home.path_join(".mixar").path_join("engine-link")
	DirAccess.make_dir_recursive_absolute(dir)
	var path := dir.path_join("godot-%d.json" % OS.get_process_id())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_warning("[Mixar Link] cannot write %s." % path)
		return ""
	file.store_string(JSON.stringify({
		"engine": "godot",
		"version": Engine.get_version_info().string,
		"adapter_version": Tools.ADAPTER_VERSION,
		"project_name": String(ProjectSettings.get_setting("application/config/name", "")),
		"pid": OS.get_process_id(),
		"port": _server.port,
		"token": _server.token,
		"started_at": Time.get_unix_time_from_system(),
	}))
	file.close()
	FileAccess.set_unix_permissions(path, FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_WRITE_OWNER)
	return path
