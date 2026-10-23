extends CanvasLayer
## Collected count (top left) and the win banner.

var _count: Label
var _banner: Label


func _ready() -> void:
	_count = Label.new()
	_count.position = Vector2(24, 16)
	_count.add_theme_font_size_override("font_size", 28)
	add_child(_count)
	_banner = Label.new()
	_banner.set_anchors_preset(Control.PRESET_CENTER)
	_banner.add_theme_font_size_override("font_size", 56)
	_banner.text = "You win!"
	_banner.visible = false
	add_child(_banner)
	var game = get_tree().get_first_node_in_group("mixar_game")
	if game:
		game.changed.connect(_refresh.bind(game))
		_refresh(game)


func _refresh(game) -> void:
	_count.text = "Collected %d / %d" % [game.collected, game.total] if game.total else ""
	_banner.text = "Game over" if game.lost else "You win!"
	_banner.visible = game.won or game.lost
