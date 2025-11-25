@tool
extends Node2D

# Godot 4.4 / GDScript 2.0
# 部屋・通路レイアウトのデータ専用ジェネレータ（TileMap にコミットしない）
# - 壁=埋め、床=掘る。ドアは予約（未使用）
# - 同期／非同期生成対応
# - 通路幅は固定 or 範囲ランダム（セグメント毎抽選可）
# - 結果は grid（int 2次元配列）、rooms（Rect2i）、centers（Vector2i）を公開
# - room_id_grid, corridor_id_grid で部屋ID・通路IDを保持
# - used_cells_mask で TilePlacer 側から渡された「使用済みセル」を保持し、
#   get_free_cells() で「まだ何も置かれていないセル」を返せるようにする。
# - リソース不使用、インスペクタ数値のみ

## レイアウトが更新されたときに、現在の grid / rooms / centers を通知するシグナル。
signal layout_updated(grid: Array, rooms: Array, centers: Array)
## レイアウト生成（同期／非同期）が終了したときに、成功／失敗を通知するシグナル。
signal generation_finished(success: bool)

const CELL_WALL: int = 0
const CELL_FLOOR: int = 1
const CELL_DOOR: int = 2

## レイアウトグリッドの幅（セル数）。
@export var width: int = 80:
	set = _set_width
## レイアウトグリッドの高さ（セル数）。
@export var height: int = 60:
	set = _set_height
## グリッド外周からどれだけ余白を空けて部屋を配置するか（セル数）。
@export var cell_padding: int = 1:
	set = _set_cell_padding

## 生成を試みる部屋の目標個数。
@export var room_count: int = 18:
	set = _set_room_count
## 部屋幅の最小値（セル数）。
@export var room_w_min: int = 5:
	set = _set_room_w_min
## 部屋幅の最大値（セル数）。
@export var room_w_max: int = 14:
	set = _set_room_w_max
## 部屋高さの最小値（セル数）。
@export var room_h_min: int = 4:
	set = _set_room_h_min
## 部屋高さの最大値（セル数）。
@export var room_h_max: int = 12:
	set = _set_room_h_max

## 通路幅の基本値。ランダム幅を使わない場合に使用される。
@export var corridor_width: int = 1:
	set = _set_corridor_width
## ランダム通路幅の最小値。
@export var corridor_width_min: int = 0:
	set = _set_corridor_width_min
## ランダム通路幅の最大値。
@export var corridor_width_max: int = 1:
	set = _set_corridor_width_max
## true のとき、通路ごと（セグメントごと）に幅をランダム決定する。
@export var corridor_width_randomize_each_corridor: bool = true:
	set = _set_corridor_width_randomize_each_corridor

## true のとき、部屋中心間の通路を斜めパスで掘る。
@export var corridor_use_diagonal_path: bool = false

## true のとき、連結性チェックで斜め接続（8方向）も通行可能として扱う。
@export var connectivity_allow_diagonal: bool = false

# ここから seed 周りを修正
var _seed_internal: int = 123456

## レイアウト生成に使用する乱数シード。同じ値なら同じレイアウトが再現される。
@export var seed: int = 123456:
	set(value):
		_seed_internal = value

		# エディタから seed を変えたときだけライブ更新
		if Engine.is_editor_hint():
			if editor_live_update:
				_generate_editor_safe()
		else:
			# ランタイムで seed が変わったときは、
			# RunOnEditor ボタンと同じ「manual generation」として扱う。
			var layout: Node = self

			if layout != null:
				var in_manual_any: Variant = TerrainAtlasPatternPlacer._layout_manual_generation_in_progress.get(layout, false)
				var in_manual: bool = bool(in_manual_any)
				if not in_manual:
					TerrainAtlasPatternPlacer._layout_manual_generation_in_progress[layout] = true
					TerrainAtlasPatternPlacer._layout_manual_generation_handled[layout] = false
					# 今回は同期生成。非同期にしたければ export フラグを追加して分岐させる。
					generate_now()
	get:
		return _seed_internal
# ここまで seed 修正

## 部屋生成が失敗した場合にやり直す最大試行回数。
@export var max_retry: int = 25:
	set = _set_max_retry
## 非同期生成時、何行ごとに process_frame へ yield するか。
@export var async_yield_rows: int = 6:
	set = _set_async_yield_rows

## true でログ出力を有効にする。
@export var log_enabled: bool = true
## ログの詳細度。値が大きいほど詳細なログを出す。
@export var log_verbosity: int = 1

func _ctx() -> String:
	if Engine.is_editor_hint():
		return "[EDITOR]"
	return "[RUNTIME]"

func _log(level: int, msg: String) -> void:
	if not log_enabled:
		return
	if level > log_verbosity:
		return
	print(_ctx() + " " + msg)

func _warn(msg: String) -> void:
	if not log_enabled:
		return
	push_warning(_ctx() + " WARN: " + msg)

func _err(msg: String) -> void:
	push_error(_ctx() + " ERROR: " + msg)
	printerr(_ctx() + " ERROR: " + msg)

var rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _is_generating: bool = false

# ===== メイン出力 =====
var grid: Array = []                        # int [height][width]
var rooms: Array[Rect2i] = []               # 部屋矩形
var centers: Array[Vector2i] = []           # 部屋中心座標

# ===== 部屋ID・通路IDグリッド =====
# room_id_grid[y][x] = 部屋ID（rooms のインデックス）または -1
# corridor_id_grid[y][x] = 通路ID（0 〜）または -1
var room_id_grid: Array = []
var corridor_id_grid: Array = []
var _next_corridor_id: int = 0

# ===== 使用済みセルマスク（TilePlacer から登録される）=====
# used_cells_mask[y][x] = そのセルが「何かに使われた」かどうか
var used_cells_mask: Array = []

# ===== エディタ用オプション =====
## シーンロード時など、エディタ上で自動的にレイアウトを生成する。
@export var editor_auto_generate: bool = true:
	set = _set_editor_auto_generate
## エディタでパラメータを変えたタイミングで、即座にレイアウトを再生成する。
@export var editor_live_update: bool = true:
	set = _set_editor_live_update
## エディタからボタン的に一度だけ生成を実行したいときに ON にするフラグ。
@export var editor_generate_button: bool = false:
	set = _set_editor_generate_button

func _set_editor_auto_generate(v: bool) -> void:
	editor_auto_generate = v

func _set_editor_live_update(v: bool) -> void:
	editor_live_update = v
	if Engine.is_editor_hint():
		if editor_live_update:
			_generate_editor_safe()

func _set_editor_generate_button(v: bool) -> void:
	if v:
		_generate_editor_safe()
	editor_generate_button = false

# エディタから安全に生成を呼び出すラッパ。
func _generate_editor_safe() -> void:
	var ok: bool = _generate_with_retry()
	emit_signal("generation_finished", ok)

# ===== セッター =====
func _set_width(v: int) -> void:
	if v < 8:
		width = 8
	else:
		width = v
	if Engine.is_editor_hint():
		if editor_live_update:
			_generate_editor_safe()

func _set_height(v: int) -> void:
	if v < 8:
		height = 8
	else:
		height = v
	if Engine.is_editor_hint():
		if editor_live_update:
			_generate_editor_safe()

func _set_cell_padding(v: int) -> void:
	if v < 0:
		cell_padding = 0
	else:
		cell_padding = v
	if Engine.is_editor_hint():
		if editor_live_update:
			_generate_editor_safe()

func _set_room_count(v: int) -> void:
	if v < 1:
		room_count = 1
	else:
		room_count = v
	if Engine.is_editor_hint():
		if editor_live_update:
			_generate_editor_safe()

func _set_room_w_min(v: int) -> void:
	if v < 1:
		room_w_min = 1
	else:
		room_w_min = v
	if room_w_max < room_w_min:
		room_w_max = room_w_min
	if Engine.is_editor_hint():
		if editor_live_update:
			_generate_editor_safe()

func _set_room_w_max(v: int) -> void:
	if v < 1:
		room_w_max = 1
	else:
		room_w_max = v
	if room_w_max < room_w_min:
		room_w_min = room_w_max
	if Engine.is_editor_hint():
		if editor_live_update:
			_generate_editor_safe()

func _set_room_h_min(v: int) -> void:
	if v < 1:
		room_h_min = 1
	else:
		room_h_min = v
	if room_h_max < room_h_min:
		room_h_max = room_h_min
	if Engine.is_editor_hint():
		if editor_live_update:
			_generate_editor_safe()

func _set_room_h_max(v: int) -> void:
	if v < 1:
		room_h_max = 1
	else:
		room_h_max = v
	if room_h_max < room_h_min:
		room_h_min = room_h_max
	if Engine.is_editor_hint():
		if editor_live_update:
			_generate_editor_safe()

func _set_corridor_width(v: int) -> void:
	if v < 0:
		corridor_width = 0
	else:
		corridor_width = v
	if Engine.is_editor_hint():
		if editor_live_update:
			_generate_editor_safe()

func _set_corridor_width_min(v: int) -> void:
	if v < 0:
		corridor_width_min = 0
	else:
		corridor_width_min = v
	if Engine.is_editor_hint():
		if editor_live_update:
			_generate_editor_safe()

func _set_corridor_width_max(v: int) -> void:
	if v < 0:
		corridor_width_max = 0
	else:
		corridor_width_max = v
	if Engine.is_editor_hint():
		if editor_live_update:
			_generate_editor_safe()

func _set_corridor_width_randomize_each_corridor(v: bool) -> void:
	corridor_width_randomize_each_corridor = v
	if Engine.is_editor_hint():
		if editor_live_update:
			_generate_editor_safe()

func _set_max_retry(v: int) -> void:
	if v < 1:
		max_retry = 1
	else:
		max_retry = v

func _set_async_yield_rows(v: int) -> void:
	if v < 1:
		async_yield_rows = 1
	else:
		async_yield_rows = v

# ===== ライフサイクル =====
func _enter_tree() -> void:
	if Engine.is_editor_hint():
		if editor_auto_generate:
			_generate_editor_safe()

# RNG にシードをセットして、少しだけウォームアップする。
func _seed_rng(s: int) -> void:
	rng.seed = s
	var i: int = 0
	while i < 4:
		rng.randf()
		i += 1

# ===== 外部 API =====
func generate_now() -> void:
	var ok: bool = _generate_with_retry()
	emit_signal("generation_finished", ok)

func generate_async() -> Signal:
	if _is_generating:
		_err("generate_async: busy")
		return generation_finished
	_is_generating = true
	var ok_async: bool = await _generate_with_retry_async()
	_is_generating = false
	emit_signal("generation_finished", ok_async)
	return generation_finished

# ===== リトライ付き生成 =====
func _generate_with_retry() -> bool:
	var attempt: int = 0
	var ok: bool = false
	_seed_rng(seed)
	while attempt < max_retry and not ok:
		attempt += 1
		ok = _generate_once()
		if not ok:
			_seed_rng(seed + attempt)
	if ok:
		_log(1, "layout generation OK")
	else:
		_log(1, "layout generation NG")
	return ok

func _generate_with_retry_async() -> bool:
	var attempt: int = 0
	var ok: bool = false
	_seed_rng(seed)
	while attempt < max_retry and not ok:
		attempt += 1
		ok = await _generate_once_async()
		if not ok:
			_seed_rng(seed + attempt)
	return ok

# ===== グリッド初期化（used_cells_mask もここで初期化） =====
func _init_grids() -> void:
	grid.clear()
	room_id_grid.clear()
	corridor_id_grid.clear()
	rooms.clear()
	centers.clear()
	used_cells_mask.clear()
	_next_corridor_id = 0

	var y0: int = 0
	while y0 < height:
		var row: Array[int] = []
		var room_row: Array[int] = []
		var cor_row: Array[int] = []
		var used_row: Array[bool] = []
		var x0: int = 0
		while x0 < width:
			row.append(CELL_WALL)
			room_row.append(-1)
			cor_row.append(-1)
			used_row.append(false)
			x0 += 1
		grid.append(row)
		room_id_grid.append(room_row)
		corridor_id_grid.append(cor_row)
		used_cells_mask.append(used_row)
		y0 += 1

# ===== 同期生成 =====
func _generate_once() -> bool:
	_init_grids()

	var tries: int = 0
	while rooms.size() < room_count and tries < room_count * 30:
		tries += 1
		var rw: int = _rand_range_int(room_w_min, room_w_max)
		var rh: int = _rand_range_int(room_h_min, room_h_max)
		var rx: int = _rand_range_int(cell_padding, width - cell_padding - rw - 1)
		var ry: int = _rand_range_int(cell_padding, height - cell_padding - rh - 1)
		var rect: Rect2i = Rect2i(rx, ry, rw, rh)
		if not _intersects_any(rect):
			var room_idx: int = rooms.size()
			rooms.append(rect)
			_dig_room(rect, room_idx)
			var cx: int = rect.position.x + rect.size.x / 2
			var cy: int = rect.position.y + rect.size.y / 2
			var c: Vector2i = Vector2i(cx, cy)
			centers.append(c)

	if rooms.size() < max(3, room_count / 2):
		_warn("too few rooms: " + str(rooms.size()))
		emit_signal("layout_updated", grid, rooms, centers)
		return false

	_connect_all_rooms_with_corridors()

	if not _validate_connectivity():
		emit_signal("layout_updated", grid, rooms, centers)
		return false

	emit_signal("layout_updated", grid, rooms, centers)
	return true

# ===== 非同期生成 =====
func _generate_once_async() -> bool:
	_init_grids()

	var y0: int = 0
	while y0 < height:
		if y0 % async_yield_rows == 0:
			await get_tree().process_frame
		y0 += 1

	var tries: int = 0
	while rooms.size() < room_count and tries < room_count * 30:
		tries += 1
		var rw: int = _rand_range_int(room_w_min, room_w_max)
		var rh: int = _rand_range_int(room_h_min, room_h_max)
		var rx: int = _rand_range_int(cell_padding, width - cell_padding - rw - 1)
		var ry: int = _rand_range_int(cell_padding, height - cell_padding - rh - 1)
		var rect: Rect2i = Rect2i(rx, ry, rw, rh)
		if not _intersects_any(rect):
			var room_idx: int = rooms.size()
			rooms.append(rect)
			_dig_room(rect, room_idx)
			var cx: int = rect.position.x + rect.size.x / 2
			var cy: int = rect.position.y + rect.size.y / 2
			var c: Vector2i = Vector2i(cx, cy)
			centers.append(c)
		if tries % (room_count / 2 + 1) == 0:
			await get_tree().process_frame

	_connect_all_rooms_with_corridors()
	await get_tree().process_frame

	if not _validate_connectivity():
		emit_signal("layout_updated", grid, rooms, centers)
		return false

	emit_signal("layout_updated", grid, rooms, centers)
	return true

# ===== 基本ユーティリティ =====
func _rand_range_int(a: int, b: int) -> int:
	if b < a:
		return a
	var span: int = b - a + 1
	var r: int = a + int(floor(rng.randf() * float(span)))
	if r < a:
		r = a
	if r > b:
		r = b
	return r

func _intersects_any(r: Rect2i) -> bool:
	var i: int = 0
	while i < rooms.size():
		var other: Rect2i = rooms[i]
		var expanded: Rect2i = Rect2i(other.position.x - 1, other.position.y - 1, other.size.x + 2, other.size.y + 2)
		if expanded.intersects(r):
			return true
		i += 1
	return false

# ===== 部屋掘り + 部屋ID付与 =====
func _dig_room(r: Rect2i, room_idx: int) -> void:
	var y: int = r.position.y
	while y < r.position.y + r.size.y:
		var x: int = r.position.x
		while x < r.position.x + r.size.x:
			grid[y][x] = CELL_FLOOR
			room_id_grid[y][x] = room_idx
			x += 1
		y += 1

# ===== 通路幅 =====
func _get_corridor_width_for_segment() -> int:
	if corridor_width_randomize_each_corridor:
		var wmin: int = corridor_width_min
		var wmax: int = corridor_width_max
		if wmin < 0:
			wmin = 0
		if wmax < wmin:
			wmax = wmin
		return _rand_range_int(wmin, wmax)
	if corridor_width < 0:
		return 0
	return corridor_width

# ===== 通路生成（部屋中心を最短木でつなぐ）=====
func _connect_all_rooms_with_corridors() -> void:
	if centers.size() <= 1:
		return
	var used: Array[Vector2i] = []
	var unused: Array[Vector2i] = []
	var i: int = 0
	while i < centers.size():
		unused.append(centers[i])
		i += 1
	used.append(unused.pop_back())
	while not unused.is_empty():
		var best_u: Vector2i = used[0]
		var best_v: Vector2i = unused[0]
		var best_dist: int = 999999
		var ui: int = 0
		while ui < used.size():
			var vi: int = 0
			while vi < unused.size():
				var a: Vector2i = used[ui]
				var b: Vector2i = unused[vi]
				var d: int = abs(a.x - b.x) + abs(a.y - b.y)
				if d < best_dist:
					best_dist = d
					best_u = a
					best_v = b
				vi += 1
			ui += 1
		var w: int = _get_corridor_width_for_segment()
		var cid: int = _next_corridor_id
		_next_corridor_id += 1
		_dig_corridor(best_u, best_v, w, cid)
		used.append(best_v)
		var idx: int = unused.find(best_v)
		if idx >= 0:
			unused.remove_at(idx)

# 通路掘り + 通路ID付与
func _dig_corridor(a: Vector2i, b: Vector2i, w: int, corridor_id: int) -> void:
	if corridor_use_diagonal_path:
		_dig_line_diagonal_simple(a, b, w, corridor_id)
		return

	if rng.randi() % 2 == 0:
		_dig_h_line(min(a.x, b.x), max(a.x, b.x), a.y, w, corridor_id)
		_dig_v_line(min(a.y, b.y), max(a.y, b.y), b.x, w, corridor_id)
	else:
		_dig_v_line(min(a.y, b.y), max(a.y, b.y), a.x, w, corridor_id)
		_dig_h_line(min(a.x, b.x), max(a.x, b.x), b.y, w, corridor_id)

func _dig_h_line(x0: int, x1: int, y: int, w: int, corridor_id: int) -> void:
	var x: int = x0
	while x <= x1:
		_dig_plus(x, y, w, corridor_id)
		x += 1

func _dig_v_line(y0: int, y1: int, x: int, w: int, corridor_id: int) -> void:
	var y: int = y0
	while y <= y1:
		_dig_plus(x, y, w, corridor_id)
		y += 1

# 非 Bresenham。毎ステップ x と y を目標に向けて 1 マスずつ近づけるだけの安全な斜めライン。
func _dig_line_diagonal_simple(a: Vector2i, b: Vector2i, w: int, corridor_id: int) -> void:
	var x: int = a.x
	var y: int = a.y
	var target_x: int = b.x
	var target_y: int = b.y

	var max_steps: int = width * height * 2
	if max_steps < 1:
		max_steps = 1

	var steps: int = 0
	while true:
		_dig_plus(x, y, w, corridor_id)

		if x == target_x and y == target_y:
			break

		var dx: int = 0
		if x < target_x:
			dx = 1
		elif x > target_x:
			dx = -1

		var dy: int = 0
		if y < target_y:
			dy = 1
		elif y > target_y:
			dy = -1

		if dx == 0 and dy == 0:
			break

		x += dx
		y += dy

		steps += 1
		if steps >= max_steps:
			_warn("_dig_line_diagonal_simple: safety break")
			break

func _dig_plus(x: int, y: int, w: int, corridor_id: int) -> void:
	var oy: int = -w
	while oy <= w:
		var ox: int = -w
		while ox <= w:
			var px: int = x + ox
			var py: int = y + oy
			if px >= 0 and px < width and py >= 0 and py < height:
				grid[py][px] = CELL_FLOOR
				if corridor_id >= 0:
					corridor_id_grid[py][px] = corridor_id
			ox += 1
		oy += 1

# ===== 連結性チェック =====
func _validate_connectivity() -> bool:
	var visited: PackedByteArray = PackedByteArray()
	visited.resize(width * height)
	var start_found: bool = false
	var sx: int = 0
	var sy: int = 0

	var y: int = 0
	while y < height and not start_found:
		var x: int = 0
		while x < width and not start_found:
			if grid[y][x] == CELL_FLOOR:
				sx = x
				sy = y
				start_found = true
			x += 1
		y += 1
	if not start_found:
		return false

	var dirs: Array[Vector2i] = []
	dirs.append(Vector2i(1, 0))
	dirs.append(Vector2i(-1, 0))
	dirs.append(Vector2i(0, 1))
	dirs.append(Vector2i(0, -1))
	if connectivity_allow_diagonal:
		dirs.append(Vector2i(1, 1))
		dirs.append(Vector2i(-1, 1))
		dirs.append(Vector2i(1, -1))
		dirs.append(Vector2i(-1, -1))

	var queue: Array[Vector2i] = []
	queue.append(Vector2i(sx, sy))
	visited[sy * width + sx] = 1
	var walkable_count: int = 0

	while not queue.is_empty():
		var p: Vector2i = queue.pop_front()
		walkable_count += 1

		var i2: int = 0
		while i2 < dirs.size():
			var nx: int = p.x + dirs[i2].x
			var ny: int = p.y + dirs[i2].y
			if nx >= 0 and nx < width and ny >= 0 and ny < height:
				var idx2: int = ny * width + nx
				if visited[idx2] == 0:
					if grid[ny][nx] == CELL_FLOOR or grid[ny][nx] == CELL_DOOR:
						visited[idx2] = 1
						queue.append(Vector2i(nx, ny))
			i2 += 1

	var total_floor: int = 0
	y = 0
	while y < height:
		var x2: int = 0
		while x2 < width:
			if grid[y][x2] == CELL_FLOOR or grid[y][x2] == CELL_DOOR:
				total_floor += 1
			x2 += 1
		y += 1

	if walkable_count < max(1, total_floor * 8 / 10):
		return false
	return true

# ====== コピー系ゲッター ======
func get_grid_copy() -> Array:
	var out: Array = []
	var y: int = 0
	while y < grid.size():
		out.append(grid[y].duplicate(true))
		y += 1
	return out

func get_rooms_copy() -> Array:
	var out: Array[Rect2i] = []
	var i: int = 0
	while i < rooms.size():
		out.append(rooms[i])
		i += 1
	return out

func get_centers_copy() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var i: int = 0
	while i < centers.size():
		out.append(centers[i])
		i += 1
	return out

func get_room_id_grid_copy() -> Array:
	var out: Array = []
	var y: int = 0
	while y < room_id_grid.size():
		out.append(room_id_grid[y].duplicate(true))
		y += 1
	return out

func get_corridor_id_grid_copy() -> Array:
	var out: Array = []
	var y: int = 0
	while y < corridor_id_grid.size():
		out.append(corridor_id_grid[y].duplicate(true))
		y += 1
	return out

# ====== 部屋面積関連 API ======
func get_room_area(room_index: int) -> int:
	if room_index < 0:
		return 0
	if room_index >= rooms.size():
		return 0
	var r: Rect2i = rooms[room_index]
	return r.size.x * r.size.y

func get_all_room_areas() -> Array[int]:
	var out: Array[int] = []
	var i: int = 0
	while i < rooms.size():
		out.append(get_room_area(i))
		i += 1
	return out

# ====== 使用済みセル登録（TilePlacer から呼ばれる） ======
func register_used_cells(cells: Array[Vector2i]) -> void:
	if used_cells_mask.is_empty():
		return
	var h: int = used_cells_mask.size()
	var w: int = used_cells_mask[0].size()
	var i: int = 0
	while i < cells.size():
		var p: Vector2i = cells[i]
		if p.y >= 0 and p.y < h and p.x >= 0 and p.x < w:
			used_cells_mask[p.y][p.x] = true
		i += 1

func clear_used_cells() -> void:
	if used_cells_mask.is_empty():
		return
	var y: int = 0
	while y < used_cells_mask.size():
		var row: Array = used_cells_mask[y]
		var x: int = 0
		while x < row.size():
			row[x] = false
			x += 1
		y += 1

func get_free_cells(kind: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var h: int = grid.size()
	if h <= 0:
		return out
	var w: int = grid[0].size()
	var y: int = 0
	while y < h:
		var x: int = 0
		while x < w:
			var cell: int = grid[y][x]
			var is_target: bool = false
			if kind == CELL_WALL:
				if cell == CELL_WALL:
					is_target = true
			else:
				if cell == CELL_FLOOR or cell == CELL_DOOR:
					is_target = true
			if is_target:
				if not used_cells_mask[y][x]:
					out.append(Vector2i(x, y))
			x += 1
		y += 1
	return out
