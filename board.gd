extends Node2D

@export var square_scene: PackedScene = preload("res://square.tscn")
@export var piece_scene: PackedScene = preload("res://piece.tscn")

var square_size: int = 64
var all_squares: Dictionary = {}
var pieces_data: Dictionary = {}
var selected_position: Vector2i = Vector2i(-1, -1)
var is_piece_selected: bool = false
var current_turn: String = "white"
var is_ai_thinking: bool = false

# UI Variables
var pending_promotion_coords: Vector2i = Vector2i(-1, -1)
@onready var promotion_ui = get_node_or_null("PromotionMenu")
@onready var game_over_ui = get_node_or_null("GameOverUI")
@onready var result_label = get_node_or_null("GameOverUI/VBoxContainer/ResultLabel")
@onready var black_graveyard = get_node_or_null("BlackGraveyard")
@onready var white_graveyard = get_node_or_null("WhiteGraveyard")

func _ready() -> void:
	if promotion_ui: promotion_ui.hide()
	if game_over_ui: game_over_ui.hide()
	generate_board()
	center_board_on_screen()
	await get_tree().process_frame 
	setup_pieces()

# --- INITIALIZATION ---

func generate_board():
	for y in 8:
		for x in 8:
			var s = square_scene.instantiate()
			add_child(s)
			s.position = Vector2(x * square_size, y * square_size)
			s.z_index = 0
			s.set_square_color((x + y) % 2 == 0)
			all_squares[Vector2i(x,y)] = s

func center_board_on_screen():
	var total_board_size = square_size * 8
	var screen_size = get_viewport_rect().size
	self.position = (screen_size / 2.0) - (Vector2(total_board_size, total_board_size) / 2.0)
	if black_graveyard: black_graveyard.position = Vector2(0, -square_size - 20)
	if white_graveyard: white_graveyard.position = Vector2(0, total_board_size + 20)

func setup_pieces():
	var layout = ["rook", "knight", "bishop", "queen", "king", "bishop", "knight", "rook"]
	for i in 8:
		place_piece(Vector2i(i,0), layout[i], "black")
		place_piece(Vector2i(i,1), "pawn", "black")
		place_piece(Vector2i(i,6), "pawn", "white")
		place_piece(Vector2i(i,7), layout[i], "white")

func place_piece(coords, type, color):
	var p = piece_scene.instantiate()
	add_child(p)
	p.z_index = 1
	p.setup(type, color, coords)
	p.position = Vector2(coords * square_size) + Vector2(32, 32)
	pieces_data[coords] = p

# --- INPUT & MOVEMENT ---

func _input(event: InputEvent) -> void:
	if is_ai_thinking or (promotion_ui and promotion_ui.visible) or (game_over_ui and game_over_ui.visible): return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var clicked_grid_pos = get_grid_position(get_global_mouse_position())
		if clicked_grid_pos.x < 0 or clicked_grid_pos.x > 7 or clicked_grid_pos.y < 0 or clicked_grid_pos.y > 7:
			deselect_everything()
			return 
		get_viewport().set_input_as_handled()
		if not is_piece_selected: handle_selection(clicked_grid_pos)
		else: handle_movement(clicked_grid_pos)

func get_grid_position(mouse_position: Vector2) -> Vector2i:
	var local_pos = to_local(mouse_position)
	return Vector2i(floor(local_pos.x / square_size), floor(local_pos.y / square_size))

func handle_movement(target_position: Vector2i) -> void:
	if target_position == selected_position:
		deselect_everything()
		return

	var current_piece = pieces_data.get(selected_position)
	var clicked_piece = pieces_data.get(target_position)

	# 1. SPECIAL CASE: Castling Input (Clicking the Rook while King is selected)
	if current_piece.type == "king" and clicked_piece != null and clicked_piece.type == "rook" and clicked_piece.color == current_piece.color:
		# Calculate where the king would land based on which rook was clicked
		var target_x = 6 if target_position.x > selected_position.x else 2
		var king_target = Vector2i(target_x, selected_position.y)
		if is_valid_castle(selected_position, king_target, current_piece.color):
			execute_castle(selected_position, king_target)
			deselect_everything()
			return

	# 2. Standard Selection Switch
	if clicked_piece != null and current_piece.color == clicked_piece.color:
		all_squares[selected_position].set_highlight(false)
		handle_selection(target_position)
		return 

	# 3. Standard Move Execution
	if is_legal_move(selected_position, target_position):
		execute_move(selected_position, target_position)
	elif current_piece.type == "king" and is_valid_castle(selected_position, target_position, current_piece.color):
		# Handles clicking the empty destination square for castle
		execute_castle(selected_position, target_position)
	
	deselect_everything()

func execute_move(from: Vector2i, to: Vector2i) -> void:
	var piece = pieces_data[from]
	if pieces_data.has(to) and pieces_data[to] != null: 
		var captured = pieces_data[to]
		add_to_graveyard(captured.type, captured.color)
		captured.queue_free()
	
	pieces_data[to] = piece  
	pieces_data.erase(from)
	piece.board_position = to 
	piece.has_moved = true
	
	create_tween().tween_property(piece, "position", Vector2(to * square_size) + Vector2(32, 32), 0.2)
	
	var promotion_rank = 0 if piece.color == "white" else 7
	if piece.type == "pawn" and to.y == promotion_rank:
		pending_promotion_coords = to
		spawn_promotion_menu(to, piece.color)
		return
	finalize_turn()

# --- CASTLING & PROMOTION UI ---



func is_valid_castle(from: Vector2i, to: Vector2i, color: String) -> bool:
	if from.y != to.y or abs(to.x - from.x) != 2: return false
	var king = pieces_data.get(from)
	if king == null or king.has_moved or is_square_attacked(from, get_enemy_color(color)): return false
	var is_kingside = to.x > from.x
	var rook_x = 7 if is_kingside else 0
	var rook = pieces_data.get(Vector2i(rook_x, from.y))
	if rook == null or rook.type != "rook" or rook.has_moved: return false
	var step = 1 if is_kingside else -1
	for i in range(1, 3):
		var check_pos = Vector2i(from.x + (i * step), from.y)
		if pieces_data.get(check_pos) != null or is_square_attacked(check_pos, get_enemy_color(color)): return false
	return true

func execute_castle(king_from: Vector2i, king_to: Vector2i):
	var king = pieces_data[king_from]
	var is_kingside = king_to.x > king_from.x
	var rook_from = Vector2i(7 if is_kingside else 0, king_from.y)
	var rook_to = Vector2i(king_to.x - 1 if is_kingside else king_to.x + 1, king_from.y)
	var rook = pieces_data[rook_from]
	_reposition_piece(king, king_from, king_to)
	_reposition_piece(rook, rook_from, rook_to)
	finalize_turn()

func _reposition_piece(p, f, t):
	pieces_data[t] = p
	pieces_data.erase(f)
	p.board_position = t
	p.has_moved = true
	create_tween().tween_property(p, "position", Vector2(t * square_size) + Vector2(32, 32), 0.2)

func spawn_promotion_menu(coords: Vector2i, color: String):
	if promotion_ui:
		var target_square = all_squares[coords]
		promotion_ui.global_position = target_square.global_position
		promotion_ui.global_position.y -= square_size if color == "white" else -square_size
		var types = ["queen", "rook", "knight", "bishop"]
		var container = promotion_ui.get_node_or_null("HBoxContainer")
		if container:
			for i in range(container.get_child_count()):
				var btn = container.get_child(i) as Button
				btn.icon = load("res://art/" + color + "_" + types[i] + ".png")
				btn.mouse_filter = Control.MOUSE_FILTER_STOP
		promotion_ui.show()
		promotion_ui.z_index = 100

func _on_promotion_selected(new_type: String):
	if pending_promotion_coords != Vector2i(-1, -1):
		var old_pawn = pieces_data.get(pending_promotion_coords)
		if old_pawn:
			var p_color = old_pawn.color
			old_pawn.queue_free()
			place_piece(pending_promotion_coords, new_type, p_color)
		pending_promotion_coords = Vector2i(-1, -1)
		if promotion_ui: promotion_ui.hide()
		finalize_turn()

# --- VALIDATION ENGINE ---

func is_legal_move(from: Vector2i, to: Vector2i) -> bool:
	var piece = pieces_data.get(from)
	if piece == null or not is_basic_move_valid(from, to): return false
	var captured = pieces_data.get(to)
	pieces_data[to] = piece
	pieces_data.erase(from)
	var king_pos = to if piece.type == "king" else find_king(piece.color)
	var is_safe = not is_square_attacked(king_pos, get_enemy_color(piece.color))
	pieces_data[from] = piece
	if captured: pieces_data[to] = captured
	else: pieces_data.erase(to)
	return is_safe

func is_square_attacked(target: Vector2i, attacker_color: String) -> bool:
	for coords in pieces_data:
		var p = pieces_data[coords]
		if p != null and p.color == attacker_color:
			if p.type == "pawn":
				var dir = -1 if p.color == "white" else 1
				if abs(target.x - coords.x) == 1 and (target.y - coords.y) == dir: return true
			elif is_basic_move_valid(coords, target): return true
	return false

func is_basic_move_valid(from: Vector2i, to: Vector2i) -> bool:
	var piece = pieces_data.get(from)
	var target = pieces_data.get(to)
	if target != null and target.color == piece.color: return false
	match piece.type:
		"knight": return (to - from).abs().x * (to - from).abs().y == 2
		"rook": return (from.x == to.x or from.y == to.y) and is_path_clear(from, to)
		"bishop": return (to - from).abs().x == (to - from).abs().y and is_path_clear(from, to)
		"queen": return (from.x == to.x or from.y == to.y or (to - from).abs().x == (to - from).abs().y) and is_path_clear(from, to)
		"king": return (to - from).abs().x <= 1 and (to - from).abs().y <= 1
		"pawn": return is_valid_pawn_move(from, to, piece.color)
	return false

func is_path_clear(from: Vector2i, to: Vector2i) -> bool:
	var step = Vector2i(clamp(to.x - from.x, -1, 1), clamp(to.y - from.y, -1, 1))
	var curr = from + step
	while curr != to:
		if pieces_data.get(curr) != null: return false
		curr += step
	return true

func is_valid_pawn_move(from, to, color):
	var dir = -1 if color == "white" else 1
	var diff = to - from
	if diff.x == 0 and diff.y == dir: return pieces_data.get(to) == null
	if from.y == (6 if color == "white" else 1) and diff.x == 0 and diff.y == dir * 2:
		return pieces_data.get(from + Vector2i(0, dir)) == null and pieces_data.get(to) == null
	if abs(diff.x) == 1 and diff.y == dir: return pieces_data.get(to) != null
	return false

# --- GAME STATE ---

func finalize_turn():
	current_turn = get_enemy_color(current_turn)
	check_game_state()

func check_game_state():
	var has_legal = false
	for c in pieces_data.keys():
		var p = pieces_data[c]
		if p != null and p.color == current_turn:
			for y in 8:
				for x in 8:
					if is_legal_move(c, Vector2i(x,y)): has_legal = true; break
				if has_legal: break
		if has_legal: break
	if not has_legal:
		var enemy = get_enemy_color(current_turn)
		if is_square_attacked(find_king(current_turn), enemy): show_game_over(enemy.to_upper() + " WINS!")
		else: show_game_over("STALEMATE!")
		is_ai_thinking = true
	elif current_turn == "black": start_ai_turn()

func start_ai_turn():
	is_ai_thinking = true
	await get_tree().create_timer(0.5).timeout
	var moves = []
	for c in pieces_data.keys():
		var p = pieces_data[c]
		if p != null and p.color == "black":
			for y in 8:
				for x in 8:
					if is_legal_move(c, Vector2i(x,y)): moves.append({"f":c, "t":Vector2i(x,y)})
	if moves.size() > 0:
		var m = moves[randi() % moves.size()]
		execute_move(m.f, m.t)
	is_ai_thinking = false

# --- UTILS & SIGNALS ---

func add_to_graveyard(type, color):
	var icon = TextureRect.new()
	icon.texture = load("res://art/" + color + "_" + type + ".png")
	icon.expand_mode = TextureRect.EXPAND_KEEP_SIZE
	icon.custom_minimum_size = Vector2(32, 32)
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if color == "white": black_graveyard.add_child(icon)
	else: white_graveyard.add_child(icon)

func show_game_over(text):
	if result_label: result_label.text = text
	game_over_ui.show()

func _on_restart_button_pressed(): get_tree().reload_current_scene()
func get_enemy_color(c): return "black" if c == "white" else "white"
func find_king(c):
	for k in pieces_data:
		if pieces_data[k].type == "king" and pieces_data[k].color == c: return k
	return Vector2i(-1,-1)

func handle_selection(pos):
	if pieces_data.has(pos) and pieces_data[pos].color == current_turn:
		selected_position = pos; is_piece_selected = true
		all_squares[pos].set_highlight(true)

func deselect_everything():
	if is_piece_selected and all_squares.has(selected_position): all_squares[selected_position].set_highlight(false)
	is_piece_selected = false; selected_position = Vector2i(-1,-1)

func _on_queen_pressed(): _on_promotion_selected("queen")
func _on_rook_pressed(): _on_promotion_selected("rook")
func _on_knight_pressed(): _on_promotion_selected("knight")
func _on_bishop_pressed(): _on_promotion_selected("bishop")
