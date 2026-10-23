extends Node3D
## mixar_role "spawn": where the player starts (and respawns until a
## checkpoint is reached). Invisible in the game.

const C := preload("res://addons/mixar_link/game/component.gd")


func _ready() -> void:
	add_to_group("mixar_spawn")
	C.drop_static_bodies(self)
	visible = false
