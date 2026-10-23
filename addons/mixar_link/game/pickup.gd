extends Node3D
## mixar_role "pickup": spins in place; the player collects it by touching it.

const C := preload("res://addons/mixar_link/game/component.gd")

var collected := false


func _ready() -> void:
	add_to_group("mixar_pickup")
	C.drop_static_bodies(self)
	C.add_area(self, 0.3).body_entered.connect(_on_body)


func _process(delta: float) -> void:
	rotate_y(delta * 1.5)


func _on_body(body: Node) -> void:
	if collected or not C.is_player(body):
		return
	collected = true
	C.notify(self, "pickup")
	queue_free()
