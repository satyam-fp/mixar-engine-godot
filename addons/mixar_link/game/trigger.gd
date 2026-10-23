extends Node3D
## mixar_role "trigger": a volume the player walks into; the game manager
## decides what it means.

const C := preload("res://addons/mixar_link/game/component.gd")


func _ready() -> void:
	add_to_group("mixar_trigger")
	C.drop_static_bodies(self)
	C.add_area(self, 0.1).body_entered.connect(_on_body)


func _on_body(body: Node) -> void:
	if C.is_player(body):
		C.notify(self, "trigger")
