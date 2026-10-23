#!/usr/bin/env python3
"""End-to-end test of the Mixar Link add-on against a real, headless Godot
editor: discovery, auth, the MCP handshake, and every tool (status,
new_scene, import_package, place, scene_tree, save_scene, play, log, capture,
stop) on a throwaway project.

    python3 test/run_e2e.py --godot /path/to/Godot [--windowed-game]

Exit code 0 = every check passed. Nothing outside a temp folder is touched:
the editor runs with HOME pointed into it, so its discovery file and user
data stay there too. The editor is always headless; the game is too unless
--windowed-game, which opens a game window for a few seconds so `capture`
returns a real frame.
"""

from __future__ import annotations

import argparse
import base64
import glob
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

PROJECT_GODOT = """config_version=5

[application]

config/name="Mixar Link E2E"

[autoload]

TestPrinter="*res://test_printer.gd"

[editor]

run/main_run_args="--headless"

[editor_plugins]

enabled=PackedStringArray("res://addons/mixar_link/plugin.cfg")
"""

TEST_PRINTER = """extends Node
func _ready() -> void:
	print("MIXAR_TEST_GAME_READY")
	push_error("MIXAR_TEST_ERROR")
"""


def glb_cube(path: str, names: list[str]) -> None:
    """A GLB with one tetrahedron mesh per node name (enough to import)."""
    pos = struct.pack("<12f", 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1)
    idx = struct.pack("<12H", 0, 1, 2, 0, 1, 3, 0, 2, 3, 1, 2, 3)
    blob = pos + idx
    doc = {
        "asset": {"version": "2.0"},
        "scene": 0,
        "scenes": [{"nodes": [0]}],
        "nodes": [{"name": names[0], "mesh": 0, "children": list(range(1, len(names)))}]
                 + [{"name": n, "mesh": 0} for n in names[1:]],
        "meshes": [{"primitives": [{"attributes": {"POSITION": 0}, "indices": 1}]}],
        "accessors": [
            {"bufferView": 0, "componentType": 5126, "count": 4, "type": "VEC3",
             "min": [0, 0, 0], "max": [1, 1, 1]},
            {"bufferView": 1, "componentType": 5123, "count": 12, "type": "SCALAR"},
        ],
        "bufferViews": [{"buffer": 0, "byteOffset": 0, "byteLength": len(pos)},
                        {"buffer": 0, "byteOffset": len(pos), "byteLength": len(idx)}],
        "buffers": [{"byteLength": len(blob)}],
    }
    js = json.dumps(doc).encode()
    js += b" " * (-len(js) % 4)
    blob += b"\0" * (-len(blob) % 4)
    body = struct.pack("<II", len(js), 0x4E4F534A) + js + struct.pack("<II", len(blob), 0x004E4942) + blob
    with open(path, "wb") as fh:
        fh.write(struct.pack("<III", 0x46546C67, 2, 12 + len(body)) + body)


class Client:
    def __init__(self, port: int, token: str):
        self.url = f"http://127.0.0.1:{port}/mcp"
        self.token = token
        self.session = ""
        self._id = 0

    def raw(self, payload: dict, headers: dict | None = None, timeout: float = 60.0):
        req = urllib.request.Request(self.url, data=json.dumps(payload).encode(), method="POST")
        req.add_header("Content-Type", "application/json")
        req.add_header("Accept", "application/json, text/event-stream")
        for k, v in (headers or {}).items():
            req.add_header(k, v)
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                body = resp.read()
                return resp.status, dict(resp.headers), json.loads(body) if body else None
        except urllib.error.HTTPError as err:
            return err.code, dict(err.headers), None

    def rpc(self, method: str, params: dict | None = None, timeout: float = 60.0):
        self._id += 1
        headers = {"Authorization": f"Bearer {self.token}"}
        if self.session:
            headers["Mcp-Session-Id"] = self.session
        status, hdrs, body = self.raw({"jsonrpc": "2.0", "id": self._id, "method": method,
                                       "params": params or {}}, headers, timeout)
        return status, hdrs, body

    def initialize(self):
        status, hdrs, body = self.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                                     "clientInfo": {"name": "e2e", "version": "0"}})
        assert status == 200, status
        self.session = {k.lower(): v for k, v in hdrs.items()}["mcp-session-id"]
        return body["result"]

    def call(self, name: str, args: dict | None = None, timeout: float = 120.0):
        status, _, body = self.rpc("tools/call", {"name": name, "arguments": args or {}}, timeout)
        assert status == 200, (name, status)
        return body["result"]


FAILURES: list[str] = []


def check(cond, label, detail=""):
    print(("PASS " if cond else "FAIL ") + label + (f"  [{detail}]" if detail and not cond else ""))
    if not cond:
        FAILURES.append(label)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--godot", required=True)
    ap.add_argument("--keep", action="store_true", help="leave the temp folder for inspection")
    ap.add_argument("--windowed-game", action="store_true", help="run the game in a window and require a frame")
    args = ap.parse_args()

    tmp = tempfile.mkdtemp(prefix="mixar-link-e2e-")
    home = os.path.join(tmp, "home")
    project = os.path.join(tmp, "project")
    package = os.path.join(tmp, "Mixar Exports", "Crate")
    os.makedirs(home)
    os.makedirs(project)
    os.makedirs(package)
    shutil.copytree(os.path.join(ROOT, "addons"), os.path.join(project, "addons"))
    with open(os.path.join(project, "project.godot"), "w") as fh:
        fh.write(PROJECT_GODOT.replace('run/main_run_args="--headless"', "") if args.windowed_game
                 else PROJECT_GODOT)
    with open(os.path.join(project, "test_printer.gd"), "w") as fh:
        fh.write(TEST_PRINTER)
    glb_cube(os.path.join(package, "Crate.glb"), ["Crate", "Crate_col-convcolonly"])
    with open(os.path.join(package, "Crate_source.blend"), "wb") as fh:
        fh.write(b"BLENDER-not-really")
    with open(os.path.join(package, "manifest.json"), "w") as fh:
        json.dump({"asset": "Crate", "format": "glb", "generator": "Mixar export_package",
                   "files": [{"file": "Crate.glb"}, {"file": "Crate_source.blend"}],
                   "engine": {"target": "godot", "version": 1, "collision_nodes": 1,
                              "objects": [{"name": "Crate", "body": "static",
                                           "collision": {"shape": "convex",
                                                         "nodes": ["Crate_col-convcolonly"]}}]}}, fh)

    env = dict(os.environ, HOME=home)
    log_path = os.path.join(tmp, "godot.log")
    log = open(log_path, "w")
    # The first run imports the project; the editor then loads the plugin.
    proc = subprocess.Popen([args.godot, "--headless", "--editor", "--path", project],
                            env=env, stdout=log, stderr=subprocess.STDOUT)
    try:
        discovery = None
        deadline = time.time() + 120
        while time.time() < deadline and discovery is None:
            found = glob.glob(os.path.join(home, ".mixar", "engine-link", "godot-*.json"))
            if found:
                discovery = found[0]
            elif proc.poll() is not None:
                break
            else:
                time.sleep(0.5)
        check(discovery is not None, "discovery file written")
        if discovery is None:
            return 1
        time.sleep(0.5)
        info = json.load(open(discovery))
        check(oct(os.stat(discovery).st_mode & 0o777) == "0o600", "discovery file is owner-only",
              oct(os.stat(discovery).st_mode & 0o777))
        check(info["engine"] == "godot" and info["port"] >= 9890 and len(info["token"]) == 48,
              "discovery carries engine, port, token")
        client = Client(info["port"], info["token"])

        # --- transport guards -------------------------------------------------
        status, _, _ = client.raw({"jsonrpc": "2.0", "id": 1, "method": "ping"})
        check(status == 401, "no token is refused", status)
        status, _, _ = client.raw({"jsonrpc": "2.0", "id": 1, "method": "ping"},
                                  {"Authorization": f"Bearer {info['token']}", "Origin": "https://evil.example"})
        check(status == 403, "a browser Origin is refused", status)
        status, _, _ = client.raw({"jsonrpc": "2.0", "id": 1, "method": "tools/list"},
                                  {"Authorization": f"Bearer {info['token']}", "Mcp-Session-Id": "nope"})
        check(status == 404, "an unknown session must re-initialize", status)

        # --- handshake -------------------------------------------------------
        init = client.initialize()
        check(init["serverInfo"]["name"] == "mixar-link-godot" and "tools" in init["capabilities"],
              "initialize")
        status, _, _ = client.raw({"jsonrpc": "2.0", "method": "notifications/initialized"},
                                  {"Authorization": f"Bearer {info['token']}", "Mcp-Session-Id": client.session})
        check(status == 202, "notification answered 202", status)
        _, _, listed = client.rpc("tools/list")
        names = {t["name"] for t in listed["result"]["tools"]}
        check({"status", "import_package", "new_scene", "place", "scene_tree", "play", "stop",
               "capture", "log", "save_scene", "open_scene"} <= names, "tools/list", sorted(names))

        st = client.call("status")["structuredContent"]
        check(st["engine"] == "godot" and st["project_name"] == "Mixar Link E2E", "status", st)

        # --- build a level ----------------------------------------------------
        r = client.call("new_scene", {"name": "Level", "set_main": True})
        check(not r["isError"] and r["structuredContent"]["scene"] == "res://mixar/levels/Level.tscn",
              "new_scene", r)
        r = client.call("new_scene", {"name": "Level"})
        check(r["isError"] and "exists" in r["content"][0]["text"], "new_scene refuses to overwrite")
        r = client.call("import_package", {"source_dir": package, "folder": "Crate"})
        sc = r["structuredContent"]
        check(not r["isError"] and sc["main_scene"] == "res://mixar/Crate/Crate.glb" and sc["imported"],
              "import_package", r)
        check(sc.get("files_copied") == 2 and not os.path.exists(os.path.join(project, "mixar", "Crate",
                                                                               "Crate_source.blend")),
              "import skips the .blend source", sc)
        check(sc.get("collision_nodes") == 1 and sc.get("engine_target") == "godot", "import reads the manifest")
        r = client.call("import_package", {"source_dir": package, "folder": "../escape"})
        check(r["isError"], "import refuses a path-like folder")
        r = client.call("place", {"scene": "res://mixar/Crate/Crate.glb", "name": "Crate1",
                                  "position": [2, 3, 0.5], "yaw_deg": 90})
        check(not r["isError"] and r["structuredContent"]["node"] == "Crate1", "place", r)
        check(r["structuredContent"].get("position") == [2.0, 3.0, 0.5], "place round-trips the Blender frame",
              r["structuredContent"].get("position"))
        tree = client.call("scene_tree")["structuredContent"]
        paths = {n["path"]: n for n in tree["nodes"]}
        check({".", "Sun", "Environment", "Camera", "Crate1"} <= set(paths), "scene_tree", sorted(paths))
        check(paths.get("Crate1", {}).get("instance_of") == "res://mixar/Crate/Crate.glb",
              "scene_tree names the instanced package")
        check(not client.call("save_scene")["isError"], "save_scene")
        saved = open(os.path.join(project, "mixar", "levels", "Level.tscn")).read()
        check("Crate1" in saved, "the level on disk holds the placed crate")

        # --- run it -------------------------------------------------------------
        r = client.call("play", {"scene": "main"}, timeout=60)
        check(not r["isError"] and r["structuredContent"]["game_connected"], "play connects the game", r)
        seq = r["structuredContent"].get("log_seq", 0)
        lines = []
        deadline = time.time() + 15
        while time.time() < deadline:
            lines = client.call("log", {"since": seq})["structuredContent"]["lines"]
            if any("MIXAR_TEST_ERROR" in l["text"] for l in lines):
                break
            time.sleep(0.5)
        game = [l for l in lines if l["source"] == "game"]
        check(any("MIXAR_TEST_GAME_READY" in l["text"] for l in game), "game prints reach the log",
              [l["text"] for l in lines][-10:])
        check(any("MIXAR_TEST_ERROR" in l["text"] and l["level"] == "error" for l in game),
              "game errors reach the log as errors")
        errs = client.call("log", {"since": seq, "errors_only": True})["structuredContent"]["lines"]
        check(errs and all(l["level"] != "info" for l in errs), "errors_only filters")
        r = client.call("capture", {"source": "game"}, timeout=30)
        if r["isError"] or args.windowed_game:
            check(not args.windowed_game and "headless" in r["content"][0]["text"],
                  "capture of a headless game says why", r)
        else:
            img = next(c for c in r["content"] if c["type"] == "image")
            check(base64.b64decode(img["data"])[:2] == b"\xff\xd8", "capture returns a JPEG")
        r = client.call("stop")
        check(not r["isError"] and not r["structuredContent"]["playing"], "stop", r)
        r = client.call("capture", {"source": "game"})
        check(r["isError"] and "not running" in r["content"][0]["text"], "capture without a game is refused")
        r = client.call("nope")
        check(r["isError"], "unknown tool is an error result")
    finally:
        proc.terminate()
        try:
            proc.wait(10)
        except subprocess.TimeoutExpired:
            proc.kill()
        log.close()
        if FAILURES or args.keep:
            print(f"temp folder kept: {tmp} (editor log: {log_path})")
        else:
            shutil.rmtree(tmp, ignore_errors=True)
    print(f"\n{'FAILED' if FAILURES else 'OK'}: {len(FAILURES)} failure(s)")
    return 1 if FAILURES else 0


if __name__ == "__main__":
    sys.exit(main())
