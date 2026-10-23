@tool
extends EditorDebuggerPlugin
## The editor's end of the channel to the running game (runtime.gd): frame
## requests go out as "mixar:capture"; frames ("mixar:frame") and log lines
## ("mixar:log") come back.

var log_buffer: Logger
var _frames := {}
var _next_request := 0


func _has_capture(capture: String) -> bool:
	return capture == "mixar"


func _capture(message: String, data: Array, _session_id: int) -> bool:
	match message.trim_prefix("mixar:"):
		"frame":
			_frames[int(data[0])] = data
			return true
		"log":
			for entry in data[0]:
				log_buffer.add("game", String(entry.get("level", "info")), String(entry.get("text", "")),
					String(entry.get("file", "")), int(entry.get("line", 0)))
			return true
	return false


func active_session() -> EditorDebuggerSession:
	for session in get_sessions():
		if session.is_active():
			return session
	return null


func connected() -> bool:
	return active_session() != null


## Ask the game for one frame; returns the request id, or -1 when no game runs.
func request_frame(max_width: int) -> int:
	var session := active_session()
	if session == null:
		return -1
	_next_request += 1
	session.send_message("mixar:capture", [_next_request, max_width])
	return _next_request


## [request_id, jpeg bytes, width, height] once it has arrived, else null.
func take_frame(request_id: int):
	if not _frames.has(request_id):
		return null
	var frame = _frames[request_id]
	_frames.erase(request_id)
	return frame
