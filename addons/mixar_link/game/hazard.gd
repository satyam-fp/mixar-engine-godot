extends Node3D
## mixar_role "hazard" / "enemy": touching it costs the player a life (the
## game respawns them). With mixar_pivot slide_* it patrols back and forth
## PATROL_M metres along that Blender axis.

const C := preload("res://addons/mixar_link/game/component.gd")
const PATROL_M := 4.0
const SPEED := 1.5

var _start: Vector3
var _dir := Vector3.ZERO
var _t := 0.0


func _ready() -> void:
	add_to_group("mixar_hazard")
	C.add_area(self, 0.15).body_entered.connect(_on_body)
	var pivot := String(get_meta("mixar_pivot", ""))
	if pivot.begins_with("slide_"):
		_dir = C.axis(pivot.get_slice("_", 1))
	_start = position


func _physics_process(delta: float) -> void:
	if _dir == Vector3.ZERO:
		return
	_t += delta * SPEED / PATROL_M
	position = _start + _dir * PATROL_M * (0.5 - 0.5 * cos(_t * PI))


func _on_body(body: Node) -> void:
	if C.is_player(body):
		C.notify(self, "hazard")
