extends ColorRect

var board_pos: Vector2i
var square_size: int = 64
@onready var highlight = $Highlight

func set_square_color(is_light: bool):
	if is_light:
		color = Color("#ebecd0")
	else:
		color = Color("#779556")
		
func set_highlight(is_visible: bool):
	highlight.visible = is_visible
	
# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	size = Vector2(square_size + 1, square_size)

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	pass
