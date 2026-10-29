@tool
extends RefCounted
## Humanoid retargeting for imported characters. A rig whose bone names match a
## known convention (Tripo's auto-rig, Mixamo) is imported with a BoneMap onto
## Godot's SkeletonProfileHumanoid: its bones take the profile's names
## (Hips, LeftUpperArm, …) and its skeleton becomes the unique node
## %GeneralSkeleton, so a clip made on ANY mapped humanoid plays on any other
## (track paths read "%GeneralSkeleton:LeftUpperArm"). Twist, share and facial
## helper bones keep their own names and are left to the skin.

const MAP_DIR := "res://mixar/retarget"

const FINGERS := ["Thumb", "Index", "Middle", "Ring", "Little"]
const FINGER_JOINTS := {"Thumb": ["Metacarpal", "Proximal", "Distal"],
	"Index": ["Proximal", "Intermediate", "Distal"], "Middle": ["Proximal", "Intermediate", "Distal"],
	"Ring": ["Proximal", "Intermediate", "Distal"], "Little": ["Proximal", "Intermediate", "Distal"]}

# Godot humanoid profile bone -> Tripo auto-rig (v3.0, 78 bones) bone.
const TRIPO_BODY := {
	"Root": "BoneRoot", "Hips": "Hip", "Spine": "Waist", "Chest": "Spine01", "UpperChest": "Spine02",
	"Neck": "NeckTwist01", "Head": "Head", "LeftEye": "L_Eye", "RightEye": "R_Eye",
	"LeftShoulder": "L_Clavicle", "LeftUpperArm": "L_Upperarm", "LeftLowerArm": "L_Forearm", "LeftHand": "L_Hand",
	"RightShoulder": "R_Clavicle", "RightUpperArm": "R_Upperarm", "RightLowerArm": "R_Forearm", "RightHand": "R_Hand",
	"LeftUpperLeg": "L_Thigh", "LeftLowerLeg": "L_Calf", "LeftFoot": "L_Foot", "LeftToes": "L_ToeBase",
	"RightUpperLeg": "R_Thigh", "RightLowerLeg": "R_Calf", "RightFoot": "R_Foot", "RightToes": "R_ToeBase",
}
const TRIPO_FINGERS := {"Thumb": "Thumb", "Index": "Index", "Middle": "Mid", "Ring": "Ring", "Little": "Pinky"}

# Godot humanoid profile bone -> Mixamo bone (after its prefix, e.g. "mixamorig_").
const MIXAMO_BODY := {
	"Hips": "Hips", "Spine": "Spine", "Chest": "Spine1", "UpperChest": "Spine2", "Neck": "Neck",
	"Head": "Head", "LeftEye": "LeftEye", "RightEye": "RightEye",
	"LeftShoulder": "LeftShoulder", "LeftUpperArm": "LeftArm", "LeftLowerArm": "LeftForeArm", "LeftHand": "LeftHand",
	"RightShoulder": "RightShoulder", "RightUpperArm": "RightArm", "RightLowerArm": "RightForeArm", "RightHand": "RightHand",
	"LeftUpperLeg": "LeftUpLeg", "LeftLowerLeg": "LeftLeg", "LeftFoot": "LeftFoot", "LeftToes": "LeftToeBase",
	"RightUpperLeg": "RightUpLeg", "RightLowerLeg": "RightLeg", "RightFoot": "RightFoot", "RightToes": "RightToeBase",
}
const MIXAMO_FINGERS := {"Thumb": "Thumb", "Index": "Index", "Middle": "Middle", "Ring": "Ring", "Little": "Pinky"}


## Which convention the skeleton's bones follow: {"naming", "prefix"} or {}.
static func detect(skeleton: Skeleton3D) -> Dictionary:
	var names := {}
	for i in skeleton.get_bone_count():
		names[skeleton.get_bone_name(i)] = true
	if names.has("Hips") and names.has("LeftUpperArm"):
		return {}  # already on the humanoid profile
	if ["BoneRoot", "Hip", "L_Upperarm", "R_Forearm", "L_Thigh"].all(func(n): return names.has(n)):
		return {"naming": "tripo", "prefix": ""}
	for name in names:
		var m := RegEx.create_from_string("^(mixamorig\\d*[_:])Hips$").search(String(name))
		if m:
			var prefix := m.get_string(1)
			if names.has(prefix + "LeftArm") and names.has(prefix + "RightUpLeg"):
				return {"naming": "mixamo", "prefix": prefix}
	return {}


## Profile bone -> this skeleton's bone, only the bones the skeleton has.
static func mapping(naming: String, prefix: String, skeleton: Skeleton3D) -> Dictionary:
	var body: Dictionary = TRIPO_BODY if naming == "tripo" else MIXAMO_BODY
	var out := {}
	for profile_bone in body:
		out[profile_bone] = prefix + body[profile_bone]
	for side in ["Left", "Right"]:
		for finger in FINGERS:
			for n in 3:
				var src: String
				if naming == "tripo":
					src = "%s_%s%d" % [side.left(1), TRIPO_FINGERS[finger], n + 1]
				else:
					src = "%s%sHand%s%d" % [prefix, side, MIXAMO_FINGERS[finger], n + 1]
				out[side + finger + FINGER_JOINTS[finger][n]] = src
	for profile_bone in out.keys():
		if skeleton.find_bone(out[profile_bone]) < 0:
			out.erase(profile_bone)
	return out


## Point the importer of ``res_path`` (an imported glb/gltf) at a humanoid
## BoneMap for every recognised skeleton in it. Returns {"naming", "skeletons",
## "mapped"} when the import options changed (the caller reimports), else {}.
static func configure(res_path: String) -> Dictionary:
	if not ResourceLoader.exists(res_path):
		return {}
	var packed = load(res_path)
	if not packed is PackedScene:
		return {}
	var scene: Node = packed.instantiate()
	var nodes := {}
	var found := {}
	for skeleton in scene.find_children("*", "Skeleton3D", true, false):
		var hit := detect(skeleton)
		if hit.is_empty():
			continue
		var bones := mapping(hit.naming, hit.prefix, skeleton)
		var bone_map := BoneMap.new()
		bone_map.profile = SkeletonProfileHumanoid.new()
		for profile_bone in bones:
			bone_map.set_skeleton_bone_name(profile_bone, bones[profile_bone])
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(MAP_DIR))
		var map_path := MAP_DIR.path_join("%s_%s.tres" % [res_path.get_file().get_basename(), skeleton.name])
		if ResourceSaver.save(bone_map, map_path) != OK:
			continue
		nodes["PATH:" + String(scene.get_path_to(skeleton))] = {
			"retarget/bone_map": load(map_path),
		}
		found = {"naming": hit.naming, "mapped": bones.size()}
	scene.free()
	if nodes.is_empty():
		return {}
	var cfg := ConfigFile.new()
	if cfg.load(res_path + ".import") != OK:
		return {}
	var subresources = cfg.get_value("params", "_subresources", {})
	if typeof(subresources) != TYPE_DICTIONARY:
		subresources = {}
	var existing: Dictionary = subresources.get("nodes", {})
	for key in nodes:
		existing[key] = nodes[key]
	subresources["nodes"] = existing
	cfg.set_value("params", "_subresources", subresources)
	if cfg.save(res_path + ".import") != OK:
		return {}
	found["skeletons"] = nodes.size()
	return found
