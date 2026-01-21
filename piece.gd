extends Sprite2D

var type: String
var color: String
var board_position: Vector2i
var has_moved: bool = false # Required for Castling

func setup(p_type: String, p_color: String, p_coords: Vector2i):
	type = p_type
	color = p_color
	board_position = p_coords
	
	# Load texture based on type and color
	# Example: res://assets/white_queen.png
	var texture_path = "res://art/" + color + "_" + type + ".svg"
	texture = load(texture_path)
