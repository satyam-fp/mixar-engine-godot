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
	print("\\u001b[31mMIXAR_ANSI_RED\\u001b[0m")
	push_error("MIXAR_TEST_ERROR")
	if OS.get_environment("MIXAR_TEST_MINIMISE") == "1" and DisplayServer.get_name() != "headless":
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MINIMIZED)
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


# A small humanoid skeleton (glTF: Y up, facing +Z, the character's left at +X):
# name, parent, local translation. Tripo auto-rig names; MIXAMO_NAMES renames.
HUMANOID = [
    ("BoneRoot", None, (0, 0, 0)), ("Hip", "BoneRoot", (0, 1.0, 0)), ("Waist", "Hip", (0, .1, 0)),
    ("Spine01", "Waist", (0, .15, 0)), ("Spine02", "Spine01", (0, .15, 0)),
    ("NeckTwist01", "Spine02", (0, .2, 0)), ("Head", "NeckTwist01", (0, .1, 0)),
    ("L_Clavicle", "Spine02", (.05, .15, 0)), ("L_Upperarm", "L_Clavicle", (.15, 0, 0)),
    ("L_Forearm", "L_Upperarm", (.28, 0, 0)), ("L_Hand", "L_Forearm", (.25, 0, 0)),
    ("R_Clavicle", "Spine02", (-.05, .15, 0)), ("R_Upperarm", "R_Clavicle", (-.15, 0, 0)),
    ("R_Forearm", "R_Upperarm", (-.28, 0, 0)), ("R_Hand", "R_Forearm", (-.25, 0, 0)),
    ("L_Thigh", "Hip", (.1, -.05, 0)), ("L_Calf", "L_Thigh", (0, -.45, 0)), ("L_Foot", "L_Calf", (0, -.45, 0)),
    ("L_ToeBase", "L_Foot", (0, -.05, .12)),
    ("R_Thigh", "Hip", (-.1, -.05, 0)), ("R_Calf", "R_Thigh", (0, -.45, 0)), ("R_Foot", "R_Calf", (0, -.45, 0)),
    ("R_ToeBase", "R_Foot", (0, -.05, .12)),
]
MIXAMO_NAMES = {"BoneRoot": "Root", "Hip": "Hips", "Waist": "Spine", "Spine01": "Spine1", "Spine02": "Spine2",
                "NeckTwist01": "Neck", "Head": "Head"}
for _side, _full in (("L", "Left"), ("R", "Right")):
    MIXAMO_NAMES.update({f"{_side}_Clavicle": f"{_full}Shoulder", f"{_side}_Upperarm": f"{_full}Arm",
                         f"{_side}_Forearm": f"{_full}ForeArm", f"{_side}_Hand": f"{_full}Hand",
                         f"{_side}_Thigh": f"{_full}UpLeg", f"{_side}_Calf": f"{_full}Leg",
                         f"{_side}_Foot": f"{_full}Foot", f"{_side}_ToeBase": f"{_full}ToeBase"})


def glb_humanoid(path: str, naming: str = "tripo", wave: bool = False) -> None:
    """A skinned GLB on HUMANOID with Tripo or Mixamo ("mixamorig:") bone names;
    ``wave`` adds a "Wave" clip raising the left upper arm 70 degrees at 0.4 s."""
    import math
    names = [n if naming == "tripo" else "mixamorig:" + MIXAMO_NAMES[n] for n, _, _ in HUMANOID]
    index = {n: i + 2 for i, (n, _, _) in enumerate(HUMANOID)}   # 0 Armature, 1 Body
    world = {}
    for n, parent, t in HUMANOID:
        base = world[parent] if parent else (0, 0, 0)
        world[n] = tuple(a + b for a, b in zip(base, t))
    pos = struct.pack("<12f", -.1, .9, 0, .1, .9, 0, 0, 1.1, 0, 0, 1.0, .1)
    idx = struct.pack("<12H", 0, 1, 2, 0, 1, 3, 0, 2, 3, 1, 2, 3)
    joints = struct.pack("<16B", *([1, 0, 0, 0] * 4))
    weights = struct.pack("<16f", *([1, 0, 0, 0] * 4))
    ibm = b"".join(struct.pack("<16f", 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, -x, -y, -z, 1)
                   for x, y, z in (world[n] for n, _, _ in HUMANOID))
    chunks = [pos, idx, joints, weights, ibm]
    if wave:
        half = math.radians(35)
        chunks += [struct.pack("<3f", 0, .4, .8),
                   struct.pack("<12f", 0, 0, 0, 1, 0, 0, math.sin(half), math.cos(half), 0, 0, 0, 1)]
    views, blob = [], b""
    for c in chunks:
        views.append({"buffer": 0, "byteOffset": len(blob), "byteLength": len(c)})
        blob += c + b"\0" * (-len(c) % 4)
    accessors = [
        {"bufferView": 0, "componentType": 5126, "count": 4, "type": "VEC3", "min": [-.1, .9, 0], "max": [.1, 1.1, .1]},
        {"bufferView": 1, "componentType": 5123, "count": 12, "type": "SCALAR"},
        {"bufferView": 2, "componentType": 5121, "count": 4, "type": "VEC4"},
        {"bufferView": 3, "componentType": 5126, "count": 4, "type": "VEC4"},
        {"bufferView": 4, "componentType": 5126, "count": len(HUMANOID), "type": "MAT4"},
    ]
    nodes = [{"name": "Armature", "children": [1, index["BoneRoot"]]},
             {"name": "Body", "mesh": 0, "skin": 0}]
    for (n, _, t), name in zip(HUMANOID, names):
        node = {"name": name, "translation": list(t)}
        kids = [index[c] for c, p, _ in HUMANOID if p == n]
        if kids:
            node["children"] = kids
        nodes.append(node)
    doc = {"asset": {"version": "2.0"}, "scene": 0, "scenes": [{"nodes": [0]}], "nodes": nodes,
           "meshes": [{"primitives": [{"attributes": {"POSITION": 0, "JOINTS_0": 2, "WEIGHTS_0": 3},
                                       "indices": 1}]}],
           "skins": [{"joints": [index[n] for n, _, _ in HUMANOID], "skeleton": index["BoneRoot"],
                      "inverseBindMatrices": 4}],
           "accessors": accessors, "bufferViews": views, "buffers": [{"byteLength": len(blob)}]}
    if wave:
        accessors += [{"bufferView": 5, "componentType": 5126, "count": 3, "type": "SCALAR", "min": [0], "max": [.8]},
                      {"bufferView": 6, "componentType": 5126, "count": 3, "type": "VEC4"}]
        doc["animations"] = [{"name": "Wave", "samplers": [{"input": 5, "output": 6}],
                              "channels": [{"sampler": 0, "target": {"node": index["L_Upperarm"],
                                                                      "path": "rotation"}}]}]
    js = json.dumps(doc).encode()
    js += b" " * (-len(js) % 4)
    body = struct.pack("<II", len(js), 0x4E4F534A) + js + struct.pack("<II", len(blob), 0x004E4942) + blob
    with open(path, "wb") as fh:
        fh.write(struct.pack("<III", 0x46546C67, 2, 12 + len(body)) + body)


def humanoid_package(root: str, name: str, naming: str, wave: bool) -> str:
    folder = os.path.join(root, name)
    os.makedirs(folder, exist_ok=True)
    glb_humanoid(os.path.join(folder, name + ".glb"), naming, wave)
    with open(os.path.join(folder, "manifest.json"), "w") as fh:
        json.dump({"asset": name, "format": "glb", "generator": "Mixar export_package",
                   "files": [{"file": name + ".glb"}]}, fh)
    return folder


def glb_level(path: str, nodes: list[dict]) -> None:
    """A GLB of unit cubes: each node {name, t (glTF xyz), s (scale), extras?,
    children?}; a child shares its parent's transform (a collision hint)."""
    v = [(x, y, z) for x in (-.5, .5) for y in (-.5, .5) for z in (-.5, .5)]
    faces = [(0, 1, 3), (0, 3, 2), (4, 6, 7), (4, 7, 5), (0, 4, 5), (0, 5, 1),
             (2, 3, 7), (2, 7, 6), (0, 2, 6), (0, 6, 4), (1, 5, 7), (1, 7, 3)]
    pos = struct.pack(f"<{len(v) * 3}f", *[c for p in v for c in p])
    idx = struct.pack(f"<{len(faces) * 3}H", *[i for f in faces for i in f])
    blob = pos + idx
    flat, roots = [], []

    def add(n):
        i = len(flat)
        flat.append(None)
        node = {"name": n["name"], "mesh": 0}
        if "t" in n:
            node["translation"] = n["t"]
        if "s" in n:
            node["scale"] = n["s"]
        if "extras" in n:
            node["extras"] = n["extras"]
        kids = [add({"name": c}) for c in n.get("children", [])]
        if kids:
            node["children"] = kids
        flat[i] = node
        return i

    roots = [add(n) for n in nodes]
    doc = {"asset": {"version": "2.0"}, "scene": 0, "scenes": [{"nodes": roots}], "nodes": flat,
           "meshes": [{"primitives": [{"attributes": {"POSITION": 0}, "indices": 1}]}],
           "accessors": [{"bufferView": 0, "componentType": 5126, "count": len(v), "type": "VEC3",
                          "min": [-.5, -.5, -.5], "max": [.5, .5, .5]},
                         {"bufferView": 1, "componentType": 5123, "count": len(faces) * 3, "type": "SCALAR"}],
           "bufferViews": [{"buffer": 0, "byteOffset": 0, "byteLength": len(pos)},
                           {"buffer": 0, "byteOffset": len(pos), "byteLength": len(idx)}],
           "buffers": [{"byteLength": len(blob)}]}
    js = json.dumps(doc).encode()
    js += b" " * (-len(js) % 4)
    blob += b"\0" * (-len(blob) % 4)
    body = struct.pack("<II", len(js), 0x4E4F534A) + js + struct.pack("<II", len(blob), 0x004E4942) + blob
    with open(path, "wb") as fh:
        fh.write(struct.pack("<III", 0x46546C67, 2, 12 + len(body)) + body)


# The Ruins test level, in glTF space (Y up; Blender (x, y, z) = glTF (x, z, -y)).
# The door (6 m wide) blocks the straight path from the spawn to the goal until
# both relics are collected; it then slides up out of the way.
RUINS = [
    {"name": "Ground", "t": [0, -0.5, -6], "s": [30, 1, 30],
     "extras": {"mixar_body": "static", "mixar_nav": "walkable"}, "children": ["Ground_col-colonly"]},
    {"name": "Spawn", "t": [0, 0.1, 2], "s": [0.3, 0.2, 0.3], "extras": {"mixar_role": "spawn"}},
    {"name": "Relic1", "t": [-3, 0.6, -4], "s": [0.4, 0.4, 0.4], "extras": {"mixar_role": "pickup"},
     "children": ["Relic1_col-convcolonly"]},
    {"name": "Relic2", "t": [3, 0.6, -6], "s": [0.4, 0.4, 0.4], "extras": {"mixar_role": "pickup"}},
    {"name": "TempleDoor", "t": [0, 1, -10], "s": [6, 2, 0.3],
     "extras": {"mixar_role": "door", "mixar_body": "kinematic", "mixar_pivot": "slide_z"},
     "children": ["TempleDoor_col-convcolonly"]},
    {"name": "Goal", "t": [0, 1, -13], "s": [2, 2, 2], "extras": {"mixar_role": "goal"}},
    # Walls either side of the door: the door is the only way to the goal.
    {"name": "WallWest", "t": [-9, 1.5, -10], "s": [12, 3, 0.3], "extras": {"mixar_body": "static"},
     "children": ["WallWest_col-convcolonly"]},
    {"name": "WallEast", "t": [9, 1.5, -10], "s": [12, 3, 0.3], "extras": {"mixar_body": "static"},
     "children": ["WallEast_col-convcolonly"]},
]

# A side-scroller strip along Blender X: a pickup, a low block to jump, the goal.
STRIP = [
    {"name": "Floor", "t": [10, -0.5, 0], "s": [30, 1, 4], "extras": {"mixar_body": "static"},
     "children": ["Floor_col-colonly"]},
    {"name": "Spawn", "t": [0, 0.1, 0], "s": [0.3, 0.2, 0.3], "extras": {"mixar_role": "spawn"}},
    {"name": "Coin", "t": [6, 0.8, 0], "s": [0.4, 0.4, 0.4], "extras": {"mixar_role": "pickup"}},
    {"name": "Block", "t": [10, 0.4, 0], "s": [1, 0.8, 4], "extras": {"mixar_body": "static"},
     "children": ["Block_col-convcolonly"]},
    {"name": "Flag", "t": [16, 1, 0], "s": [1, 2, 2], "extras": {"mixar_role": "goal"}},
]


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


def launch(godot: str, project: str, home: str, log_path: str):
    """Start a headless editor on `project`; (process, Client, log file) once its
    discovery file appears, or (process, None, log file)."""
    log = open(log_path, "w")
    proc = subprocess.Popen([godot, "--headless", "--editor", "--path", project],
                            env=dict(os.environ, HOME=home), stdout=log, stderr=subprocess.STDOUT)
    deadline = time.time() + 120
    while time.time() < deadline:
        found = glob.glob(os.path.join(home, ".mixar", "engine-link", "godot-*.json"))
        if found:
            time.sleep(0.5)
            info = json.load(open(found[0]))
            client = Client(info["port"], info["token"])
            client.initialize()
            return proc, client, log
        if proc.poll() is not None:
            break
        time.sleep(0.5)
    return proc, None, log


def plugin_mode_checks(godot: str, tmp: str) -> None:
    """A studio's existing project (plugin mode): Mixar keeps to res://mixar/."""
    home = os.path.join(tmp, "home-plugin")
    project = os.path.join(tmp, "studio")
    os.makedirs(home)
    os.makedirs(project)
    shutil.copytree(os.path.join(ROOT, "addons"), os.path.join(project, "addons"))
    with open(os.path.join(project, "project.godot"), "w") as fh:
        fh.write(PROJECT_GODOT.replace("[autoload]\n\nTestPrinter=\"*res://test_printer.gd\"\n", "")
                 + '\n[mixar_link]\n\nproject_mode="plugin"\neditable_scenes=PackedStringArray("res://shared.tscn")\n')
    for name in ("studio_level.tscn", "shared.tscn"):
        with open(os.path.join(project, name), "w") as fh:
            fh.write('[gd_scene format=3]\n\n[node name="Root" type="Node3D"]\n')
    package = os.path.join(tmp, "Mixar Exports", "Crate")
    proc, client, log = launch(godot, project, home, os.path.join(tmp, "godot-plugin.log"))
    try:
        check(client is not None, "plugin-mode editor connects")
        if client is None:
            return
        check(client.call("status")["structuredContent"].get("project_mode") == "plugin", "status reports plugin mode")
        before = open(os.path.join(project, "project.godot")).read()
        r = client.call("new_scene", {"name": "Arena", "set_main": True})
        check(r["isError"] and "plugin mode" in r["content"][0]["text"], "plugin mode refuses to set the main scene", r)
        r = client.call("new_scene", {"name": "Arena", "set_main": False, "template": "top_down"})
        check(r["isError"] and "input actions" in r["content"][0]["text"],
              "plugin mode refuses to add input actions", r)
        r = client.call("new_scene", {"name": "Arena", "set_main": False})
        check(not r["isError"], "plugin mode still builds levels under res://mixar", r)
        r = client.call("import_package", {"source_dir": package, "folder": "Crate"})
        check(not r["isError"], "plugin mode imports packages into res://mixar", r)
        r = client.call("place", {"scene": "res://mixar/Crate/Crate.glb"})
        check(not r["isError"], "plugin mode places into its own level", r)
        client.call("open_scene", {"scene": "res://studio_level.tscn"})
        r = client.call("place", {"scene": "res://mixar/Crate/Crate.glb"})
        check(r["isError"] and "editable_scenes" in r["content"][0]["text"],
              "plugin mode refuses to edit the studio's own level", r)
        r = client.call("set_property", {"node": ".", "property": "visible", "value": False})
        check(r["isError"], "plugin mode refuses set_property on the studio's level")
        client.call("open_scene", {"scene": "res://shared.tscn"})
        r = client.call("place", {"scene": "res://mixar/Crate/Crate.glb"})
        check(not r["isError"], "plugin mode edits a level the studio listed", r)
        r = client.call("build_web")
        check(r["isError"], "plugin mode build_web is refused (templates or preset)")
        check("Crate" not in open(os.path.join(project, "studio_level.tscn")).read(), "the studio level is untouched")
        after = open(os.path.join(project, "project.godot")).read()
        check("run/main_scene" not in after and "move_forward" not in after and before == after,
              "project.godot is untouched")
    finally:
        proc.terminate()
        try:
            proc.wait(10)
        except subprocess.TimeoutExpired:
            proc.kill()
        log.close()


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

    # --windowed-game minimises the game window at once: capture must still draw.
    env = dict(os.environ, HOME=home, MIXAR_TEST_MINIMISE="1" if args.windowed_game else "0")
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
        everything = client.call("log", {"since": 0, "max_lines": 1000})["structuredContent"]["lines"]
        check(any(l["text"] == "MIXAR_ANSI_RED" for l in everything),
              "ANSI colour codes are stripped and the reply is valid JSON",
              [l["text"] for l in everything if "ANSI" in l["text"]])
        errs = client.call("log", {"since": seq, "errors_only": True})["structuredContent"]["lines"]
        check(errs and all(l["level"] != "info" for l in errs), "errors_only filters")
        r = client.call("capture", {"source": "game"}, timeout=30)
        if args.windowed_game:
            img = next((c for c in r.get("content", []) if c.get("type") == "image"), None)
            check(not r["isError"] and img and base64.b64decode(img["data"])[:2] == b"\xff\xd8",
                  "a minimised game window is still captured (forced draw)", r if r["isError"] else "")
        else:
            check(r["isError"] and "headless" in r["content"][0]["text"], "capture of a headless game says why", r)
        r = client.call("stop")
        check(not r["isError"] and not r["structuredContent"]["playing"], "stop", r)
        r = client.call("capture", {"source": "game"})
        check(r["isError"] and "not running" in r["content"][0]["text"], "capture without a game is refused")
        r = client.call("nope")
        check(r["isError"], "unknown tool is an error result")

        # --- P2: tags become behaviour; the template plays ---------------------
        ruins_pkg = os.path.join(tmp, "Mixar Exports", "Ruins")
        os.makedirs(ruins_pkg)
        glb_level(os.path.join(ruins_pkg, "Ruins.glb"), RUINS)
        with open(os.path.join(ruins_pkg, "manifest.json"), "w") as fh:
            json.dump({"asset": "Ruins", "files": [{"file": "Ruins.glb"}],
                       "engine": {"target": "godot", "version": 1, "objects": [], "collision_nodes": 3}}, fh)
        r = client.call("new_scene", {"name": "RuinsLevel", "set_main": True, "template": "third_person"})
        check(not r["isError"] and "jump" in r["structuredContent"]["input_actions"], "new_scene third_person", r)
        r = client.call("new_scene", {"name": "Other", "template": "racing"})
        check(r["isError"] and "Unknown template" in r["content"][0]["text"], "unknown template refused")
        godot_cfg = open(os.path.join(project, "project.godot")).read()
        check("move_forward=" in godot_cfg and "camera_left=" in godot_cfg, "the input map is saved")
        r = client.call("import_package", {"source_dir": ruins_pkg, "folder": "Ruins"})
        check(not r["isError"] and r["structuredContent"]["imported"], "import the ruins", r)
        r = client.call("place", {"scene": "res://mixar/Ruins/Ruins.glb", "name": "Ruins"})
        check(not r["isError"], "place the ruins at the origin", r)
        tree = {n["path"] for n in client.call("scene_tree")["structuredContent"]["nodes"]}
        check({"Player", "Game", "HUD", "Ruins"} <= tree, "template nodes in the level", sorted(tree))

        # Scripts, nodes, properties.
        r = client.call("write_script", {"path": "res://mixar/scripts/spin.gd",
                                         "source": "extends Node3D\nfunc _process(d):\n\trotate_y(d)\n"})
        check(not r["isError"], "write_script", r)
        r = client.call("write_script", {"path": "res://mixar/scripts/bad.gd", "source": "extends Node3D\nfunc (:\n"})
        check(r["isError"] and not os.path.exists(os.path.join(project, "mixar", "scripts", "bad.gd")),
              "a script that does not compile is not written", r)
        check(r["isError"] and r["structuredContent"].get("errors"), "compile errors are returned", r)
        r = client.call("write_script", {"path": "res://addons/evil.gd", "source": "extends Node"})
        check(r["isError"], "scripts outside res://mixar/scripts are refused")
        r = client.call("add_node", {"type": "Node3D", "name": "Marker", "script": "res://mixar/scripts/spin.gd",
                                     "position": [5, 0, 1]})
        check(not r["isError"] and r["structuredContent"]["node"] == "Marker", "add_node with a script", r)
        r = client.call("add_node", {"type": "EditorPlugin", "name": "X"})
        check(r["isError"], "editor-only types are refused")
        r = client.call("set_property", {"node": "Marker", "property": "position", "value": [1, 2, 3]})
        check(not r["isError"] and "Vector3(1, 2, 3)" in r["structuredContent"]["value"], "set_property", r)
        r = client.call("set_property", {"node": "Marker", "property": "nope", "value": 1})
        check(r["isError"], "unknown property refused")
        r = client.call("build_web")
        check(r["isError"] and "export templates" in r["content"][0]["text"] or not r["isError"],
              "build_web without templates says how to install them", r)
        if r["isError"]:
            r = client.call("build_info")
            check(r["isError"] and "build_web first" in r["content"][0]["text"], "build_info without a build")
            web = os.path.join(project, "mixar_build", "web")
            os.makedirs(web, exist_ok=True)
            for name, data in (("index.html", b"<html></html>"), ("index.wasm", b"\0asm1234")):
                open(os.path.join(web, name), "wb").write(data)
        r = client.call("build_info")
        files = {f["name"]: f["bytes"] for f in r["structuredContent"].get("files", [])}
        check(not r["isError"] and files.get("index.html") and os.path.isabs(r["structuredContent"]["dir"]),
              "build_info lists the build", r)

        r = client.call("play", {"scene": "main"}, timeout=60)
        check(not r["isError"], "play the ruins", r)
        steps = [
            {"wait": 1.0}, {"state": True},
            {"walk_to": [0, 13, 1], "timeout": 8},
            {"walk_to": [-3, 4, 0.6], "timeout": 10},
            {"walk_to": [3, 6, 0.6], "timeout": 10},
            {"wait": 1.6},
            {"walk_to": [0, 13, 1], "timeout": 10},
            {"hold": "jump", "seconds": 0.1},
            {"hold": "fly", "seconds": 0.1},
        ]
        r = client.call("playtest", {"steps": steps}, timeout=120)
        check(not r["isError"], "playtest ran", r)
        res = r["structuredContent"]["steps"] if not r["isError"] else []
        def st(i):
            return res[i]["state"] if i < len(res) else {}
        check(st(1).get("total") == 2 and st(1).get("collected") == 0 and not st(1).get("doors_open"),
              "two pickups counted, door shut", st(1))
        check(len(res) > 2 and res[2].get("no_path") and not st(2).get("won"),
              "the shut door leaves the goal with no path", res[2] if len(res) > 2 else None)
        check(st(3).get("collected") == 1, "first relic collected", res[3] if len(res) > 3 else None)
        check(st(4).get("collected") == 2 and st(4).get("doors_open"), "second relic opens the door",
              res[4] if len(res) > 4 else None)
        check(st(6).get("won") is True and res[6].get("routed"), "the goal wins once the door is open",
              res[6] if len(res) > 6 else None)
        check(len(res) == 9 and "no input action 'fly'" in res[8].get("error", ""),
              "an unknown action stops the playtest", res[-1] if res else None)
        client.call("stop")

        # --- full scripting: files, settings, custom gameplay ----------------------
        r = client.call("list_files", {"dir": "res://addons/mixar_link/templates"})
        check(not r["isError"] and any(f["path"].endswith("game.gd") for f in r["structuredContent"]["files"]),
              "list_files", r)
        r = client.call("read_file", {"path": "res://addons/mixar_link/templates/game.gd"})
        check(not r["isError"] and "on_mixar_event" in r["structuredContent"]["content"], "read_file", r)
        r = client.call("read_file", {"path": "res://.godot/editor/filesystem_cache10"})
        check(r["isError"], "read_file refuses the .godot cache")
        r = client.call("write_file", {"path": "res://addons/evil.gd", "content": "extends Node"})
        check(r["isError"] and "res://mixar" in r["content"][0]["text"], "write_file keeps to res://mixar")
        countdown = (
            "extends Node\n"
            "## A countdown: reports time_left; at zero the game is lost.\n"
            "@export var seconds := 30.0\n"
            "var jumps := 0\n"
            "func _ready() -> void:\n"
            "\tadd_to_group(\"mixar_state\")\n"
            "func _process(delta: float) -> void:\n"
            "\tif seconds > 0.0:\n"
            "\t\tseconds = maxf(0.0, seconds - delta)\n"
            "\t\tif seconds == 0.0:\n"
            "\t\t\tget_tree().call_group(\"mixar_game\", \"on_mixar_event\", \"lose\", self)\n"
            "func _unhandled_input(event: InputEvent) -> void:\n"
            "\tif event.is_action_pressed(\"jump\"):\n"
            "\t\tjumps += 1\n"
            "func mixar_state() -> Dictionary:\n"
            "\treturn {\"time_left\": snappedf(seconds, 0.1), \"event_jumps\": jumps}\n")
        r = client.call("write_file", {"path": "res://mixar/scripts/countdown.gd", "content": countdown})
        check(not r["isError"], "write_file a gameplay script", r)
        lift = ("extends AnimatableBody3D\n"
                "var _t := 0.0\n"
                "func _physics_process(delta: float) -> void:\n"
                "\t_t += delta\n"
                "\tposition.y = 1.0 + sin(_t * 2.0)\n")
        check(not client.call("write_file", {"path": "res://mixar/scripts/lift.gd", "content": lift})["isError"],
              "write_file a platform script")
        bad_scene = '[gd_scene format=3]\n\n[node name="X" type="NotAType"]\n'
        r = client.call("write_file", {"path": "res://mixar/scenes/bad.tscn", "content": bad_scene})
        check(r["isError"] and not os.path.exists(os.path.join(project, "mixar", "scenes", "bad.tscn")),
              "a scene that does not load is not written", r)
        good_scene = ('[gd_scene load_steps=2 format=3]\n\n'
                      '[ext_resource type="Script" path="res://mixar/scripts/lift.gd" id="1"]\n\n'
                      '[node name="Lift" type="AnimatableBody3D"]\nscript = ExtResource("1")\n')
        r = client.call("write_file", {"path": "res://mixar/scenes/lift.tscn", "content": good_scene})
        check(not r["isError"], "write_file a scene", r)
        r = client.call("add_node", {"type": "Node", "name": "Countdown", "script": "res://mixar/scripts/countdown.gd"})
        check(not r["isError"], "attach the countdown", r)
        r = client.call("place", {"scene": "res://mixar/scenes/lift.tscn", "name": "Lift", "position": [6, 0, 0]})
        check(not r["isError"], "place the written lift scene", r)
        r = client.call("set_property", {"node": "Countdown", "property": "seconds", "value": 4.0})
        check(not r["isError"], "set the countdown's exported seconds", r)
        r = client.call("set_property", {"node": "Ruins/Relic1", "property": "visible", "value": True})
        check(not r["isError"], "set a property inside a placed package (editable children)", r)
        r = client.call("project_setting", {"name": "input/dash", "value": {"keys": ["Shift"], "mouse": ["right"]}})
        check(not r["isError"] and "dash=" in open(os.path.join(project, "project.godot")).read(),
              "project_setting adds an input action", r)
        r = client.call("project_setting", {"name": "autoload/Score", "value": "res://mixar/scripts/countdown.gd"})
        check(not r["isError"] and "Score=" in open(os.path.join(project, "project.godot")).read(),
              "project_setting adds an autoload", r)
        client.call("project_setting", {"name": "autoload/Score", "value": None})
        r = client.call("project_setting", {"name": "network/limits/x", "value": 1})
        check(r["isError"], "project_setting refuses settings outside its list")
        # The CS:GO run's realism pass was refused the renderer and AA settings.
        r = client.call("project_setting", {"name": "rendering/anti_aliasing/quality/msaa_3d", "value": 2})
        check(not r["isError"], "project_setting sets rendering quality settings", r)
        client.call("project_setting", {"name": "rendering/anti_aliasing/quality/msaa_3d", "value": 0})
        r = client.call("remove_node", {"node": "Marker"})
        check(not r["isError"], "remove_node", r)
        r = client.call("play", {"scene": "main"}, timeout=60)
        r = client.call("playtest", {"steps": [
            {"wait": 0.5}, {"press": "jump"}, {"press": "jump"},
            {"inspect": {"node": "Lift", "properties": ["global_position"]}},
            {"wait": 0.7}, {"inspect": {"node": "Lift", "properties": ["global_position"]}},
            {"wait": 4.0}, {"state": True}]}, timeout=120)
        res = r["structuredContent"]["steps"] if not r["isError"] else []
        z0 = res[3]["values"]["global_position"][2] if len(res) > 3 and "values" in res[3] else None
        z1 = res[5]["values"]["global_position"][2] if len(res) > 5 and "values" in res[5] else None
        check(z0 is not None and z1 is not None and abs(z1 - z0) > 0.2, "the written lift moves in the game", (z0, z1))
        final = res[7]["state"] if len(res) > 7 else {}
        check(final.get("event_jumps") == 2,
              "a playtest press reaches a script's _unhandled_input (once per press)", final)
        check(final.get("time_left") == 0.0 and final.get("lost") is True,
              "the written countdown reports time_left and loses the game", final)
        errors = client.call("log", {"since": r["structuredContent"].get("steps", [{}])[0].get("seq", 0) if False else 0,
                                     "errors_only": True})["structuredContent"]["lines"]
        check(not any("countdown.gd" in l["file"] or "lift.gd" in l["file"] for l in errors),
              "the written scripts raise no errors", [l["text"] for l in errors][-5:])
        r = client.call("playtest", {"steps": [
            {"inspect": {"node": ".", "properties": ["name"]}},
            {"inspect": {"node": "Lift", "properties": ["rotation", "global_position"]}}]}, timeout=60)
        res = r["structuredContent"]["steps"] if not r["isError"] else []
        check(len(res) > 1 and "error" not in res[0] and res[0].get("node") == ".",
              "inspect '.' reads the level root in the running game", res[:1])
        check(len(res) > 1 and res[1].get("blender_frame") == ["global_position"]
              and len(res[1].get("values", {}).get("rotation", [])) == 3,
              "inspect keeps rotation in Godot's frame, positions in Blender's", res[1:2])
        client.call("stop")
        broken = ('[gd_scene load_steps=2 format=3]\n\n'
                  '[sub_resource type="GDScript" id="1"]\nscript/source = "extends Node\\nfunc _ready():\\n\\tvar x := \\n"\n\n'
                  '[node name="Broken" type="Node"]\nscript = SubResource("1")\n')
        r = client.call("write_file", {"path": "res://mixar/scenes/embedded_bad.tscn", "content": broken})
        check(r["isError"] and not os.path.exists(os.path.join(project, "mixar", "scenes", "embedded_bad.tscn")),
              "a scene whose embedded script does not compile is not written", r["content"][0]["text"][:200])
        fine = broken.replace('var x := \\n', 'pass\\n')
        r = client.call("write_file", {"path": "res://mixar/scenes/embedded_ok.tscn", "content": fine})
        check(not r["isError"], "a scene with a compiling embedded script is written", r["content"][0]["text"][:200])
        client.call("remove_node", {"node": "Countdown"})
        client.call("remove_node", {"node": "Lift"})

        # P0.4: a Tripo rig and a Mixamo rig go onto Godot's humanoid profile on
        # import, and a clip made on the Mixamo rig plays on the Tripo one.
        hero = humanoid_package(tmp, "Hero", "tripo", wave=False)
        waver = humanoid_package(tmp, "Waver", "mixamo", wave=True)
        r = client.call("import_package", {"source_dir": hero, "folder": "Hero"})
        check(not r["isError"] and r["structuredContent"].get("retarget", {}).get("naming") == "tripo",
              "a Tripo rig is retargeted to the humanoid profile on import", r["structuredContent"])
        r = client.call("import_package", {"source_dir": waver, "folder": "Waver"})
        check(not r["isError"] and r["structuredContent"].get("retarget", {}).get("naming") == "mixamo",
              "a Mixamo rig is retargeted to the humanoid profile on import", r["structuredContent"])
        wave_check = (
            "extends Node3D\n"
            "var angle := -1.0\n"
            "var humanoid := false\n"
            "func _ready() -> void:\n"
            "\tadd_to_group(\"mixar_state\")\n"
            "\tvar src: Node = load(\"res://mixar/Waver/Waver.glb\").instantiate()\n"
            "\tvar wave: Animation = src.find_children(\"*\", \"AnimationPlayer\", true, false)[0].get_animation(\"Wave\")\n"
            "\tvar hero: Node3D = load(\"res://mixar/Hero/Hero.glb\").instantiate()\n"
            "\tadd_child(hero)\n"
            "\tvar skel: Skeleton3D = hero.get_node(\"%GeneralSkeleton\")\n"
            "\thumanoid = skel.find_bone(\"LeftUpperArm\") >= 0 and skel.find_bone(\"L_Upperarm\") < 0\n"
            "\tvar bone := skel.find_bone(\"LeftUpperArm\")\n"
            "\tvar rest := skel.get_bone_pose_rotation(bone)\n"
            "\tvar player := AnimationPlayer.new()\n"
            "\thero.add_child(player)\n"
            "\tplayer.root_node = player.get_path_to(hero)\n"
            "\tvar lib := AnimationLibrary.new()\n"
            "\tlib.add_animation(\"Wave\", wave)\n"
            "\tplayer.add_animation_library(\"\", lib)\n"
            "\tplayer.play(\"Wave\")\n"
            "\tplayer.seek(0.4, true)\n"
            "\tangle = rad_to_deg(rest.angle_to(skel.get_bone_pose_rotation(bone)))\n"
            "\tsrc.free()\n"
            "func mixar_state() -> Dictionary:\n"
            "\treturn {\"wave_angle\": snappedf(angle, 0.1), \"hero_humanoid\": humanoid}\n")
        r = client.call("write_file", {"path": "res://mixar/scripts/wave_check.gd", "content": wave_check})
        check(not r["isError"], "write the retarget check script", r)
        r = client.call("add_node", {"type": "Node3D", "name": "WaveCheck", "script": "res://mixar/scripts/wave_check.gd"})
        check(not r["isError"], "attach the retarget check", r)
        client.call("play", {"scene": "main"}, timeout=60)
        r = client.call("playtest", {"steps": [{"wait": 0.3}, {"state": True}]}, timeout=60)
        res = r["structuredContent"]["steps"] if not r["isError"] else []
        state = res[-1].get("state", {}) if res else {}
        check(state.get("hero_humanoid") is True, "the Tripo rig's bones carry the humanoid names in the game", state)
        check(float(state.get("wave_angle", -1)) > 40.0,
              "a clip made on the Mixamo rig plays on the Tripo rig (left upper arm raised)", state)
        client.call("stop")
        client.call("remove_node", {"node": "WaveCheck"})

        # prove_loop on a fresh run: every pickup, then the goal, unaided.
        r = client.call("play", {"scene": "main"}, timeout=60)
        r = client.call("playtest", {"steps": [{"wait": 1.0}, {"prove_loop": True, "timeout": 12}]}, timeout=200)
        proof = r["structuredContent"]["steps"][1] if not r["isError"] else {}
        check(proof.get("won") is True and proof.get("unreached") == [], "prove_loop wins the ruins", proof)
        check([v.get("target") for v in proof.get("visits", [])][-1:] == ["Goal"], "prove_loop ends at the goal")
        client.call("stop")

        # Templates: top_down and platformer.
        strip_pkg = os.path.join(tmp, "Mixar Exports", "Strip")
        os.makedirs(strip_pkg)
        glb_level(os.path.join(strip_pkg, "Strip.glb"), STRIP)
        with open(os.path.join(strip_pkg, "manifest.json"), "w") as fh:
            json.dump({"asset": "Strip", "files": [{"file": "Strip.glb"}], "engine": {"target": "godot"}}, fh)
        r = client.call("new_scene", {"name": "StripLevel", "set_main": True, "template": "platformer"})
        check(not r["isError"], "new_scene platformer", r)
        client.call("import_package", {"source_dir": strip_pkg, "folder": "Strip"})
        client.call("place", {"scene": "res://mixar/Strip/Strip.glb", "name": "Strip"})
        level = open(os.path.join(project, "mixar", "levels", "StripLevel.tscn")).read()
        check('mode = "platformer"' in level, "the platformer player is saved in its mode")
        client.call("play", {"scene": "main"}, timeout=60)
        r = client.call("playtest", {"steps": [
            {"wait": 1.0},
            {"hold": "move_right", "seconds": 0.6}, {"state": True},
            {"prove_loop": True, "timeout": 10}]}, timeout=200)
        res = r["structuredContent"]["steps"] if not r["isError"] else []
        moved = res[1]["state"]["player_position"] if len(res) > 1 else [0, 0, 0]
        check(moved[0] > 1.0 and abs(moved[1]) < 0.05, "move_right runs along Blender X in the lane",
              moved)
        proof = res[3] if len(res) > 3 else {}
        check(proof.get("won") is True, "the platformer is won over the block (a jump)", proof)
        client.call("stop")
        r = client.call("new_scene", {"name": "TopLevel", "template": "top_down", "ground": True})
        check(not r["isError"] and 'mode = "top_down"' in open(os.path.join(
            project, "mixar", "levels", "TopLevel.tscn")).read(), "new_scene top_down", r)
        lines = client.call("log", {"errors_only": True, "max_lines": 500})["structuredContent"]["lines"]
        unicode = [l["text"] for l in lines if "Unicode parsing error" in l["text"]]
        check(not unicode, "the link's own replies log no Unicode errors", unicode[:2])
    finally:
        proc.terminate()
        try:
            proc.wait(10)
        except subprocess.TimeoutExpired:
            proc.kill()
        log.close()
    try:
        plugin_mode_checks(args.godot, tmp)
    finally:
        if FAILURES or args.keep:
            print(f"temp folder kept: {tmp} (editor log: {log_path})")
        else:
            shutil.rmtree(tmp, ignore_errors=True)
    print(f"\n{'FAILED' if FAILURES else 'OK'}: {len(FAILURES)} failure(s)")
    return 1 if FAILURES else 0


if __name__ == "__main__":
    sys.exit(main())
