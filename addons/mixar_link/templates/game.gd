extends Node
## The game manager (group "mixar_game"): counts pickups, opens doors when all
## are collected, respawns the player after a hazard or a fall, and wins at a
## goal once the doors are open. Mixar's playtests read get_state().
##
## Custom scripts talk to it with
##   get_tree().call_group("mixar_game", "on_mixar_event", "<event>", self)
## (pickup, hazard, checkpoint, goal, lose, restart) and report their own
## values by joining group "mixar_state" with a mixar_state() method.

signal changed

const FALL_Y := -25.0

var total := 0
var collected := 0
var deaths := 0
var won := false
var lost := false
var doors_open := false
var player: CharacterBody3D
var _respawn := Vector3(0, 1, 0)


func _ready() -> void:
	add_to_group("mixar_game")
	_start.call_deferred()


func _start() -> void:
	player = get_tree().get_first_node_in_group("mixar_player")
	total = get_tree().get_nodes_in_group("mixar_pickup").size()
	var spawn = get_tree().get_first_node_in_group("mixar_spawn")
	if spawn:
		_respawn = spawn.global_position + Vector3(0, 0.1, 0)
	elif player:
		_respawn = player.global_position
	if player:
		var model = get_tree().get_first_node_in_group("mixar_player_model")
		if model and model != player:
			player.wear(model)
		player.respawn(_respawn)
	if total == 0:
		_open_doors()
	print("[Mixar Game] started: %d pickup(s)" % total)
	changed.emit()


func _physics_process(_delta: float) -> void:
	if player and not won and player.global_position.y < FALL_Y:
		on_mixar_event("hazard", self)


func on_mixar_event(event: String, node: Node) -> void:
	match event:
		"pickup":
			collected += 1
			if collected >= total:
				_open_doors()
		"hazard":
			deaths += 1
			if player:
				player.respawn(_respawn)
		"checkpoint":
			_respawn = (node as Node3D).global_position + Vector3(0, 0.1, 0)
		"goal":
			if doors_open and not won and not lost:
				won = true
				print("[Mixar Game] won")
		"lose":  # a custom script's fail state (a timer ran out, a boss won)
			if not won and not lost:
				lost = true
				print("[Mixar Game] lost")
		"restart":
			get_tree().reload_current_scene.call_deferred()
	changed.emit()


func _open_doors() -> void:
	doors_open = true
	get_tree().call_group("mixar_door", "open")


func get_state() -> Dictionary:
	var state := {"collected": collected, "total": total, "won": won, "lost": lost, "deaths": deaths,
		"doors_open": doors_open}
	# Custom gameplay reports its own values: any node in group "mixar_state"
	# with a mixar_state() -> Dictionary method (a timer's time_left, a score).
	for node in get_tree().get_nodes_in_group("mixar_state"):
		if node.has_method("mixar_state"):
			state.merge(node.mixar_state(), true)
	if player:
		var p := player.global_position
		state["player_position"] = [snappedf(p.x, 0.01), snappedf(-p.z, 0.01), snappedf(p.y, 0.01)]
		state["on_floor"] = player.is_on_floor()
	return state
