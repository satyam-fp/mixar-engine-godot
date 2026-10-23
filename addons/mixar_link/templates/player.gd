extends CharacterBody3D
## The templates' player, in one of three modes:
## - "third_person": WASD / arrows move relative to the camera, Q / E turn it.
## - "top_down": the camera looks down from above; WASD / arrows move north /
##   south / west / east (Blender +Y / -Y / -X / +X).
## - "platformer": a side view; A / D or left / right run along Blender X, the
##   player stays in its lane (its starting Blender Y). The camera looks from
##   Blender -Y (Blender's front view).
## Space jumps in every mode. Builds its own capsule, collision and camera when
## the scene gives it none. A node tagged mixar_role "player" in the level
## becomes its look (the game manager hands it over).
##
## `autopilot` (a Godot-space point, or null) steers it there; Mixar's
## playtests use it to check what is reachable.

@export var mode := "third_person"

const SPEED := 5.0
const JUMP_VELOCITY := 5.5
const PLATFORMER_JUMP_VELOCITY := 7.0
const CAMERA_TURN := 2.5

var autopilot = null
var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
var _camera_yaw := 0.0
var _lane_z := 0.0
var _arm: SpringArm3D


func _ready() -> void:
	add_to_group("mixar_player")
	if get_node_or_null("Collision") == null:
		var col := CollisionShape3D.new()
		col.name = "Collision"
		var capsule := CapsuleShape3D.new()
		capsule.radius = 0.35
		capsule.height = 1.8
		col.shape = capsule
		col.position.y = 0.9
		add_child(col)
	if get_node_or_null("Body") == null:
		var body := MeshInstance3D.new()
		body.name = "Body"
		var mesh := CapsuleMesh.new()
		mesh.radius = 0.35
		mesh.height = 1.8
		body.mesh = mesh
		body.position.y = 0.9
		add_child(body)
	_arm = SpringArm3D.new()
	_arm.name = "CameraArm"
	_arm.top_level = true
	_arm.spring_length = {"top_down": 14.0, "platformer": 12.0}.get(mode, 4.5)
	_arm.add_excluded_object(get_rid())
	add_child(_arm)
	var cam := Camera3D.new()
	cam.name = "Camera"
	cam.current = true
	_arm.add_child(cam)
	_lane_z = global_position.z
	_follow()


func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= gravity * delta
	if mode == "third_person":
		_camera_yaw += Input.get_axis("camera_right", "camera_left") * CAMERA_TURN * delta
	var dir := Vector3.ZERO
	if autopilot != null:
		var to: Vector3 = autopilot - global_position
		to.y = 0.0
		if mode == "platformer":
			to.z = 0.0
		if to.length() > 0.1:
			dir = to.normalized()
	elif mode == "platformer":
		dir = Vector3(Input.get_axis("move_left", "move_right"), 0, 0)
	else:
		var input := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
		dir = (Basis(Vector3.UP, _camera_yaw) * Vector3(input.x, 0, input.y)).normalized()
	velocity.x = dir.x * SPEED
	velocity.z = dir.z * SPEED
	if dir.length() > 0.01:
		rotation.y = lerp_angle(rotation.y, atan2(-dir.x, -dir.z), 10.0 * delta)
	if Input.is_action_just_pressed("jump"):
		jump()
	move_and_slide()
	if mode == "platformer":
		global_position.z = _lane_z
		velocity.z = 0.0
	_follow()


func _follow() -> void:
	_arm.global_position = global_position + Vector3(0, 1.6 if mode != "platformer" else 1.2, 0)
	match mode:
		"top_down": _arm.rotation = Vector3(deg_to_rad(-60.0), 0, 0)
		"platformer": _arm.rotation = Vector3(deg_to_rad(-8.0), 0, 0)
		_: _arm.rotation = Vector3(deg_to_rad(-18.0), _camera_yaw, 0)


func jump() -> void:
	if is_on_floor():
		velocity.y = PLATFORMER_JUMP_VELOCITY if mode == "platformer" else JUMP_VELOCITY


## How far the player still is from `target` in the plane it moves in.
func distance_to_target(target: Vector3) -> float:
	var to := target - global_position
	return absf(to.x) if mode == "platformer" else Vector2(to.x, to.z).length()


## Whether playtests should route by the navigation mesh (a side view runs and
## jumps along one line instead).
func uses_navigation() -> bool:
	return mode != "platformer"


func respawn(at: Vector3) -> void:
	global_position = at
	velocity = Vector3.ZERO
	_lane_z = at.z


## Use `model` (a tagged mesh from the level) as the player's look.
func wear(model: Node3D) -> void:
	var body := get_node_or_null("Body")
	if body:
		body.visible = false
	# A Mixar engine package keeps the model's own origin (its feet).
	model.reparent(self, false)
	model.position = Vector3.ZERO
	model.rotation = Vector3.ZERO
	for child in model.get_children():
		if child is StaticBody3D:
			child.queue_free()
