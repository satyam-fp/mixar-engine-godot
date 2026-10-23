# Mixar Link for Godot

A Godot 4.5+ editor add-on that lets the [Mixar](https://mixar.app) agent work in
your Godot project. It imports Mixar export packages, places them in a level, runs
the game, and reads back frames and log lines. It runs a small
[MCP](https://modelcontextprotocol.io) server inside the editor, reachable only from
your own machine.

## Install

1. Copy `addons/mixar_link` into your project's `addons/` folder.
2. Open **Project → Project Settings → Plugins** and enable **Mixar Link**.
3. Keep the project open in the editor. The Mixar desktop app finds it on its own.

Enabling the add-on also registers a `MixarLink` autoload, the first in the list.
In a game started from the editor it forwards log lines and answers frame requests.
In an exported build it does nothing.

## How Mixar connects

On start the add-on listens on the first free port between `127.0.0.1:9890` and
`127.0.0.1:9899`. It writes `~/.mixar/engine-link/godot-<pid>.json` (port and a
random token, readable only by you) and deletes the file when the editor closes.

Every request must have:

- `Authorization: Bearer <token>`;
- a loopback `Host`;
- no `Origin` header, so a web page cannot drive your editor.

Transport is MCP Streamable HTTP (`POST /mcp`, JSON responses, `Mcp-Session-Id`
after `initialize`).

## Tools

| Tool | Does |
| --- | --- |
| `status` | Engine, project, open scene, main scene, whether the game runs |
| `import_package` | Copies a Mixar package folder into `res://mixar/<folder>/` (skipping `.blend` sources) and waits for the import |
| `new_scene` | Creates `res://mixar/levels/<name>.tscn` (sun, sky, camera by default), opens it, optionally sets it as the main scene |
| `open_scene` | Opens a scene |
| `place` | Instances an imported scene at a position and yaw, with undo, then saves |
| `scene_tree` | The open scene's own nodes: path, type, position |
| `save_scene` | Saves the open scene |
| `play` / `stop` | Runs the game from the editor and waits for it to connect; stops it |
| `capture` | A JPEG frame of the running game, or of the editor's 3D viewport |
| `log` | Editor and game log lines after a sequence number; `errors_only` filters |
| `playtest` | Scripted steps in the running game (`hold`/`press` an input action, `wait`, `walk_to` a point, `prove_loop`, `state`) with the game state after each. `walk_to` follows a navigation mesh baked from the level's colliders at that moment (`no_path` when nothing connects); `prove_loop` visits every pickup nearest-first, then the goal, and reports `won` and what it could not reach |
| `write_script` | Writes a GDScript under `res://mixar/scripts/`, compiled first (a script that fails is not written) |
| `add_node` / `set_property` | Adds a built-in node (optionally scripted) / sets a property, with undo, then saves |
| `build_web` | Exports a no-threads web build into `res://mixar_build/web/` (needs Godot's export templates) |
| `build_info` | The last web build's files and folder, for the Mixar desktop to upload a share |

`new_scene` takes a `template` that wraps the level in a game: a player, a game
manager, a HUD and the input map. Space jumps in all three:

| Template | Player |
| --- | --- |
| `third_person` | WASD / arrows relative to the camera; Q / E turn it |
| `top_down` | A camera high above; WASD / arrows move north/south/west/east |
| `platformer` | A side view (from Blender -Y): A / D run along Blender X, the player keeps its lane |

## Studio projects (plugin mode)

In an existing project, set this in `project.godot` (Project Settings, advanced):

```ini
[mixar_link]
project_mode="plugin"
editable_scenes=PackedStringArray("res://levels/shared.tscn")
```

In plugin mode Mixar keeps to `res://mixar/`. It never changes project settings
(main scene, input map, export presets), and it edits only levels under
`res://mixar/` or listed in `editable_scenes`. Everything else is refused with a
message saying what the studio can do instead. The agent cannot change the mode.
Enabling the add-on still registers its `MixarLink` autoload. The default,
`"owned"`, is for games Mixar builds from scratch.

## Game tags

Packages exported with `engine="godot"` carry `mixar_*` tags as glTF extras. On
import, the add-on gives each tagged node its tags as metadata, groups
(`mixar_<role>`, …) and a component script (`addons/mixar_link/game/`):

| Role | In the game |
| --- | --- |
| `pickup` | Spins; collected on touch |
| `door` | Opens (hinge or slide, `mixar_pivot`) once every pickup is collected |
| `goal` | Wins once the doors are open |
| `hazard` / `enemy` | Respawns the player; patrols with a `slide_*` pivot |
| `checkpoint` | Moves the respawn point |
| `spawn` | The player's start |
| `trigger` | Tells the game manager (`on_mixar_event`) |

Positions use Blender's frame (Z up, metres), the frame Mixar works in. Blender
`(x, y, z)` is Godot `(x, z, -y)`, and a yaw about Blender Z is the same angle about
Godot Y.

Packages exported with `engine="godot"` carry collision as Godot import hints
(`-convcolonly` / `-colonly`) and game tags (`mixar_role`, `mixar_body`, …) as glTF
extras. Godot reads the extras as node metadata.

## Test

```sh
python3 test/run_e2e.py --godot /path/to/Godot            # headless editor and game (75 checks: plays levels to a win, plugin mode)
python3 test/run_e2e.py --godot /path/to/Godot --windowed-game   # also checks a real frame
```

## License

MIT
