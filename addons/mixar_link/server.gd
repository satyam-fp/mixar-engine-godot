@tool
extends Node
## A minimal MCP server (Streamable HTTP transport, JSON responses only) on
## 127.0.0.1. One request per connection (`Connection: close`).
##
## Every request must carry `Authorization: Bearer <token>` (the token is in
## the discovery file only this user can read), a loopback `Host`, and no
## `Origin` header, so a web page in a browser cannot drive the editor.
## Tool calls run as coroutines: a slow one (an import, waiting for a game
## frame) never blocks the editor or other requests.

const PROTOCOL_VERSION := "2025-06-18"
const MAX_BODY := 1 << 20
const HEADER_TIMEOUT_MS := 10000
const PORT_FIRST := 9890
const PORT_LAST := 9899

var port := 0
var token := ""
var tools: RefCounted

var _tcp := TCPServer.new()
var _conns: Array = []
var _sessions := {}


func start(p_tools: RefCounted) -> bool:
	tools = p_tools
	token = Crypto.new().generate_random_bytes(24).hex_encode()
	for p in range(PORT_FIRST, PORT_LAST + 1):
		if _tcp.listen(p, "127.0.0.1") == OK:
			port = p
			return true
	return false


func stop() -> void:
	for c in _conns:
		c.peer.disconnect_from_host()
	_conns.clear()
	_tcp.stop()


func _process(_delta: float) -> void:
	while _tcp.is_connection_available():
		_conns.append({"peer": _tcp.take_connection(), "buf": PackedByteArray(),
			"t0": Time.get_ticks_msec(), "busy": false, "done": false})
	for c in _conns.duplicate():
		if c.busy:
			continue
		var peer: StreamPeerTCP = c.peer
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			_drop(c)
			continue
		var n := peer.get_available_bytes()
		if n > 0:
			var got: Array = peer.get_partial_data(n)
			if got[0] == OK:
				c.buf.append_array(got[1])
		var req = _parse(c.buf)
		if req == null:
			if Time.get_ticks_msec() - c.t0 > HEADER_TIMEOUT_MS:
				_respond(c, 408, {}, "")
			continue
		c.busy = true
		_handle(c, req)


func _parse(buf: PackedByteArray):
	var end := _header_end(buf)
	if end < 0:
		return {"bad": 413} if buf.size() > 16384 else null
	var lines := buf.slice(0, end).get_string_from_utf8().split("\r\n")
	var first := lines[0].split(" ")
	if first.size() < 2:
		return {"bad": 400}
	var headers := {}
	for i in range(1, lines.size()):
		var k := lines[i].find(":")
		if k > 0:
			headers[lines[i].substr(0, k).strip_edges().to_lower()] = lines[i].substr(k + 1).strip_edges()
	var length := int(headers.get("content-length", "0"))
	if length > MAX_BODY:
		return {"bad": 413}
	var start := end + 4
	if buf.size() < start + length:
		return null
	return {"method": first[0], "path": first[1].split("?")[0], "headers": headers,
		"body": buf.slice(start, start + length).get_string_from_utf8()}


func _header_end(buf: PackedByteArray) -> int:
	var i := buf.find(13)
	while i >= 0 and i + 3 < buf.size():
		if buf[i + 1] == 10 and buf[i + 2] == 13 and buf[i + 3] == 10:
			return i
		i = buf.find(13, i + 1)
	return -1


func _handle(c: Dictionary, req: Dictionary) -> void:
	if req.has("bad"):
		_respond(c, req.bad, {}, "")
		return
	var h: Dictionary = req.headers
	if h.has("origin"):
		_respond(c, 403, {}, "")
		return
	var host := String(h.get("host", ""))
	if host != "127.0.0.1:%d" % port and host != "localhost:%d" % port:
		_respond(c, 403, {}, "")
		return
	if String(h.get("authorization", "")) != "Bearer " + token:
		_respond(c, 401, {}, "")
		return
	if req.path != "/mcp":
		_respond(c, 404, {}, "")
		return
	if req.method != "POST":
		_respond(c, 405, {"Allow": "POST"}, "")
		return
	var msg = JSON.parse_string(req.body)
	if typeof(msg) != TYPE_DICTIONARY:
		_respond(c, 400, {}, _rpc_error(null, -32700, "Parse error"))
		return
	var id = msg.get("id")
	var method := String(msg.get("method", ""))
	var params: Dictionary = msg.params if typeof(msg.get("params")) == TYPE_DICTIONARY else {}
	if id == null:
		_respond(c, 202, {}, "")  # a notification (notifications/initialized, cancelled)
		return
	var extra := {}
	var result
	match method:
		"initialize":
			var sid := Crypto.new().generate_random_bytes(16).hex_encode()
			_sessions[sid] = true
			extra["Mcp-Session-Id"] = sid
			result = {
				"protocolVersion": PROTOCOL_VERSION,
				"capabilities": {"tools": {"listChanged": false}},
				"serverInfo": {"name": "mixar-link-godot", "version": tools.ADAPTER_VERSION},
			}
		"ping":
			result = {}
		"tools/list", "tools/call":
			if not _sessions.has(String(h.get("mcp-session-id", ""))):
				_respond(c, 404, {}, _rpc_error(id, -32001, "Unknown session; initialize again"))
				return
			if method == "tools/list":
				result = {"tools": tools.list_tools()}
			else:
				var args: Dictionary = params.arguments if typeof(params.get("arguments")) == TYPE_DICTIONARY else {}
				result = await tools.call_tool(String(params.get("name", "")), args)
		_:
			_respond(c, 200, {}, _rpc_error(id, -32601, "Method not found: " + method))
			return
	_respond(c, 200, extra, JSON.stringify({"jsonrpc": "2.0", "id": id, "result": result}))


func _rpc_error(id, code: int, message: String) -> String:
	return JSON.stringify({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}})


const _REASONS := {200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized",
	403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 408: "Request Timeout",
	413: "Payload Too Large"}


func _respond(c: Dictionary, status: int, headers: Dictionary, body: String) -> void:
	if c.done:
		return
	c.done = true
	var bytes := body.to_utf8_buffer()
	var head := "HTTP/1.1 %d %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n" % [
		status, _REASONS.get(status, "Error"), bytes.size()]
	for k in headers:
		head += "%s: %s\r\n" % [k, headers[k]]
	var peer: StreamPeerTCP = c.peer
	peer.poll()
	if peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		peer.put_data((head + "\r\n").to_utf8_buffer())
		if bytes.size():
			peer.put_data(bytes)
	_drop(c)


func _drop(c: Dictionary) -> void:
	c.peer.disconnect_from_host()
	_conns.erase(c)
