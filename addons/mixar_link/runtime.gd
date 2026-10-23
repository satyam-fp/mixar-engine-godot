extends Node
## Autoload "MixarLink" in the running game. Active only when the game was
## started from the editor (EngineDebugger.is_active()); an exported build
## loads it and does nothing.
##
## It forwards the game's log lines to the editor and answers frame requests
## with a JPEG of the game's viewport.

const LogBuffer := preload("res://addons/mixar_link/log_buffer.gd")
const BATCH := 200

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
	if message.trim_prefix("mixar:") == "capture":
		_capture(int(data[0]), int(data[1]))
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
