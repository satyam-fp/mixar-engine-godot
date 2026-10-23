extends CharacterBody3D
## Third-person player: WASD / arrows move relative to the camera, Space
## jumps, Q / E turn the camera. Builds its own capsule, collision and camera
## when the scene gives it none. A node tagged mixar_role "player" in the
## level becomes its look (the game manager hands it over).
##
## `autopilot` (a Godot-space point, or null) steers it straight there; Mixar's
## playtests use it to check what is reachable.

const SPEED := 5.0
const JUMP_VELOCITY := 5.5
const CAMERA_TURN := 2.5

var autopilot = null
var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
var _camera_yaw := 0.0
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
	_arm.spring_length = 4.5
	_arm.add_excluded_object(get_rid())
	add_child(_arm)
	var cam := Camera3D.new()
	cam.name = "Camera"
	cam.current = true
	_arm.add_child(cam)
	_follow()


func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= gravity * delta
	_camera_yaw += Input.get_axis("camera_right", "camera_left") * CAMERA_TURN * delta
	var dir := Vector3.ZERO
	if autopilot != null:
		var to: Vector3 = autopilot - global_position
		to.y = 0.0
		if to.length() > 0.1:
			dir = to.normalized()
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
	_follow()


func _follow() -> void:
	_arm.global_position = global_position + Vector3(0, 1.6, 0)
	_arm.rotation = Vector3(deg_to_rad(-18.0), _camera_yaw, 0)


func jump() -> void:
	if is_on_floor():
		velocity.y = JUMP_VELOCITY


func respawn(at: Vector3) -> void:
	global_position = at
	velocity = Vector3.ZERO


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
