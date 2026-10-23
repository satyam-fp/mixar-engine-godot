extends Node3D
## mixar_role "door": opens when the game calls open() (by default once every
## pickup is collected). mixar_pivot hinge_* swings it 90° about that Blender
## axis through its origin; slide_* moves it its own length along the axis.

const C := preload("res://addons/mixar_link/game/component.gd")
const SECONDS := 1.2

var is_open := false


func _ready() -> void:
	add_to_group("mixar_door")


func open() -> void:
	if is_open:
		return
	is_open = true
	var pivot := String(get_meta("mixar_pivot", "hinge_z"))
	var kind := pivot.get_slice("_", 0)
	var ax := C.axis(pivot.get_slice("_", 1))
	var tween := create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	if kind == "slide":
		var extent := absf((C.local_aabb(self).size * ax).dot(Vector3.ONE))
		tween.tween_property(self, "position", position + basis * ax * extent, SECONDS)
	else:
		tween.tween_property(self, "quaternion", quaternion * Quaternion(ax.abs(), PI / 2.0 * signf(ax.dot(Vector3.ONE))), SECONDS)
	C.notify(self, "door_open")
