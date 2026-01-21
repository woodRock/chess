extends Node3D

# --- Configuration ---
@export_group("Grid Settings")
@export var square_size: float = 0.042 
@export var board_offset: Vector3 = Vector3(-0.15, 0.002, -0.15) 
@export var model_folder: String = "res://art/" 

@export_group("Camera Settings")
@export var rotation_speed: float = 2.0
@export var camera_height: float = 0.35   
@export var camera_distance: float = 0.35 

@export_group("Zoom Settings")
@export var zoom_speed: float = 0.5
@export var min_zoom: float = 0.05    
@export var max_zoom: float = 0.8      

@export_group("Graveyard Settings")
@export var graveyard_spacing: float = 0.025
@export var graveyard_scale: float = 0.65

@export_group("Visuals")
@export var selection_lift: float = 0.01 
@export var dot_color: Color = Color(0, 1, 0, 0.6)

# --- Logic Variables ---
var pieces_data: Dictionary = {} 
var selected_position: Vector2i = Vector2i(-1, -1)
var current_turn: String = "white"
var legal_moves: Array[Vector2i] = []
var ai_thinking: bool = false 
var promotion_active: bool = false 
var white_captured: Array[Node3D] = []
var black_captured: Array[Node3D] = []
var moved_pieces: Array[Node3D] = []
var pending_promotion: Dictionary = {}

# --- Node References ---
var pieces_container: Node3D
var dots_container: Node3D
var promotion_container: Node3D 
var camera_pivot: Node3D
var white_anchor: Node3D
var black_anchor: Node3D
var camera: Camera3D
var check_light: OmniLight3D
var game_over_ui: Node 
var result_label: Label

# --- INITIALIZATION ---

func _ready() -> void:
	setup_node_references()
	setup_improved_lighting()
	setup_camera_position()
	setup_pieces_3d()
	generate_collision_for_board()
	
	await get_tree().process_frame
	find_ui_elements()

func _ensure_node(node_name: String, default_pos: Vector3 = Vector3.ZERO) -> Node3D:
	var n = get_node_or_null(node_name)
	if not n:
		n = Node3D.new()
		n.name = node_name
		add_child(n)
		n.position = default_pos
	return n

func setup_node_references():
	pieces_container = _ensure_node("Pieces")
	dots_container = _ensure_node("Dots")
	promotion_container = _ensure_node("PromotionUI")
	camera_pivot = _ensure_node("CameraPivot")
	white_anchor = _ensure_node("GraveyardWhite", Vector3(-0.25, 0, -0.1))
	black_anchor = _ensure_node("GraveyardBlack", Vector3(0.25, 0, -0.1))

	camera = camera_pivot.get_node_or_null("Camera3D")
	if not camera:
		camera = get_node_or_null("Camera3D")
		if camera:
			camera.get_parent().remove_child(camera)
			camera_pivot.add_child(camera)
		else:
			camera = Camera3D.new(); camera.name = "Camera3D"
			camera_pivot.add_child(camera)
	
	camera.make_current()
	camera.near = 0.001 
	
	# FIXED: Bulletproof CheckLight Initialization
	check_light = get_node_or_null("CheckLight")
	if not check_light:
		check_light = OmniLight3D.new()
		check_light.name = "CheckLight"
		add_child(check_light)
	
	# Now it is safe to assign properties
	check_light.light_color = Color.RED
	check_light.light_energy = 3.0
	check_light.omni_range = 0.08
	check_light.visible = false

func find_ui_elements():
	game_over_ui = get_tree().root.find_child("GameOverUI", true, false)
	result_label = get_tree().root.find_child("ResultLabel", true, false)
	var restart_btn = get_tree().root.find_child("RestartButton", true, false)
	if restart_btn:
		if not restart_btn.pressed.is_connected(_on_restart_button_pressed):
			restart_btn.pressed.connect(_on_restart_button_pressed)

func setup_improved_lighting():
	var world_env = get_node_or_null("WorldEnv")
	if not world_env:
		var env_node = WorldEnvironment.new(); env_node.name = "WorldEnv"
		var env_res = Environment.new()
		env_res.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		env_res.ambient_light_color = Color(0.45, 0.45, 0.5)
		env_res.ambient_light_energy = 1.0
		env_res.tonemap_mode = Environment.TONE_MAPPER_ACES
		env_node.environment = env_res
		add_child(env_node)

	if not has_node("Sun"):
		var sun = DirectionalLight3D.new(); sun.name = "Sun"
		sun.position = Vector3(1, 2, 1); sun.rotation_degrees = Vector3(-60, 45, 0)
		sun.shadow_enabled = true; sun.shadow_bias = 0.02
		add_child(sun)

func setup_camera_position():
	camera_pivot.global_position = Vector3.ZERO
	camera.position = Vector3(0, camera_height, camera_distance)
	camera.look_at(Vector3.ZERO, Vector3.UP)

# --- CAMERA MOVEMENT & ZOOM ---

func handle_camera_movement(delta: float) -> void:
	if Input.is_action_pressed("ui_right"): camera_pivot.rotation.y -= rotation_speed * delta
	if Input.is_action_pressed("ui_left"): camera_pivot.rotation.y += rotation_speed * delta
	if Input.is_action_pressed("ui_up"): zoom_camera(-zoom_speed * delta)
	if Input.is_action_pressed("ui_down"): zoom_camera(zoom_speed * delta)

func zoom_camera(amount: float):
	camera.position.z = clamp(camera.position.z + amount, min_zoom, max_zoom)
	camera.position.y = clamp(camera.position.y + (amount * 1.5), min_zoom, max_zoom)
	camera.look_at(camera_pivot.global_position, Vector3.UP)

# --- CORE LOGIC ---

func is_legal_move(from: Vector2i, to: Vector2i) -> bool:
	if from == to: return false
	var piece = pieces_data.get(from)
	if piece == null or not is_basic_move_valid(from, to): return false
	
	var captured = pieces_data.get(to)
	pieces_data[to] = piece; pieces_data.erase(from)
	var color = "white" if piece.name.to_lower().contains("white") else "black"
	var king_pos = find_king(color)
	if piece.name.to_lower().contains("king"): king_pos = to
	var is_safe = not is_square_attacked(king_pos, get_enemy_color(color))
	
	pieces_data[from] = piece
	if captured: pieces_data[to] = captured
	else: pieces_data.erase(to)
	return is_safe

func is_basic_move_valid(from: Vector2i, to: Vector2i) -> bool:
	var piece = pieces_data.get(from)
	var target = pieces_data.get(to)
	var p_name = piece.name.to_lower()
	var color = "white" if p_name.contains("white") else "black"
	if target != null and target.name.to_lower().contains(color): return false
	var diff = to - from
	if p_name.contains("knight"): return abs(diff.x * diff.y) == 2
	elif p_name.contains("rook"): return (from.x == to.x or from.y == to.y) and is_path_clear(from, to)
	elif p_name.contains("bishop"): return abs(diff.x) == abs(diff.y) and is_path_clear(from, to)
	elif p_name.contains("queen"): return (abs(diff.x) == abs(diff.y) or from.x == to.x or from.y == to.y) and is_path_clear(from, to)
	elif p_name.contains("king"): return abs(diff.x) <= 1 and abs(diff.y) <= 1
	elif p_name.contains("pawn"): return is_valid_pawn_move(from, to, color == "white")
	return false

func is_square_attacked(target: Vector2i, attacker_color: String) -> bool:
	for coords in pieces_data:
		var p = pieces_data[coords]
		if p != null and p.name.to_lower().contains(attacker_color):
			if p.name.to_lower().contains("pawn"):
				var dir = -1 if attacker_color == "white" else 1
				if abs(target.x - coords.x) == 1 and (target.y - coords.y) == dir: return true
			elif is_basic_move_valid(coords, target): return true
	return false

func is_path_clear(from: Vector2i, to: Vector2i) -> bool:
	var step = Vector2i(clamp(to.x - from.x, -1, 1), clamp(to.y - from.y, -1, 1))
	var curr = from + step
	while curr != to:
		if pieces_data.has(curr): return false
		curr += step
	return true

func is_valid_pawn_move(from: Vector2i, to: Vector2i, is_white: bool) -> bool:
	var dir = -1 if is_white else 1
	var diff = to - from
	if diff.x == 0 and diff.y == dir: return not pieces_data.has(to)
	if from.y == (6 if is_white else 1) and diff.x == 0 and diff.y == dir * 2:
		return not pieces_data.has(from + Vector2i(0, dir)) and not pieces_data.has(to)
	if abs(diff.x) == 1 and diff.y == dir: return pieces_data.has(to)
	return false

# --- EXECUTION & GRAVEYARD ---

func execute_move_3d(from: Vector2i, to: Vector2i):
	var piece = pieces_data[from]
	var p_name = piece.name.to_lower()
	if pieces_data.has(to):
		send_to_graveyard(pieces_data[to])
	pieces_data[to] = piece; pieces_data.erase(from)
	if not piece in moved_pieces: moved_pieces.append(piece)
	var target_3d = Vector3(to.x * square_size, 0.0, to.y * square_size) + board_offset
	create_tween().tween_property(piece, "position", target_3d, 0.3).set_trans(Tween.TRANS_SINE)
	if p_name.contains("pawn") and (to.y == 0 or to.y == 7):
		pending_promotion = {"piece": piece, "to": to}
		show_promotion_menu(p_name.contains("white"))
	else:
		finalize_turn()

func send_to_graveyard(piece: Node3D):
	var is_white = piece.name.to_lower().contains("white")
	var tray = white_captured if is_white else black_captured
	var anchor = white_anchor if is_white else black_anchor
	var count = tray.size()
	var row = count % 8
	var col = floor(count / 8.0)
	var local_pos = Vector3(col * graveyard_spacing, 0, row * graveyard_spacing)
	var target_global_pos = anchor.global_position + local_pos
	var tween = create_tween().set_parallel(true)
	tween.tween_property(piece, "global_position", target_global_pos, 0.5).set_trans(Tween.TRANS_QUART)
	tween.tween_property(piece, "scale", Vector3(graveyard_scale, graveyard_scale, graveyard_scale), 0.5)
	for child in piece.find_children("*", "CollisionObject3D", true):
		child.input_ray_pickable = false
	tray.append(piece)

# --- INPUT HANDLING ---

func _process(delta: float) -> void:
	if promotion_active or ai_thinking: return 
	handle_camera_movement(delta)
	if current_turn == "black":
		ai_thinking = true
		await get_tree().create_timer(1.0).timeout
		make_ai_move()

func _input(event):
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP: zoom_camera(-zoom_speed * 0.1)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN: zoom_camera(zoom_speed * 0.1)
		
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if get_viewport().gui_get_focus_owner(): return
		var ray_origin = camera.project_ray_origin(event.position)
		var ray_dir = camera.project_ray_normal(event.position)
		var query = PhysicsRayQueryParameters3D.create(ray_origin, ray_origin + ray_dir * 1000)
		var res = get_world_3d().direct_space_state.intersect_ray(query)
		
		if res:
			var hit = res.collider as Node3D
			if promotion_active:
				var promo = find_promotion_parent(hit)
				if promo: handle_promotion_selection(promo)
			else:
				var local = res.position - global_position - board_offset
				var gx = round(local.x / square_size); var gz = round(local.z / square_size)
				if gx >= 0 and gx <= 7 and gz >= 0 and gz <= 7: handle_piece_selection(Vector2i(int(gx), int(gz)))

func handle_piece_selection(pos: Vector2i):
	if pieces_data.has(pos) and pieces_data[pos].name.to_lower().contains(current_turn):
		deselect_piece(); selected_position = pos
		for y in 8:
			for x in 8:
				if is_legal_move(pos, Vector2i(x,y)): legal_moves.append(Vector2i(x,y))
		show_dots(legal_moves)
		create_tween().tween_property(pieces_data[pos], "position:y", selection_lift, 0.1)
	elif selected_position != Vector2i(-1, -1) and pos in legal_moves:
		execute_move_3d(selected_position, pos); deselect_piece()
	else:
		deselect_piece()

# --- SETUP UTILS ---

func generate_collision_for_board():
	var found_mesh = false
	for child in get_children():
		if child is MeshInstance3D:
			child.create_trimesh_collision()
			found_mesh = true
	
	if not found_mesh:
		var static_body = StaticBody3D.new()
		var col = CollisionShape3D.new()
		var box = BoxShape3D.new()
		box.size = Vector3(square_size * 8, 0.01, square_size * 8)
		col.shape = box
		static_body.add_child(col)
		add_child(static_body)
		static_body.position = Vector3(square_size * 3.5, -0.005, square_size * 3.5) + board_offset

func setup_pieces_3d():
	for child in pieces_container.get_children(): child.queue_free()
	pieces_data.clear(); white_captured.clear(); black_captured.clear(); moved_pieces.clear()
	var layout = ["rook", "knight", "bishop", "queen", "king", "bishop", "knight", "rook"]
	for i in 8:
		spawn_piece_3d(Vector2i(i, 0), "black_" + layout[i])
		spawn_piece_3d(Vector2i(i, 1), "black_pawn")
		spawn_piece_3d(Vector2i(i, 6), "white_pawn")
		spawn_piece_3d(Vector2i(i, 7), "white_" + layout[i])

func spawn_piece_3d(coords: Vector2i, p_name: String):
	var p = load(model_folder + p_name + ".glb").instantiate()
	pieces_container.add_child(p)
	p.position = Vector3(coords.x * square_size, 0, coords.y * square_size) + board_offset
	p.name = p_name
	if p_name.begins_with("black"): p.rotation_degrees.y = 180
	pieces_data[coords] = p
	for m in p.find_children("*", "MeshInstance3D", true): m.create_trimesh_collision()

func show_dots(moves):
	clear_dots()
	for m in moves:
		var dot = MeshInstance3D.new(); dot.mesh = SphereMesh.new(); dot.mesh.radius = 0.005; dot.mesh.height = 0.01
		var mat = StandardMaterial3D.new(); mat.albedo_color = dot_color; mat.transparency = StandardMaterial3D.TRANSPARENCY_ALPHA
		dot.material_override = mat; dots_container.add_child(dot); dot.position = Vector3(m.x * square_size, 0.005, m.y * square_size) + board_offset

func clear_dots(): for child in dots_container.get_children(): child.queue_free()
func deselect_piece():
	if selected_position != Vector2i(-1, -1) and pieces_data.has(selected_position):
		create_tween().tween_property(pieces_data[selected_position], "position:y", 0.0, 0.1)
	selected_position = Vector2i(-1, -1); legal_moves = []; clear_dots()
func find_king(color):
	for k in pieces_data:
		if pieces_data[k].name.to_lower().contains("king") and pieces_data[k].name.to_lower().contains(color): return k
	return Vector2i(-1,-1)
func get_enemy_color(c): return "black" if c == "white" else "white"
func _on_restart_button_pressed(): get_tree().reload_current_scene()

func check_game_state():
	var king_pos = find_king(current_turn)
	if king_pos == Vector2i(-1, -1): return
	var in_check = is_square_attacked(king_pos, get_enemy_color(current_turn))
	check_light.visible = in_check
	if in_check: check_light.global_position = pieces_data[king_pos].global_position + Vector3(0, 0.02, 0)
	var has_legal = false
	for c in pieces_data.keys():
		if pieces_data[c].name.to_lower().contains(current_turn):
			for y in 8:
				for x in 8:
					if is_legal_move(c, Vector2i(x,y)): has_legal = true; break
				if has_legal: break
		if has_legal: break
	if not has_legal: show_game_over(in_check, get_enemy_color(current_turn))

func make_ai_move():
	var moves = []
	for p in pieces_data.keys():
		if pieces_data[p].name.to_lower().contains("black"):
			for y in 8:
				for x in 8:
					if is_legal_move(p, Vector2i(x,y)): moves.append({"f": p, "t": Vector2i(x,y)})
	if moves.size() > 0:
		var m = moves.pick_random(); execute_move_3d(m.f, m.t)
	else: finalize_turn()

func finalize_turn():
	current_turn = get_enemy_color(current_turn); ai_thinking = false; check_game_state()

func show_game_over(mate, winner):
	if game_over_ui: game_over_ui.show()
	if result_label: result_label.text = ("CHECKMATE! " if mate else "STALEMATE! ") + winner.to_upper() + " WINS!"

func show_promotion_menu(is_white):
	promotion_active = true
	var options = ["queen", "rook", "bishop", "knight"]
	promotion_container.global_transform = camera.global_transform
	promotion_container.translate_object_local(Vector3(0, 0, -0.15))
	for i in options.size():
		var p = load(model_folder + ("white_" if is_white else "black_") + options[i] + ".glb").instantiate()
		promotion_container.add_child(p)
		p.position = Vector3((i - 1.5) * 0.04, -0.02, 0); p.name = "PROMOTE_" + options[i]
		for m in p.find_children("*", "MeshInstance3D", true): m.create_trimesh_collision()

func find_promotion_parent(n):
	var c = n
	while c:
		if c.name.begins_with("PROMOTE_"): return c
		c = c.get_parent()
	return null

func handle_promotion_selection(n):
	var type = n.name.replace("PROMOTE_", "")
	pending_promotion.piece.queue_free()
	spawn_piece_3d(pending_promotion.to, ("white_" if current_turn == "white" else "black_") + type)
	for c in promotion_container.get_children(): c.queue_free()
	promotion_active = false; finalize_turn()
