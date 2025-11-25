@tool
extends EditorInspectorPlugin

# File: addons/terrain_pattern_tools/terrain_pattern_placer_inspector.gd
# TerrainAtlasPatternPlacer.gd 用インスペクタ拡張
#
# ・対象 TileMapLayer の TileSet から Pattern 一覧を取得
# ・各 Pattern ごとに
#     - サムネイル（実タイルの見た目そのまま。縮小なし）
#     - グリッド版サムネ（Pattern のセル配置だけをマス目で表示）
#     - 出現重み（数値入力 SpinBox）
#     - 接地条件（上下左右のチェックボックス）
#     - 必須接地セル（Pattern 内の「必ず縁に接していなければならないセル」をクリックで指定）
#     - 最低設置数（Min）
#     - 最大設置数（Max, -1 で無制限）
#     - register_used_cells_to_layout のパターン別オーバーライド（Reg）
#     - only_place_on_unoccupied のパターン別オーバーライド（Unocc）
#   を設定できる UI を提供する。
#
# TerrainAtlasPatternPlacer 側の対応プロパティ:
#   - pattern_weights                         : Dictionary (key = pattern index, value = float)
#   - pattern_adjacent_dirs                   : Dictionary (key = pattern index, value = int bitmask)
#   - pattern_required_cells                  : Dictionary (key = pattern index, value = Array[Vector2i])
#   - pattern_min_counts                      : Dictionary (key = pattern index, value = int)
#   - pattern_max_counts                      : Dictionary (key = pattern index, value = int, -1 or unset)
#   - pattern_register_used_cells_override    : Dictionary (key = pattern index, value = int 0/1/2)
#   - pattern_only_place_on_unoccupied_override : Dictionary (key = pattern index, value = int 0/1/2)
#
# bitmask は 1=U, 2=R, 4=D, 8=L

# タイルセット＋パターンをそのまま TileMapLayer で描画するプレビュー用 Control
class PatternPreviewControl:
	extends Control

	var tileset: TileSet = null
	var pattern: TileMapPattern = null
	var preview_size: Vector2 = Vector2.ZERO

	var _tilemap: TileMapLayer = null
	const _MARGIN: float = 2.0

	# プレビューに使う TileSet / Pattern を設定
	func setup(p_tileset: TileSet, p_pattern: TileMapPattern) -> void:
		tileset = p_tileset
		pattern = p_pattern
		_rebuild_tilemap()
		_compute_preview_size()
		_update_min_size()

	# Pattern の内容から一時 TileMapLayer を構築し直す
	func _rebuild_tilemap() -> void:
		if _tilemap != null and is_instance_valid(_tilemap):
			remove_child(_tilemap)
			_tilemap.queue_free()
			_tilemap = null

		if tileset == null:
			return
		if pattern == null:
			return

		_tilemap = TileMapLayer.new()
		_tilemap.tile_set = tileset
		_tilemap.position = Vector2(_MARGIN, _MARGIN)
		_tilemap.y_sort_enabled = false
		add_child(_tilemap)

		var used: Array[Vector2i] = pattern.get_used_cells()
		var i: int = 0
		while i < used.size():
			var cell: Vector2i = used[i]
			var source_id: int = pattern.get_cell_source_id(cell)
			var atlas_coords: Vector2i = pattern.get_cell_atlas_coords(cell)
			var alt_id: int = pattern.get_cell_alternative_tile(cell)
			_tilemap.set_cell(cell, source_id, atlas_coords, alt_id)
			i += 1

	# Pattern サイズとタイルサイズからピクセルサイズを計算
	func _compute_preview_size() -> void:
		if tileset == null:
			preview_size = Vector2.ZERO
			return
		if pattern == null:
			preview_size = Vector2.ZERO
			return

		var cell_size: Vector2i = tileset.tile_size
		if cell_size.x <= 0:
			cell_size.x = 16
		if cell_size.y <= 0:
			cell_size.y = 16

		var psize: Vector2i = pattern.get_size()
		if psize.x <= 0 or psize.y <= 0:
			preview_size = Vector2.ZERO
			return

		var px_w: float = float(psize.x * cell_size.x)
		var px_h: float = float(psize.y * cell_size.y)
		preview_size = Vector2(px_w + _MARGIN * 2.0, px_h + _MARGIN * 2.0)

	# レイアウト用に custom_minimum_size を更新
	func _update_min_size() -> void:
		custom_minimum_size = preview_size


# Pattern の使用セルだけをグリッドで表示する簡易プレビュー用 Control
class PatternGridPreviewControl:
	extends Control

	var pattern: TileMapPattern = null
	var preview_size: Vector2 = Vector2.ZERO
	var cell_pixel_size: Vector2 = Vector2(8.0, 8.0)

	# パターンを設定してサイズを計算
	func setup(p_pattern: TileMapPattern) -> void:
		pattern = p_pattern
		_compute_preview_size()
		_update_min_size()
		queue_redraw()

	# Pattern サイズからプレビューサイズを計算
	func _compute_preview_size() -> void:
		if pattern == null:
			preview_size = Vector2.ZERO
			return

		var psize: Vector2i = pattern.get_size()
		if psize.x <= 0 or psize.y <= 0:
			preview_size = Vector2.ZERO
			return

		var px_w: float = float(psize.x) * cell_pixel_size.x
		var px_h: float = float(psize.y) * cell_pixel_size.y
		var margin: float = 2.0
		preview_size = Vector2(px_w + margin * 2.0, px_h + margin * 2.0)

	# レイアウト用に custom_minimum_size を更新
	func _update_min_size() -> void:
		custom_minimum_size = preview_size

	# 使用セルを塗ったグリッドを描画
	func _draw() -> void:
		if pattern == null:
			return
		if preview_size == Vector2.ZERO:
			return

		var psize: Vector2i = pattern.get_size()
		if psize.x <= 0 or psize.y <= 0:
			return

		var margin: float = 2.0

		var used: Array[Vector2i] = pattern.get_used_cells()
		var used_set: Dictionary = {}
		var ui: int = 0
		while ui < used.size():
			var c: Vector2i = used[ui]
			used_set[c] = true
			ui += 1

		var y: int = 0
		while y < psize.y:
			var x: int = 0
			while x < psize.x:
				var pos: Vector2 = Vector2(
					margin + float(x) * cell_pixel_size.x,
					margin + float(y) * cell_pixel_size.y
				)
				var rect: Rect2 = Rect2(pos, cell_pixel_size)

				var key: Vector2i = Vector2i(x, y)
				var filled: bool = used_set.has(key)

				if filled:
					draw_rect(rect, Color(0.9, 0.9, 1.0, 0.9), true)
				draw_rect(rect, Color(0.2, 0.2, 0.3, 1.0), false)

				x += 1
			y += 1


# 対象が TerrainAtlasPatternPlacer か判定
func _is_target_object(obj: Object) -> bool:
	if obj == null:
		return false

	var s = obj.get_script()
	if s == null:
		return false

	var obj_path: String = s.resource_path

	# このインスペクタ自身のスクリプトが置かれているディレクトリを取得
	var this_script: Script = get_script()
	if this_script == null:
		return false
	var base_dir: String = this_script.resource_path.get_base_dir()

	# 同じディレクトリ内の terrain_atlas_pattern_placer.gd / TerrainAtlasPatternPlacer.gd を対象にする
	var lower_path: String = base_dir + "/terrain_atlas_pattern_placer.gd"
	var upper_path: String = base_dir + "/TerrainAtlasPatternPlacer.gd"

	if obj_path == lower_path:
		return true
	if obj_path == upper_path:
		return true

	return false

# インスペクタ拡張の対象かどうか
func _can_handle(object: Object) -> bool:
	return _is_target_object(object)

# インスペクタにカスタム UI を差し込む
func _parse_begin(object: Object) -> void:
	if not _is_target_object(object):
		return

	var placer := object

	# インスペクタに追加するルートコンテナ
	var root := VBoxContainer.new()

	# タイトル
	var title := Label.new()
	title.text = "Terrain Pattern Meta (Weights / Adj / Required / Min / Max / Reg / Unocc)"
	title.add_theme_color_override("font_color", Color(0.9, 0.9, 1.0))
	title.tooltip_text = "TerrainAtlasPatternPlacer 用のパターンメタ情報をまとめて設定します。"
	title.mouse_filter = Control.MOUSE_FILTER_PASS
	root.add_child(title)

	# 概要説明
	var desc := Label.new()
	desc.text = "TileSet の Pattern ごとに出現率・接地条件・必須接地セル・最低/最大設置数・register_used_cells_to_layout/only_place_on_unoccupied のパターン別オーバーライドを設定します。"
	desc.tooltip_text = "Pattern ごとに配置ルールや制約を細かく制御するための設定です。"
	desc.mouse_filter = Control.MOUSE_FILTER_PASS
	root.add_child(desc)

	# Pattern 一覧をスクロール表示するコンテナ
	var sc := ScrollContainer.new()
	sc.custom_minimum_size = Vector2(0, 260)
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.tooltip_text = "TileSet に登録された Pattern 一覧をスクロールして表示します。"

	# パターン行を縦に並べるコンテナ
	var list := VBoxContainer.new()
	list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(list)

	root.add_child(sc)

	# パターン一覧を構築
	_build_pattern_list(placer, list)

	add_custom_control(root)

# ===== ユーティリティ =====

# Dictionary プロパティを安全に取得（未設定なら空 Dictionary を作成）
func _get_dict_safe(placer: Object, prop_name: String) -> Dictionary:
	var v := placer.get(prop_name)
	if typeof(v) == TYPE_NIL:
		var d_new: Dictionary = {}
		placer.set(prop_name, d_new)
		return d_new
	if typeof(v) == TYPE_DICTIONARY:
		var d_exist: Dictionary = v
		return d_exist
	var d2: Dictionary = {}
	placer.set(prop_name, d2)
	return d2

# Array に指定 Vector2i が含まれているか判定
func _array_has_vec2i(arr: Array, pos: Vector2i) -> bool:
	var i: int = 0
	while i < arr.size():
		var v_any = arr[i]
		if v_any is Vector2i:
			var v: Vector2i = v_any
			if v == pos:
				return true
		i += 1
	return false

# Array から指定 Vector2i を 1 件削除して返す
func _array_remove_vec2i(arr: Array, pos: Vector2i) -> Array:
	var i: int = 0
	while i < arr.size():
		var v_any = arr[i]
		if v_any is Vector2i:
			var v: Vector2i = v_any
			if v == pos:
				arr.remove_at(i)
				return arr
		i += 1
	return arr

# 必須セルボタンの色を状態に合わせて更新
func _update_required_button_color(btn: Button, is_required: bool, is_used: bool) -> void:
	if is_required:
		btn.modulate = Color(1.0, 0.2, 0.2, 1.0)
	else:
		if is_used:
			btn.modulate = Color(1.0, 1.0, 1.0, 0.9)
		else:
			btn.modulate = Color(0.6, 0.6, 0.9, 0.65)

# ===== パターン一覧 UI =====
func _build_pattern_list(placer: Object, list: VBoxContainer) -> void:
	# 既存の子ノードをクリア
	var children: Array = list.get_children()
	var idx_child: int = 0
	while idx_child < children.size():
		var c: Node = children[idx_child]
		list.remove_child(c)
		c.queue_free()
		idx_child += 1

	# 対象 TileMapLayer を取得
	var layer: TileMapLayer = null
	if placer.target_layer_path != NodePath(""):
		var node_any: Node = placer.get_node_or_null(placer.target_layer_path)
		if node_any is TileMapLayer:
			layer = node_any

	# TileMapLayer が見つからない場合
	if layer == null:
		var lbl_none := Label.new()
		lbl_none.text = "Target TileMapLayer が見つかりません。"
		lbl_none.tooltip_text = "TerrainAtlasPatternPlacer の target_layer_path が正しく設定されているか確認してください。"
		lbl_none.mouse_filter = Control.MOUSE_FILTER_PASS
		list.add_child(lbl_none)
		return

	# TileSet を取得
	var ts: TileSet = layer.tile_set
	if ts == null:
		var lbl_no_ts := Label.new()
		lbl_no_ts.text = "TileSet が設定されていません。"
		lbl_no_ts.tooltip_text = "対象 TileMapLayer に TileSet を設定してください。"
		lbl_no_ts.mouse_filter = Control.MOUSE_FILTER_PASS
		list.add_child(lbl_no_ts)
		return

	# Pattern が存在しない場合
	var count: int = ts.get_patterns_count()
	if count <= 0:
		var lbl_no_pat := Label.new()
		lbl_no_pat.text = "TileSet に Pattern が登録されていません。"
		lbl_no_pat.tooltip_text = "TileSet エディタから Terrain Pattern を登録してください。"
		lbl_no_pat.mouse_filter = Control.MOUSE_FILTER_PASS
		list.add_child(lbl_no_pat)
		return

	# 各種設定用 Dictionary
	var weights: Dictionary = _get_dict_safe(placer, "pattern_weights")
	var adj_dirs: Dictionary = _get_dict_safe(placer, "pattern_adjacent_dirs")
	var required_cells_dict: Dictionary = _get_dict_safe(placer, "pattern_required_cells")
	var min_counts: Dictionary = _get_dict_safe(placer, "pattern_min_counts")
	var max_counts: Dictionary = _get_dict_safe(placer, "pattern_max_counts")
	var reg_overrides: Dictionary = _get_dict_safe(placer, "pattern_register_used_cells_override")
	var unocc_overrides: Dictionary = _get_dict_safe(placer, "pattern_only_place_on_unoccupied_override")

	# TileSet 内の全 Pattern を列挙
	var i: int = 0
	while i < count:
		var pat: TileMapPattern = ts.get_pattern(i)
		if pat != null and not pat.is_empty():
			# 1 パターン分の行コンテナ
			var row := HBoxContainer.new()
			row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

			# 実タイルの見た目プレビュー
			var preview_tex := PatternPreviewControl.new()
			preview_tex.setup(ts, pat)
			preview_tex.size_flags_horizontal = 0
			row.add_child(preview_tex)

			# 使用セルのグリッドプレビュー
			var preview_grid := PatternGridPreviewControl.new()
			preview_grid.setup(pat)
			preview_grid.size_flags_horizontal = 0
			row.add_child(preview_grid)

			# 行の高さをプレビューに合わせて調整
			var base_h: float = 24.0
			var tex_h: float = preview_tex.preview_size.y
			var grid_h: float = preview_grid.preview_size.y
			var row_h: float = base_h
			if tex_h > row_h:
				row_h = tex_h
			if grid_h > row_h:
				row_h = grid_h
			row.custom_minimum_size = Vector2(0, row_h)

			# Pattern インデックス表示
			var lab_idx := Label.new()
			lab_idx.text = "Idx " + str(i)
			lab_idx.custom_minimum_size = Vector2(60, 0)
			lab_idx.tooltip_text = "TileSet 内での Pattern インデックス番号です。"
			lab_idx.mouse_filter = Control.MOUSE_FILTER_PASS
			row.add_child(lab_idx)

			# Pattern サイズ表示
			var size: Vector2i = pat.get_size()
			var lab_size := Label.new()
			lab_size.text = "(" + str(size.x) + "x" + str(size.y) + ")"
			lab_size.custom_minimum_size = Vector2(60, 0)
			lab_size.tooltip_text = "Pattern のセルサイズ（幅 x 高さ）です。"
			lab_size.mouse_filter = Control.MOUSE_FILTER_PASS
			row.add_child(lab_size)

			# ===== Weight SpinBox（上限 1.0 / 細かい刻み）=====
			var w_label := Label.new()
			w_label.text = "W"
			w_label.custom_minimum_size = Vector2(16, 0)
			w_label.tooltip_text = "Pattern の出現重みを表すラベルです。"
			w_label.mouse_filter = Control.MOUSE_FILTER_PASS
			row.add_child(w_label)

			var spin := SpinBox.new()
			spin.min_value = 0.0
			spin.max_value = 1.0
			spin.step = 0.001
			spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL

			var cur_w: float = 1.0
			if weights.has(i):
				var wv_any = weights[i]
				cur_w = float(wv_any)
			if cur_w < 0.0:
				cur_w = 0.0
			if cur_w > 1.0:
				cur_w = 1.0
			spin.value = cur_w
			spin.tooltip_text = "出現重み（0.0〜1.0）"
			spin.value_changed.connect(_on_weight_changed.bind(placer, i))
			row.add_child(spin)

			# 最低配置回数ラベル
			var min_label := Label.new()
			min_label.text = "Min"
			min_label.custom_minimum_size = Vector2(28, 0)
			min_label.tooltip_text = "このパターンの最低配置回数（下限）を表すラベルです。"
			min_label.mouse_filter = Control.MOUSE_FILTER_PASS
			row.add_child(min_label)

			# 最低配置回数 SpinBox
			var spin_min := SpinBox.new()
			spin_min.min_value = 0.0
			spin_min.max_value = 9999.0
			spin_min.step = 1.0
			spin_min.size_flags_horizontal = 0

			var cur_min: int = 0
			if min_counts.has(i):
				var min_any = min_counts[i]
				cur_min = int(min_any)
				if cur_min < 0:
					cur_min = 0
			spin_min.value = float(cur_min)
			spin_min.tooltip_text = "このパターンの最低配置回数（0 で下限なし）"
			spin_min.value_changed.connect(_on_min_count_changed.bind(placer, i))
			row.add_child(spin_min)

			# 最大配置回数ラベル
			var max_label := Label.new()
			max_label.text = "Max"
			max_label.custom_minimum_size = Vector2(32, 0)
			max_label.tooltip_text = "このパターンの最大配置回数（上限）を表すラベルです。"
			max_label.mouse_filter = Control.MOUSE_FILTER_PASS
			row.add_child(max_label)

			# 最大配置回数 SpinBox
			var spin_max := SpinBox.new()
			spin_max.min_value = -1.0
			spin_max.max_value = 9999.0
			spin_max.step = 1.0
			spin_max.size_flags_horizontal = 0

			var cur_max: int = -1
			if max_counts.has(i):
				var max_any = max_counts[i]
				cur_max = int(max_any)
			spin_max.value = float(cur_max)
			spin_max.tooltip_text = "このパターンの最大配置回数（-1 で無制限）"
			spin_max.value_changed.connect(_on_max_count_changed.bind(placer, i))
			row.add_child(spin_max)

			# 接地条件ラベル
			var lab_adj := Label.new()
			lab_adj.text = "Adj"
			lab_adj.custom_minimum_size = Vector2(32, 0)
			lab_adj.tooltip_text = "パターンの上下左右の縁（境界）条件を示す設定です。"
			lab_adj.mouse_filter = Control.MOUSE_FILTER_PASS
			row.add_child(lab_adj)

			# 接地条件ビットマスク
			var mask: int = 0
			if adj_dirs.has(i):
				var mv_any = adj_dirs[i]
				mask = int(mv_any)
			if mask < 0:
				mask = 0

			# 上方向接地条件
			var btn_up := CheckBox.new()
			btn_up.text = "U"
			btn_up.button_pressed = (mask & 1) != 0
			btn_up.tooltip_text = "上方向に縁（allowed=false またはマップ外）が必要"
			btn_up.toggled.connect(_on_adj_toggled.bind(placer, i, 1))
			row.add_child(btn_up)

			# 右方向接地条件
			var btn_right := CheckBox.new()
			btn_right.text = "R"
			btn_right.button_pressed = (mask & 2) != 0
			btn_right.tooltip_text = "右方向に縁が必要"
			btn_right.toggled.connect(_on_adj_toggled.bind(placer, i, 2))
			row.add_child(btn_right)

			# 下方向接地条件
			var btn_down := CheckBox.new()
			btn_down.text = "D"
			btn_down.button_pressed = (mask & 4) != 0
			btn_down.tooltip_text = "下方向に縁が必要"
			btn_down.toggled.connect(_on_adj_toggled.bind(placer, i, 4))
			row.add_child(btn_down)

			# 左方向接地条件
			var btn_left := CheckBox.new()
			btn_left.text = "L"
			btn_left.button_pressed = (mask & 8) != 0
			btn_left.tooltip_text = "左方向に縁が必要"
			btn_left.toggled.connect(_on_adj_toggled.bind(placer, i, 8))
			row.add_child(btn_left)

			# register_used_cells_to_layout オーバーライドラベル
			var reg_label := Label.new()
			reg_label.text = "Reg"
			reg_label.custom_minimum_size = Vector2(32, 0)
			reg_label.tooltip_text = "register_used_cells_to_layout のパターン別オーバーライド種別です。"
			reg_label.mouse_filter = Control.MOUSE_FILTER_PASS
			row.add_child(reg_label)

			# register_used_cells_to_layout オプション
			var reg_opt := OptionButton.new()
			reg_opt.custom_minimum_size = Vector2(90, 0)
			reg_opt.add_item("Inherit", 0)
			reg_opt.add_item("Force On", 1)
			reg_opt.add_item("Force Off", 2)
			reg_opt.tooltip_text = "register_used_cells_to_layout のパターン別オーバーライド"

			var cur_reg_mode: int = 0
			if reg_overrides.has(i):
				var reg_any = reg_overrides[i]
				cur_reg_mode = int(reg_any)
				if cur_reg_mode < 0:
					cur_reg_mode = 0
				if cur_reg_mode > 2:
					cur_reg_mode = 0
			reg_opt.selected = cur_reg_mode
			reg_opt.item_selected.connect(_on_register_override_changed.bind(placer, i))
			row.add_child(reg_opt)

			# only_place_on_unoccupied オーバーライドラベル
			var unocc_label := Label.new()
			unocc_label.text = "Unocc"
			unocc_label.custom_minimum_size = Vector2(40, 0)
			unocc_label.tooltip_text = "only_place_on_unoccupied のパターン別オーバーライド種別です。"
			unocc_label.mouse_filter = Control.MOUSE_FILTER_PASS
			row.add_child(unocc_label)

			# only_place_on_unoccupied オプション
			var unocc_opt := OptionButton.new()
			unocc_opt.custom_minimum_size = Vector2(100, 0)
			unocc_opt.add_item("Inherit", 0)
			unocc_opt.add_item("Force On", 1)
			unocc_opt.add_item("Force Off", 2)
			unocc_opt.tooltip_text = "only_place_on_unoccupied のパターン別オーバーライド"

			var cur_unocc_mode: int = 0
			if unocc_overrides.has(i):
				var unocc_any = unocc_overrides[i]
				cur_unocc_mode = int(unocc_any)
				if cur_unocc_mode < 0:
					cur_unocc_mode = 0
				if cur_unocc_mode > 2:
					cur_unocc_mode = 0
			unocc_opt.selected = cur_unocc_mode
			unocc_opt.item_selected.connect(_on_unocc_override_changed.bind(placer, i))
			row.add_child(unocc_opt)

			# 行を一覧に追加
			list.add_child(row)

			# 必須接地セルラベル
			var req_label := Label.new()
			req_label.text = "Required cells (click to toggle, pattern-local):"
			req_label.custom_minimum_size = Vector2(0, 16)
			req_label.tooltip_text = "パターン内で必ず縁に接していなければならないセルを指定します。"
			req_label.mouse_filter = Control.MOUSE_FILTER_PASS
			list.add_child(req_label)

			# 必須接地セル情報取得
			var req_arr: Array = []
			if required_cells_dict.has(i):
				var ra_any = required_cells_dict[i]
				if ra_any is Array:
					req_arr = ra_any

			# 使用セルセット作成
			var used_cells: Array[Vector2i] = pat.get_used_cells()
			var used_set: Dictionary = {}
			var ui2: int = 0
			while ui2 < used_cells.size():
				var u: Vector2i = used_cells[ui2]
				used_set[u] = true
				ui2 += 1

			# 必須接地セル指定用グリッド
			var grid := GridContainer.new()
			grid.columns = size.x
			grid.custom_minimum_size = Vector2(float(size.x) * 16.0, float(size.y) * 16.0)
			grid.tooltip_text = "各セルボタンをクリックして必須接地セルかどうかを切り替えます。"

			var gy: int = 0
			while gy < size.y:
				var gx: int = 0
				while gx < size.x:
					var cell_pos := Vector2i(gx, gy)
					var btn := Button.new()
					btn.toggle_mode = true
					btn.focus_mode = Control.FOCUS_NONE
					btn.custom_minimum_size = Vector2(16, 16)
					btn.text = ""
					btn.tooltip_text = "x=" + str(gx) + ", y=" + str(gy) + " を必須接地セルにする"

					var is_required: bool = _array_has_vec2i(req_arr, cell_pos)
					var is_used: bool = used_set.has(cell_pos)

					btn.button_pressed = is_required
					_update_required_button_color(btn, is_required, is_used)

					btn.toggled.connect(_on_required_cell_toggled.bind(placer, i, cell_pos, is_used, btn))
					grid.add_child(btn)

					gx += 1
				gy += 1

			# 必須接地セルグリッドを追加
			list.add_child(grid)

			# パターンごとの区切り線
			var sep := HSeparator.new()
			sep.custom_minimum_size = Vector2(0, 4)
			list.add_child(sep)

		i += 1

# ===== コールバック =====
func _on_weight_changed(value: float, placer: Object, pat_index: int) -> void:
	if not is_instance_valid(placer):
		return
	if value < 0.0:
		value = 0.0
	if value > 1.0:
		value = 1.0

	var d: Dictionary = _get_dict_safe(placer, "pattern_weights")
	d[pat_index] = value
	placer.set("pattern_weights", d)

func _on_min_count_changed(value: float, placer: Object, pat_index: int) -> void:
	if not is_instance_valid(placer):
		return

	var ival: int = int(round(value))
	if ival < 0:
		ival = 0

	var d: Dictionary = _get_dict_safe(placer, "pattern_min_counts")
	d[pat_index] = ival
	placer.set("pattern_min_counts", d)

func _on_max_count_changed(value: float, placer: Object, pat_index: int) -> void:
	if not is_instance_valid(placer):
		return

	var ival: int = int(round(value))
	var d: Dictionary = _get_dict_safe(placer, "pattern_max_counts")

	if ival < 0:
		if d.has(pat_index):
			d.erase(pat_index)
	else:
		d[pat_index] = ival

	placer.set("pattern_max_counts", d)

func _on_adj_toggled(pressed: bool, placer: Object, pat_index: int, bit: int) -> void:
	if not is_instance_valid(placer):
		return

	var d: Dictionary = _get_dict_safe(placer, "pattern_adjacent_dirs")
	var mask: int = 0
	if d.has(pat_index):
		var mv_any = d[pat_index]
		mask = int(mv_any)

	if pressed:
		mask = mask | bit
	else:
		mask = mask & (~bit)

	if mask < 0:
		mask = 0

	d[pat_index] = mask
	placer.set("pattern_adjacent_dirs", d)

func _on_register_override_changed(selected_index: int, placer: Object, pat_index: int) -> void:
	if not is_instance_valid(placer):
		return

	var d: Dictionary = _get_dict_safe(placer, "pattern_register_used_cells_override")
	if selected_index == 0:
		if d.has(pat_index):
			d.erase(pat_index)
	else:
		d[pat_index] = selected_index

	placer.set("pattern_register_used_cells_override", d)

func _on_unocc_override_changed(selected_index: int, placer: Object, pat_index: int) -> void:
	if not is_instance_valid(placer):
		return

	var d: Dictionary = _get_dict_safe(placer, "pattern_only_place_on_unoccupied_override")
	if selected_index == 0:
		if d.has(pat_index):
			d.erase(pat_index)
	else:
		d[pat_index] = selected_index

	placer.set("pattern_only_place_on_unoccupied_override", d)

func _on_required_cell_toggled(pressed: bool, placer: Object, pat_index: int, cell_pos: Vector2i, is_used: bool, btn: Button) -> void:
	if not is_instance_valid(placer):
		return

	var d: Dictionary = _get_dict_safe(placer, "pattern_required_cells")
	var arr: Array = []
	if d.has(pat_index):
		var a_any = d[pat_index]
		if a_any is Array:
			arr = a_any

	if pressed:
		if not _array_has_vec2i(arr, cell_pos):
			arr.append(cell_pos)
	else:
		arr = _array_remove_vec2i(arr, cell_pos)

	d[pat_index] = arr
	placer.set("pattern_required_cells", d)

	_update_required_button_color(btn, pressed, is_used)
