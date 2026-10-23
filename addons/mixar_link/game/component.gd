extends RefCounted
## Shared helpers for the Mixar game components (the scripts the import
## plugin attaches by mixar_role). Runtime-only: no editor API here, so an
## exported game compiles it.


## Blender frame (Z up, metres) → Godot, and back.
static func to_godot(p: Array) -> Vector3:
	var v := [0.0, 0.0, 0.0]
	for i in mini(3, p.size()):
		v[i] = float(p[i])
	return Vector3(v[0], v[2], -v[1])


static func to_blender(v: Vector3) -> Array:
	return [snappedf(v.x, 0.001), snappedf(-v.z, 0.001), snappedf(v.y, 0.001)]


## The node's meshes' bounds in its own space (a unit box when it has none).
static func local_aabb(node: Node3D) -> AABB:
	var box := AABB()
	var found := false
	var inverse := node.global_transform.affine_inverse()
	var meshes: Array = [node] + node.find_children("*", "MeshInstance3D", true, false)
	for n in meshes:
		if n is MeshInstance3D and n.mesh != null:
			var b: AABB = (inverse * n.global_transform) * n.get_aabb()
			box = b if not found else box.merge(b)
			found = true
	return box if found else AABB(Vector3(-0.5, -0.5, -0.5), Vector3.ONE)


## A trigger volume around the node's meshes, `grow` metres larger each side.
static func add_area(node: Node3D, grow := 0.1) -> Area3D:
	var aabb := local_aabb(node).grow(grow)
	var area := Area3D.new()
	area.name = "MixarArea"
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = aabb.size
	shape.shape = box
	shape.position = aabb.get_center()
	area.add_child(shape)
	node.add_child(area)
	return area


## Pickups, triggers and markers are walked through, not into: drop the
## collision hulls the package carried for them.
static func drop_static_bodies(node: Node) -> void:
	for child in node.get_children():
		if child is StaticBody3D:
			child.queue_free()


static func is_player(body: Node) -> bool:
	return body != null and body.is_in_group("mixar_player")


## Tell the game manager (group "mixar_game") what happened; without one,
## nothing listens and nothing breaks.
static func notify(node: Node, event: String) -> void:
	if node.is_inside_tree():
		node.get_tree().call_group("mixar_game", "on_mixar_event", event, node)


## A Blender-frame axis name's Godot axis: x → X, y → -Z, z → Y.
static func axis(name: String) -> Vector3:
	match name:
		"x": return Vector3.RIGHT
		"y": return Vector3.FORWARD
	return Vector3.UP
