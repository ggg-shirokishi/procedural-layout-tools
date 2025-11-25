extends Node

# ============================================
# RuntimeLayoutKeyboardController.gd
# --------------------------------------------
# ・ゲーム実行中にキーボード入力でダンジョンレイアウトを再生成するコントローラ。
# ・役割は「レイアウトノードの seed をランダムに更新する」こと。
#   → 実際の生成処理は RoomLayoutGenerator.gd 側の
#      seed セッター内で行う前提。
#
# 【前提条件】
# - layout_node_path には RoomLayoutGenerator.gd を付けた Node2D を指定。
# - RoomLayoutGenerator.gd には、seed セッターで generate_now() を呼ぶ実装がある。
# - layout_node 側には以下のプロパティがある前提：
#   width, height, room_count,
#   room_w_min, room_w_max, room_h_min, room_h_max,
#   corridor_width, corridor_width_min, corridor_width_max
#
# 【このスクリプトの挙動】
# - 指定アクション（例: Rキー）を押すたびに:
#   1) 必要なら幅/高さ/部屋数/部屋サイズ/通路幅を範囲からランダムに決め直す
#   2) seed をランダムに変更 → RoomLayoutGenerator が再生成
# - 再生成成功後:
#   - 指定 Node2D を「未使用セル」に移動（フロア or 壁近傍フロア）
#   - 指定 ZoomCamera2D/Camera2D の limit_* をレイアウトの外枠に合わせる
# ============================================

const CELL_WALL: int = 0
const CELL_FLOOR: int = 1

enum MoveTargetKind {
	MOVE_ON_FLOORS,
	MOVE_NEAR_WALLS
}

@export var layout_node_path: NodePath
@export var input_action_name: String = "dungeon_regen"
@export var log_enabled: bool = true

# ===== レイアウトパラメータのランダム化設定 =====

# 再生成ごとにレイアウト全体の幅・高さをランダムにするか
@export var randomize_layout_size: bool = false
# width のランダム範囲 (min, max)
@export var layout_width_range: Vector2i = Vector2i(80, 80)
# height のランダム範囲 (min, max)
@export var layout_height_range: Vector2i = Vector2i(60, 60)

# 再生成ごとに部屋数をランダムにするか
@export var randomize_room_count: bool = false
# room_count のランダム範囲 (min, max)
@export var room_count_range: Vector2i = Vector2i(18, 18)

# 再生成ごとに部屋サイズ（room_w_min/max, room_h_min/max）をランダムにするか
@export var randomize_room_size: bool = false
# 「部屋の幅」が取りうる範囲（ここから2つ引いて min/max に割り当てる）
@export var room_width_range: Vector2i = Vector2i(5, 14)
# 「部屋の高さ」が取りうる範囲
@export var room_height_range: Vector2i = Vector2i(4, 12)

# 再生成ごとに通路幅をランダムにするか
@export var randomize_corridor_width: bool = false
# 通路幅として取りうる範囲（ここから2つ引いて min/max にし、固定幅もこの中から）
@export var corridor_width_range: Vector2i = Vector2i(0, 3)

# ===== レイアウト更新後に移動させる対象の設定 =====

@export var move_target_node_path: NodePath
@export var move_target_tilemap_layer_path: NodePath
@export var move_target_kind: MoveTargetKind = MoveTargetKind.MOVE_ON_FLOORS
@export var move_after_generation: bool = true

# レイアウトグリッド 1 セルのピクセルサイズ
@export var cell_size: Vector2 = Vector2(16.0, 16.0)

# ===== カメラ制限の自動調整設定 =====
# 再生成後に limit_* をレイアウトの外枠に合わせたい ZoomCamera2D / Camera2D
@export var zoom_camera_path: NodePath

var layout_node: Node = null
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()

func _ready() -> void:
	if Engine.is_editor_hint():
		return

	if layout_node_path != NodePath(""):
		layout_node = get_node_or_null(layout_node_path)
	else:
		layout_node = null

	if not is_instance_valid(layout_node):
		push_error("RuntimeLayoutKeyboardController: layout_node_path が未設定か、ノードが見つからない。")
		return

	_rng.randomize()

	if not InputMap.has_action(input_action_name):
		push_warning(
			"RuntimeLayoutKeyboardController: InputMap にアクション \"" +
			input_action_name +
			"\" がありません。Project Settings > Input Map で設定してください。"
		)

	if layout_node.has_signal("generation_finished"):
		if not layout_node.is_connected("generation_finished", Callable(self, "_on_layout_generation_finished")):
			layout_node.connect("generation_finished", Callable(self, "_on_layout_generation_finished"))
	else:
		if log_enabled:
			print("RuntimeLayoutKeyboardController: layout_node に generation_finished シグナルが無い。")

	if log_enabled:
		print(
			"RuntimeLayoutKeyboardController: ready. layout_node=",
			layout_node.name,
			" action=",
			input_action_name
		)

func _process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return
	if not is_instance_valid(layout_node):
		return

	if Input.is_action_just_pressed(input_action_name):
		_regenerate_with_random_seed()

# ===== ランダムパラメータ適用 =====

func _sorted_range(range: Vector2i) -> Vector2i:
	if range.y < range.x:
		return Vector2i(range.y, range.x)
	return range

func _apply_random_layout_parameters() -> void:
	if not is_instance_valid(layout_node):
		return

	# ---- 全体サイズ ----
	if randomize_layout_size:
		var wr: Vector2i = _sorted_range(layout_width_range)
		var hr: Vector2i = _sorted_range(layout_height_range)
		var w_new: int = max(1, _rng.randi_range(wr.x, wr.y))
		var h_new: int = max(1, _rng.randi_range(hr.x, hr.y))
		layout_node.set("width", w_new)
		layout_node.set("height", h_new)

	# ---- 部屋数 ----
	if randomize_room_count:
		var rr: Vector2i = _sorted_range(room_count_range)
		var rc_new: int = max(1, _rng.randi_range(rr.x, rr.y))
		layout_node.set("room_count", rc_new)

	# ---- 部屋サイズ（幅・高さ）----
	if randomize_room_size:
		var wr2: Vector2i = _sorted_range(room_width_range)
		var hr2: Vector2i = _sorted_range(room_height_range)

		var w_a: int = max(1, _rng.randi_range(wr2.x, wr2.y))
		var w_b: int = max(1, _rng.randi_range(wr2.x, wr2.y))
		var h_a: int = max(1, _rng.randi_range(hr2.x, hr2.y))
		var h_b: int = max(1, _rng.randi_range(hr2.x, hr2.y))

		var room_w_min_new: int = min(w_a, w_b)
		var room_w_max_new: int = max(w_a, w_b)
		var room_h_min_new: int = min(h_a, h_b)
		var room_h_max_new: int = max(h_a, h_b)

		layout_node.set("room_w_min", room_w_min_new)
		layout_node.set("room_w_max", room_w_max_new)
		layout_node.set("room_h_min", room_h_min_new)
		layout_node.set("room_h_max", room_h_max_new)

	# ---- 通路幅 ----
	if randomize_corridor_width:
		var cr: Vector2i = _sorted_range(corridor_width_range)
		var c_a: int = max(0, _rng.randi_range(cr.x, cr.y))
		var c_b: int = max(0, _rng.randi_range(cr.x, cr.y))

		var cw_min_new: int = min(c_a, c_b)
		var cw_max_new: int = max(c_a, c_b)

		layout_node.set("corridor_width_min", cw_min_new)
		layout_node.set("corridor_width_max", cw_max_new)

		var fixed_width: int = _rng.randi_range(cw_min_new, cw_max_new)
		layout_node.set("corridor_width", fixed_width)

	if log_enabled:
		print("RuntimeLayoutKeyboardController: random layout params applied.")

# ===== seed を変えて再生成 =====

func _regenerate_with_random_seed() -> void:
	if not is_instance_valid(layout_node):
		push_error("RuntimeLayoutKeyboardController: layout_node が無効。")
		return

	# 先にレイアウトパラメータを振ってから seed を変える
	_apply_random_layout_parameters()

	var old_seed_any = layout_node.get("seed")
	if typeof(old_seed_any) == TYPE_NIL:
		push_error(
			"RuntimeLayoutKeyboardController: layout_node に \"seed\" プロパティが無い。" +
			"RoomLayoutGenerator.gd が付いているか確認。"
		)
		return

	var old_seed: int = int(old_seed_any)
	var new_seed: int = old_seed
	var safety: int = 0
	while new_seed == old_seed and safety < 8:
		new_seed = int(_rng.randi())
		safety += 1

	layout_node.set("seed", new_seed)

	if log_enabled:
		print(
			"RuntimeLayoutKeyboardController: regenerate. old_seed=",
			str(old_seed),
			" new_seed=",
			str(new_seed),
			" node=",
			layout_node.name
		)

# ===== レイアウト更新後コールバック =====

func _on_layout_generation_finished(success: bool) -> void:
	if Engine.is_editor_hint():
		return

	if not success:
		if log_enabled:
			print("RuntimeLayoutKeyboardController: layout generation failed. move/camera skipped.")
		return

	_update_zoom_camera_limits()

	if not move_after_generation:
		if log_enabled:
			print("RuntimeLayoutKeyboardController: move_after_generation=false なので移動しない。")
		return

	_move_target_to_free_cell()

# ===== グリッド値取得ヘルパー =====

func _get_grid_value(grid: Array, x: int, y: int) -> int:
	var h: int = grid.size()
	if h <= 0:
		return CELL_WALL
	if y < 0 or y >= h:
		return CELL_WALL
	var row_any: Variant = grid[y]
	if not (row_any is Array):
		return CELL_WALL
	var row: Array = row_any
	var w: int = row.size()
	if x < 0 or x >= w:
		return CELL_WALL
	var v_any: Variant = row[x]
	if not (v_any is int):
		return CELL_WALL
	return int(v_any)

# ===== 「壁に隣接したフロア」の未使用セル抽出 =====

func _filter_free_cells_near_walls(free_floor_cells: Array, grid: Array) -> Array:
	var result: Array = []
	var i: int = 0
	while i < free_floor_cells.size():
		var cell_any: Variant = free_floor_cells[i]
		if cell_any is Vector2i:
			var c: Vector2i = cell_any
			var gx: int = c.x
			var gy: int = c.y

			var val_up: int = _get_grid_value(grid, gx, gy - 1)
			var val_down: int = _get_grid_value(grid, gx, gy + 1)
			var val_left: int = _get_grid_value(grid, gx - 1, gy)
			var val_right: int = _get_grid_value(grid, gx + 1, gy)

			var is_near_wall: bool = false
			if val_up == CELL_WALL:
				is_near_wall = true
			elif val_down == CELL_WALL:
				is_near_wall = true
			elif val_left == CELL_WALL:
				is_near_wall = true
			elif val_right == CELL_WALL:
				is_near_wall = true

			if is_near_wall:
				result.append(c)
		i += 1
	return result

# ===== 生成前位置からの基準セル計算 =====

func _get_reference_cell_from_previous_position(target_2d: Node2D) -> Dictionary:
	var result: Dictionary = {}
	result["valid"] = false
	result["cell"] = Vector2i(0, 0)

	if target_2d == null:
		return result

	var old_global_pos: Vector2 = target_2d.global_position

	if move_target_tilemap_layer_path != NodePath(""):
		var layer_any: Variant = get_node_or_null(move_target_tilemap_layer_path)
		if layer_any is TileMapLayer:
			var layer: TileMapLayer = layer_any
			var local_in_layer: Vector2 = layer.to_local(old_global_pos)
			var ref_cell_layer: Vector2i = layer.local_to_map(local_in_layer)
			result["valid"] = true
			result["cell"] = ref_cell_layer
			return result

	if is_instance_valid(layout_node) and layout_node is Node2D:
		var layout_2d: Node2D = layout_node
		var local_in_layout: Vector2 = layout_2d.to_local(old_global_pos)

		var sx: float = cell_size.x
		var sy: float = cell_size.y
		if sx <= 0.0:
			sx = 1.0
		if sy <= 0.0:
			sy = 1.0

		var cx: int = int(floor(local_in_layout.x / sx))
		var cy: int = int(floor(local_in_layout.y / sy))

		result["valid"] = true
		result["cell"] = Vector2i(cx, cy)
		return result

	return result

# ===== 未使用セルへの移動 =====

func _move_target_to_free_cell() -> void:
	if move_target_node_path == NodePath(""):
		if log_enabled:
			print("RuntimeLayoutKeyboardController: move_target_node_path が空。移動しない。")
		return

	var target_node: Node = get_node_or_null(move_target_node_path)
	if not is_instance_valid(target_node):
		push_warning("RuntimeLayoutKeyboardController: move_target_node が見つからない。")
		return

	if not (target_node is Node2D):
		push_warning("RuntimeLayoutKeyboardController: move_target_node が Node2D ではない。")
		return

	var target_2d: Node2D = target_node

	if not is_instance_valid(layout_node):
		push_error("RuntimeLayoutKeyboardController: layout_node が無効。")
		return

	if not layout_node.has_method("get_free_cells"):
		push_error("RuntimeLayoutKeyboardController: layout_node に get_free_cells(kind:int) が無い。")
		return

	var grid: Array = []
	if layout_node.has_method("get_grid_copy"):
		var grid_any: Variant = layout_node.call("get_grid_copy")
		if grid_any is Array:
			grid = grid_any

	var free_floor_cells_any: Variant = layout_node.call("get_free_cells", CELL_FLOOR)
	if not (free_floor_cells_any is Array):
		push_error("RuntimeLayoutKeyboardController: get_free_cells(CELL_FLOOR) が Array を返さない。")
		return

	var free_floor_cells: Array = free_floor_cells_any
	if free_floor_cells.is_empty():
		if log_enabled:
			print("RuntimeLayoutKeyboardController: フロア未使用セルが存在しない。")
		return

	var candidate_cells: Array = []

	if move_target_kind == MoveTargetKind.MOVE_ON_FLOORS:
		candidate_cells = free_floor_cells.duplicate()
	else:
		if grid.is_empty():
			if log_enabled:
				print("RuntimeLayoutKeyboardController: grid が無いのでフロア全体から選択。")
			candidate_cells = free_floor_cells.duplicate()
		else:
			var near_wall_cells: Array = _filter_free_cells_near_walls(free_floor_cells, grid)
			if near_wall_cells.is_empty():
				if log_enabled:
					print("RuntimeLayoutKeyboardController: 壁近傍の未使用セルが無いのでフロア全体から選択。")
				candidate_cells = free_floor_cells.duplicate()
			else:
				candidate_cells = near_wall_cells

	if candidate_cells.is_empty():
		if log_enabled:
			print("RuntimeLayoutKeyboardController: 候補セルが空。")
		return

	var ref_info: Dictionary = _get_reference_cell_from_previous_position(target_2d)
	var reference_valid: bool = bool(ref_info.get("valid", false))
	var reference_cell: Vector2i = Vector2i(0, 0)
	if reference_valid:
		var rc_any: Variant = ref_info.get("cell", Vector2i(0, 0))
		if rc_any is Vector2i:
			reference_cell = rc_any
		else:
			reference_valid = false

	var index: int = 0
	if reference_valid:
		var best_index: int = 0
		var best_dist2: float = -1.0
		var i: int = 0
		while i < candidate_cells.size():
			var cell_any2: Variant = candidate_cells[i]
			if cell_any2 is Vector2i:
				var c2: Vector2i = cell_any2
				var dx: float = float(c2.x - reference_cell.x)
				var dy: float = float(c2.y - reference_cell.y)
				var d2: float = dx * dx + dy * dy
				if best_dist2 < 0.0 or d2 < best_dist2:
					best_dist2 = d2
					best_index = i
			i += 1
		index = best_index
	else:
		if candidate_cells.size() > 1:
			index = int(_rng.randi() % candidate_cells.size())

	var cell_any: Variant = candidate_cells[index]
	if not (cell_any is Vector2i):
		push_error("RuntimeLayoutKeyboardController: candidate_cells の要素が Vector2i ではない。")
		return

	var cell: Vector2i = cell_any
	var global_pos: Vector2

	if move_target_tilemap_layer_path != NodePath(""):
		var layer_any2: Variant = get_node_or_null(move_target_tilemap_layer_path)
		if layer_any2 is TileMapLayer:
			var layer2: TileMapLayer = layer_any2
			var layer_local_pos: Vector2 = layer2.map_to_local(cell)
			global_pos = layer2.to_global(layer_local_pos)
		else:
			if not (layout_node is Node2D):
				push_error("RuntimeLayoutKeyboardController: TileMapLayer でもなく layout_node も Node2D ではない。")
				return
			var layout_2d_fallback: Node2D = layout_node
			var sx_f: float = cell_size.x
			var sy_f: float = cell_size.y
			if sx_f <= 0.0:
				sx_f = 1.0
			if sy_f <= 0.0:
				sy_f = 1.0
			var local_pos_f: Vector2 = Vector2(
				float(cell.x) * sx_f + sx_f * 0.5,
				float(cell.y) * sy_f + sy_f * 0.5
			)
			global_pos = layout_2d_fallback.to_global(local_pos_f)
	else:
		if not (layout_node is Node2D):
			push_error("RuntimeLayoutKeyboardController: layout_node が Node2D ではない。")
			return

		var layout_2d: Node2D = layout_node
		var sx: float = cell_size.x
		var sy: float = cell_size.y
		if sx <= 0.0:
			sx = 1.0
		if sy <= 0.0:
			sy = 1.0

		var local_pos: Vector2 = Vector2(
			float(cell.x) * sx + sx * 0.5,
			float(cell.y) * sy + sy * 0.5
		)

		global_pos = layout_2d.to_global(local_pos)

	target_2d.global_position = global_pos

	if log_enabled:
		var kind_str: String = ""
		if move_target_kind == MoveTargetKind.MOVE_ON_FLOORS:
			kind_str = "FLOOR"
		else:
			kind_str = "NEAR_WALL"

		var ref_str: String = "N/A"
		if reference_valid:
			ref_str = str(reference_cell)

		print(
			"RuntimeLayoutKeyboardController: moved target node=",
			target_2d.name,
			" to free cell=(",
			str(cell.x),
			",",
			str(cell.y),
			") kind=",
			kind_str,
			" ref_cell=",
			ref_str,
			" global_pos=",
			str(global_pos)
		)

# ===== ZoomCamera2D / Camera2D の limit_* をレイアウト四辺に合わせる =====

func _update_zoom_camera_limits() -> void:
	if zoom_camera_path == NodePath(""):
		return
	if not is_instance_valid(layout_node):
		return

	var cam_any: Variant = get_node_or_null(zoom_camera_path)
	if not (cam_any is Camera2D):
		return

	var cam: Camera2D = cam_any

	if not (layout_node is Node2D):
		return

	var layout_2d: Node2D = layout_node

	var w_any = layout_node.get("width")
	var h_any = layout_node.get("height")
	if typeof(w_any) != TYPE_INT or typeof(h_any) != TYPE_INT:
		return

	var gw: int = int(w_any)
	var gh: int = int(h_any)
	if gw <= 0 or gh <= 0:
		return

	var sx: float = cell_size.x
	var sy: float = cell_size.y
	if sx <= 0.0:
		sx = 1.0
	if sy <= 0.0:
		sy = 1.0

	var local_tl: Vector2 = Vector2(0.0, 0.0)
	var local_br: Vector2 = Vector2(float(gw) * sx, float(gh) * sy)

	var global_tl: Vector2 = layout_2d.to_global(local_tl)
	var global_br: Vector2 = layout_2d.to_global(local_br)

	var left: float = min(global_tl.x, global_br.x)
	var right: float = max(global_tl.x, global_br.x)
	var top: float = min(global_tl.y, global_br.y)
	var bottom: float = max(global_tl.y, global_br.y)

	cam.limit_left = int(floor(left))
	cam.limit_right = int(ceil(right))
	cam.limit_top = int(floor(top))
	cam.limit_bottom = int(ceil(bottom))

	if log_enabled:
		print(
			"RuntimeLayoutKeyboardController: camera limits l=",
			str(cam.limit_left),
			" r=",
			str(cam.limit_right),
			" t=",
			str(cam.limit_top),
			" b=",
			str(cam.limit_bottom)
		)
