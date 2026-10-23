@tool
extends Logger
## A bounded, thread-safe buffer of log lines. Installed with OS.add_logger()
## in the editor (source "editor") and in the running game (source "game");
## game lines reach the editor's buffer through the debugger channel.
##
## Never print from here: a print inside a logger callback is logged again.

const MAX_LINES := 2000

var source := "editor"
var _ansi := RegEx.create_from_string("\u001b\\[[0-9;]*[A-Za-z]")
var _mutex := Mutex.new()
var _lines: Array = []
var _seq := 0
var _dropped := 0


func _log_message(message: String, error: bool) -> void:
	add(source, "error" if error else "info", message.strip_edges(false, true), "", 0)


func _log_error(function: String, file: String, line: int, code: String, rationale: String,
		editor_notify: bool, error_type: int, script_backtraces: Array) -> void:
	var level := "warning" if error_type == ERROR_TYPE_WARNING else "error"
	var text := rationale if rationale != "" else code
	if function != "":
		text = "%s (in %s)" % [text, function]
	add(source, level, text, file, line)


func add(src: String, level: String, text: String, file: String, line: int) -> void:
	_mutex.lock()  # loggers are called from any thread; the RegEx is shared
	text = _ansi.sub(text, "", true).strip_edges()
	if text == "":
		_mutex.unlock()
		return
	_seq += 1
	_lines.append({"seq": _seq, "source": src, "level": level, "text": text.left(2000),
		"file": file, "line": line})
	if _lines.size() > MAX_LINES:
		_lines.pop_front()
		_dropped += 1
	_mutex.unlock()


## Lines after `seq`, oldest first, at most `max_lines`.
func since(seq: int, max_lines: int, errors_only := false) -> Dictionary:
	_mutex.lock()
	var out: Array = []
	var more := false
	for entry in _lines:
		if entry.seq <= seq:
			continue
		if errors_only and entry.level == "info":
			continue
		if out.size() >= max_lines:
			more = true
			break
		out.append(entry.duplicate())
	var latest := _seq
	var dropped := _dropped
	_mutex.unlock()
	var next: int = out[-1].seq if not out.is_empty() else (seq if more else latest)
	return {"lines": out, "next": next, "more": more, "dropped": dropped}


func latest() -> int:
	_mutex.lock()
	var s := _seq
	_mutex.unlock()
	return s
