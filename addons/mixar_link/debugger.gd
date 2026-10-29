@tool
extends EditorDebuggerPlugin
## The editor's end of the channel to the running game (runtime.gd). Requests
## go out as "mixar:<kind>" with a request id first ("capture", "playtest");
## the game answers with the same kind and id. Log lines ("mixar:log") stream
## in unasked.

var log_buffer: Logger
var _replies := {}
var _next_request := 0
var _runtime_ready := false


func _setup_session(session_id: int) -> void:
	var session := get_session(session_id)
	# A reply that lands after its request timed out must never answer a
	# request of the NEXT play session (cs-go iter 4: a capture showed the
	# previous session's frame).
	session.started.connect(_reset)
	session.stopped.connect(_reset)


func _reset() -> void:
	_runtime_ready = false
	_replies.clear()


func _has_capture(capture: String) -> bool:
	return capture == "mixar"


func _capture(message: String, data: Array, _session_id: int) -> bool:
	var kind := message.trim_prefix("mixar:")
	if kind == "log":
		for entry in data[0]:
			log_buffer.add("game", String(entry.get("level", "info")), String(entry.get("text", "")),
				String(entry.get("file", "")), int(entry.get("line", 0)))
		return true
	if kind == "ready":
		_runtime_ready = true
		return true
	if kind in ["frame", "playtest"]:
		_replies[int(data[0])] = data
		return true
	return false


func active_session() -> EditorDebuggerSession:
	for session in get_sessions():
		if session.is_active():
			return session
	return null


## A game is running AND its MixarLink runtime is listening.
func connected() -> bool:
	return _runtime_ready and active_session() != null


## Send a request to the game; returns its id, or -1 when no game runs.
func request(kind: String, args: Array) -> int:
	var session := active_session()
	if session == null or not _runtime_ready:
		return -1
	_next_request += 1
	session.send_message("mixar:" + kind, [_next_request] + args)
	return _next_request


## The reply's data array once it has arrived, else null.
func take(request_id: int):
	if not _replies.has(request_id):
		return null
	var reply = _replies[request_id]
	_replies.erase(request_id)
	return reply
