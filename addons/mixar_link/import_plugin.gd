@tool
extends EditorScenePostImportPlugin
## Turns a Mixar package's game tags into Godot behaviour at import time.
## Packages exported with engine="godot" carry the mixar_* tags as glTF extras,
## which Godot imports as each node's "extras" metadata. Every tagged node gets
## its tags as metadata (mixar_role, mixar_pivot, …), persistent groups
## (mixar_tagged, mixar_<role>, mixar_nav_<nav>, mixar_body_<body>), and the
## component script for its role. Untagged scenes are left alone.

const DIR := "res://addons/mixar_link/game/"
const ROLE_SCRIPTS := {
	"pickup": "pickup.gd", "door": "door.gd", "hazard": "hazard.gd", "enemy": "hazard.gd",
	"goal": "goal.gd", "checkpoint": "checkpoint.gd", "trigger": "trigger.gd", "spawn": "spawn.gd",
}


func _post_process(scene: Node) -> void:
	for node in [scene] + scene.find_children("*", "", true, false):
		if not node.has_meta("extras"):
			continue
		var extras = node.get_meta("extras")
		if typeof(extras) != TYPE_DICTIONARY:
			continue
		var tags := {}
		for key in extras:
			if String(key).begins_with("mixar_"):
				tags[String(key)] = String(extras[key])
		if tags.is_empty():
			continue
		for key in tags:
			node.set_meta(key, tags[key])
		node.add_to_group("mixar_tagged", true)
		var role := String(tags.get("mixar_role", ""))
		if role != "":
			node.add_to_group("mixar_" + role, true)
		if role == "player":
			node.add_to_group("mixar_player_model", true)
		if tags.has("mixar_nav"):
			node.add_to_group("mixar_nav_" + tags.mixar_nav, true)
		if tags.has("mixar_body"):
			node.add_to_group("mixar_body_" + tags.mixar_body, true)
		if ROLE_SCRIPTS.has(role) and node is Node3D:
			node.set_script(load(DIR + ROLE_SCRIPTS[role]))
