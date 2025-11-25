@tool
class_name TerrainAtlasPatternPlacer
extends Node2D

# File: addons/terrain_pattern_tools/terrain_atlas_pattern_placer.gd
# Godot 4.4 / GDScript 2.0
# レイアウト（grid）を RoomLayoutGenerator などから取得し、
# 指定の TileMapLayer 1 枚へ
#   - TERRAIN: set_cells_terrain_connect()
#   - PATTERN: set_pattern()
# で貼り付ける。
#
# - target_kind = WALLS なら CELL_WALL セルに対して貼り付け
#   target_kind = FLOORS なら CELL_FLOOR + CELL_DOOR セルに貼り付け
# - auto_update_on_layout_signal = true のとき、
#   layout_node(layout_updated/generation_finished) と自動連動
# - 配置後、実際に使用したセル一覧を layout_node.register_used_cells(cells)
#   に渡してレイアウト側に保存させる（※register_used_cells_to_layout=true のときのみ）
# - only_place_on_unoccupied:
#     true なら「レイアウト上で未使用」かつ「TileMapLayer にも何も置かれていないセル」
#     のみを対象に配置する。
#   （レイアウト側の get_free_cells(kind) ＋ TileMapLayer の空セル判定で決定）
#
# - pattern_register_used_cells_override[pattern_index]:
#     0 = Inherit（グローバル register_used_cells_to_layout を継承）
#     1 = Force On（グローバルが false でも必ず register_used_cells 対象に含める）
#     2 = Force Off（グローバルが true でも必ず register_used_cells 対象から外す）
#
# - pattern_only_place_on_unoccupied_override[pattern_index]:
#     0 = Inherit（グローバル only_place_on_unoccupied を継承）
#     1 = Force On（このパターンだけ「未使用セルのみ」に貼る）
#     2 = Force Off（このパターンだけ「未使用制限なし」で貼る）
#
#   ※パターンのうち 1 つでも Force On が含まれていれば、
#     グローバル only_place_on_unoccupied が false でも layout.get_free_cells を使用します。
#
# - execution_order によって、同じ layout_node を参照している複数 TilePlacer の
#   実行順序を厳密に制御する。
#   （小さい値から順に place_now() 実行。値が同じ場合は instance_id 昇順）
#
# - run_on_editor_button:
#     true にすると、押下時に layout_node.generate_now() があればそれを呼び、
#     その後同じ layout_node を見る全 TilePlacer を execution_order 順に一括で place_now()
#     する。generate_now が無い場合は自分の place_now() だけを実行。

# 配置処理完了を通知するシグナル
signal placement_finished(success: bool)

# レイアウトグリッド上のセル種別
const CELL_WALL: int = 0
const CELL_FLOOR: int = 1
const CELL_DOOR: int = 2

# 対象セル種別（壁・床）
enum TargetKind { WALLS, FLOORS }
# 配置方法（Terrain か Pattern）
enum PlacementType { TERRAIN, PATTERN }

# ===== 静的管理：layout ごとの TilePlacer 一覧とバッチ更新状態 =====

# layout ノードごとに紐づく TerrainAtlasPatternPlacer の配列
static var _layout_to_placers: Dictionary = {}
# layout ごとのバッチ更新要求フラグ
static var _layout_pending: Dictionary = {}

# run_on_editor_button による手動 generate_now 実行中フラグ
static var _layout_manual_generation_in_progress: Dictionary = {}
# 手動 generate_now に対して一度でも _run_all_for_layout を回したかどうか
static var _layout_manual_generation_handled: Dictionary = {}

# 指定 layout に紐づく静的状態を一括で掃除
static func _clear_all_for_layout(layout: Node) -> void:
	if layout == null:
		return
	if _layout_to_placers.has(layout):
		_layout_to_placers.erase(layout)
	if _layout_pending.has(layout):
		_layout_pending.erase(layout)
	if _layout_manual_generation_in_progress.has(layout):
		_layout_manual_generation_in_progress.erase(layout)
	if _layout_manual_generation_handled.has(layout):
		_layout_manual_generation_handled.erase(layout)

# layout に属する placer を登録
static func _register_placer_for_layout(layout: Node, placer: TerrainAtlasPatternPlacer) -> void:
	if layout == null:
		return
	if placer == null:
		return
	if not is_instance_valid(layout):
		return
	if not is_instance_valid(placer):
		return
	if not _layout_to_placers.has(layout):
		_layout_to_placers[layout] = []
	var arr: Array = _layout_to_placers[layout]
	if not arr.has(placer):
		arr.append(placer)
	_layout_to_placers[layout] = arr
	print("[TerrainAtlasPatternPlacer] _register_placer_for_layout: layout=", str(layout.name), " placer=", str(placer.name))

# layout から placer を解除
static func _unregister_placer_for_layout(layout: Node, placer: TerrainAtlasPatternPlacer) -> void:
	if layout == null:
		return
	if not _layout_to_placers.has(layout):
		return
	var arr: Array = _layout_to_placers[layout]
	if arr.has(placer):
		arr.erase(placer)
		_layout_to_placers[layout] = arr
		print("[TerrainAtlasPatternPlacer] _unregister_placer_for_layout: layout=", str(layout.name), " placer=", str(placer.name))
	# 最後の placer が消えたら、その layout に紐づく静的情報を全て破棄
	if arr.is_empty():
		_clear_all_for_layout(layout)

# execution_order → instance_id の順でソートする比較関数
static func _sort_by_order(a: TerrainAtlasPatternPlacer, b: TerrainAtlasPatternPlacer) -> bool:
	if a.execution_order == b.execution_order:
		if int(a.get_instance_id()) < int(b.get_instance_id()):
			return true
		return false
	if a.execution_order < b.execution_order:
		return true
	return false

# layout に紐づく全 placer をソート順に実行
static func _run_all_for_layout(layout: Node) -> void:
	if layout == null:
		return
	if not is_instance_valid(layout):
		return
	if not layout.is_inside_tree():
		return
	if not _layout_to_placers.has(layout):
		return

	var arr_any: Array = _layout_to_placers[layout]
	var arr: Array = []
	var i: int = 0
	while i < arr_any.size():
		var p_any: Variant = arr_any[i]
		if p_any is TerrainAtlasPatternPlacer:
			var p: TerrainAtlasPatternPlacer = p_any
			if is_instance_valid(p):
				if p.is_inside_tree():
					arr.append(p)
		i += 1

	if arr.is_empty():
		return

	arr.sort_custom(Callable(TerrainAtlasPatternPlacer, "_sort_by_order"))
	print("[TerrainAtlasPatternPlacer] _run_all_for_layout: layout=", str(layout.name), " placers_count=", str(arr.size()))

	var j: int = 0
	while j < arr.size():
		var placer: TerrainAtlasPatternPlacer = arr[j]
		if is_instance_valid(placer) and placer.is_inside_tree():
			if placer.auto_update_on_layout_signal:
				print("[TerrainAtlasPatternPlacer] _run_all_for_layout: calling place_now on ", str(placer.name))
				var ok: bool = placer.place_now()
				placer.emit_signal("placement_finished", ok)
			else:
				print("[TerrainAtlasPatternPlacer] _run_all_for_layout: auto_update_on_layout_signal=false, skip placer=", str(placer.name))
		j += 1

# layout 単位のバッチ更新要求
static func _request_batched_update(layout: Node, runner: TerrainAtlasPatternPlacer) -> void:
	if layout == null:
		return
	if runner == null:
		return
	if not is_instance_valid(layout):
		return
	if not is_instance_valid(runner):
		return
	if not runner.is_inside_tree():
		return
	if not _layout_pending.has(layout):
		_layout_pending[layout] = false
	var pending: bool = _layout_pending[layout]
	if pending:
		print("[TerrainAtlasPatternPlacer] _request_batched_update: already pending for layout=", str(layout.name))
		return
	_layout_pending[layout] = true
	print("[TerrainAtlasPatternPlacer] _request_batched_update: layout=", str(layout.name), " runner=", str(runner.name))
	# runner がまだツリー内に居る場合のみ起動
	if runner.is_inside_tree():
		runner._run_batched_update_for_layout(layout)

# ===== レイアウト参照 =====

## レイアウト生成ノード(RoomLayoutGenerator など)へのパス
@export var layout_node: NodePath:
	set = _set_layout_node
var _layout_ref: Node = null
var _grid: Array = []

# ===== 対象レイヤ =====

## 配置対象の TileMapLayer へのパス
@export var target_layer_path: NodePath
var _target_layer: TileMapLayer = null

# ===== 実行制御 =====

## 配置前に対象 TileMapLayer を clear() するかどうか
@export var clear_before_place: bool = true

## 使用したセル一覧を layout_node.register_used_cells() に登録するか
@export var register_used_cells_to_layout: bool = true
## true のとき、レイアウト上も TileMapLayer 上も未使用のセルのみを配置対象にする
@export var only_place_on_unoccupied: bool = false

## エディタのボタンから generate/place を実行するためのトリガー用フラグ
@export var run_on_editor_button: bool = false:
	set = _set_run_on_editor_button

# run_on_editor_button が true にされたときの処理（押された瞬間だけ動く）
func _set_run_on_editor_button(v: bool) -> void:
	# false のときは何もしない（リセットだけを許可）
	if not v:
		return

	print("[TerrainAtlasPatternPlacer] run_on_editor_button pressed on node=", str(name))

	var layout_used: bool = false
	if layout_node != NodePath(""):
		var layout: Node = get_node_or_null(layout_node)
		if layout != null:
			print("[TerrainAtlasPatternPlacer] run_on_editor_button: found layout node=", str(layout.name))
			if layout.has_method("generate_now"):
				print("[TerrainAtlasPatternPlacer] run_on_editor_button: calling layout.generate_now() (manual mode)")
				TerrainAtlasPatternPlacer._layout_manual_generation_in_progress[layout] = true
				TerrainAtlasPatternPlacer._layout_manual_generation_handled[layout] = false
				layout.call("generate_now")
				layout_used = true
	if not layout_used:
		print("[TerrainAtlasPatternPlacer] run_on_editor_button: layout.generate_now() not used, calling place_now() directly on node=", str(name))
		var ok: bool = place_now()
		emit_signal("placement_finished", ok)

	# ボタンフラグのリセットは別メソッドに deferred で飛ばす
	call_deferred("_reset_run_on_editor_button_flag")

# run_on_editor_button をインスペクタ上で押したあとのリセット処理
func _reset_run_on_editor_button_flag() -> void:
	# ここで false をセットしても setter は v==false なので何もせず終わる
	if run_on_editor_button:
		run_on_editor_button = false

# ===== 自動連動設定 =====

## layout_updated / generation_finished シグナルと自動連動するかどうか
@export var auto_update_on_layout_signal: bool = true
## true のとき、エディタ実行時のみ自動更新し、ゲーム実行中は無効化する
@export var auto_update_in_editor_only: bool = true
## バッチ更新までに待つフレーム数（0 なら「少なくとも 1 フレーム」は待つ）
@export var auto_update_debounce_frames: int = 1

# ===== ログ =====

## ログ出力を有効にするか
@export var log_enabled: bool = true
## ログの詳細度（大きいほど詳細なログを出す）
@export var log_verbosity: int = 1

# ===== 貼り付けモード =====

## レイアウト上のどのセル種別を対象にするか（WALLS/FLOORS）
@export var target_kind: TargetKind = TargetKind.WALLS
## TERRAIN で Terrain を塗るか、PATTERN で TileMapPattern を貼るか
@export var placement_type: PlacementType = PlacementType.TERRAIN

# --- TERRAIN 用 ---

## 使用する Terrain セットのインデックス
@export var terrain_set_index: int = 0
## 使用する Terrain セット内の Terrain インデックス
@export var terrain_index: int = 0

# --- PATTERN 用 ---

## 使用する TileMapPattern のインデックス一覧（空なら有効な全パターンを対象）
@export var pattern_indices: PackedInt32Array = PackedInt32Array()
## true のとき、パターン同士が重ならないように配置する
@export var pattern_avoid_overlap: bool = true
## ターゲットセルに対するパターンの目標カバレッジ（0.0〜1.0）
@export var pattern_coverage_ratio: float = 0.1

## パターンごとの出現重み（pattern_index → weight）
@export var pattern_weights: Dictionary = {}
## パターンごとの接地方向ビットマスク（1=U, 2=R, 4=D, 8=L）
@export var pattern_adjacent_dirs: Dictionary = {}
## パターンごとの必須接地セル（pattern 内セル座標の配列など）
@export var pattern_required_cells: Dictionary = {}
## パターンごとの最低配置回数
@export var pattern_min_counts: Dictionary = {}
## パターンごとの最大配置回数（-1 で無制限）
@export var pattern_max_counts: Dictionary = {}

## register_used_cells_to_layout のパターン別オーバーライド設定
@export var pattern_register_used_cells_override: Dictionary = {}
## only_place_on_unoccupied のパターン別オーバーライド設定
@export var pattern_only_place_on_unoccupied_override: Dictionary = {}

# --- 書き込み順序指定 ---

## 同じ layout_node を使う複数 Placer 間での実行順序（小さいほど先に実行）
@export var execution_order: int = 0

# ===== 内部: 状態 =====
var _pending_auto_update_local: bool = false
var _last_used_cells: Array[Vector2i] = []
var _last_pattern_force_register: bool = false

# ===== ログ関連 =====

# エディタかランタイムかのコンテキスト文字列
func _ctx() -> String:
	if Engine.is_editor_hint():
		return "[EDITOR]"
	return "[RUNTIME]"

# ログ出力（レベル制御付き）
func _log(level: int, msg: String) -> void:
	if not log_enabled:
		return
	if level > log_verbosity:
		return
	print(_ctx() + " " + msg)

# 警告ログ出力
func _warn(msg: String) -> void:
	if not log_enabled:
		return
	push_warning(_ctx() + " WARN: " + msg)

# エラーログ出力
func _err(msg: String) -> void:
	push_error(_ctx() + " ERROR: " + msg)
	printerr(_ctx() + " ERROR: " + msg)

# ===== ライフサイクル =====

func _enter_tree() -> void:
	_connect_to_layout()

func _exit_tree() -> void:
	_disconnect_from_layout()
	_pending_auto_update_local = false

# ===== layout_node セッター（再接続）=====
func _set_layout_node(p: NodePath) -> void:
	layout_node = p
	_disconnect_from_layout()
	_connect_to_layout()

# ===== レイアウトシグナル接続／切断 =====
func _connect_to_layout() -> void:
	_layout_ref = null
	if layout_node == NodePath(""):
		return
	var ref: Node = get_node_or_null(layout_node)
	if ref == null:
		return
	_layout_ref = ref
	TerrainAtlasPatternPlacer._register_placer_for_layout(_layout_ref, self)
	if _layout_ref.has_signal("layout_updated"):
		if not _layout_ref.is_connected("layout_updated", Callable(self, "_on_layout_updated")):
			_layout_ref.connect("layout_updated", Callable(self, "_on_layout_updated"))
	if _layout_ref.has_signal("generation_finished"):
		if not _layout_ref.is_connected("generation_finished", Callable(self, "_on_layout_generation_finished")):
			_layout_ref.connect("generation_finished", Callable(self, "_on_layout_generation_finished"))

func _disconnect_from_layout() -> void:
	if _layout_ref != null:
		if is_instance_valid(_layout_ref):
			TerrainAtlasPatternPlacer._unregister_placer_for_layout(_layout_ref, self)
			if _layout_ref.has_signal("layout_updated"):
				if _layout_ref.is_connected("layout_updated", Callable(self, "_on_layout_updated")):
					_layout_ref.disconnect("layout_updated", Callable(self, "_on_layout_updated"))
			if _layout_ref.has_signal("generation_finished"):
				if _layout_ref.is_connected("generation_finished", Callable(self, "_on_layout_generation_finished")):
					_layout_ref.disconnect("generation_finished", Callable(self, "_on_layout_generation_finished"))
	_layout_ref = null

# ===== 自動連動: シグナル受信 =====

# layout_updated シグナル受信時の処理
func _on_layout_updated(grid: Array, rooms: Array, centers: Array) -> void:
	print("[TerrainAtlasPatternPlacer] _on_layout_updated: node=", str(name), " auto_update_on_layout_signal=", str(auto_update_on_layout_signal))
	if _layout_ref != null:
		var in_manual: bool = bool(TerrainAtlasPatternPlacer._layout_manual_generation_in_progress.get(_layout_ref, false))
		if in_manual:
			print("[TerrainAtlasPatternPlacer] _on_layout_updated: ignored during manual generation on node=", str(name))
			return
	if not auto_update_on_layout_signal:
		return
	if auto_update_in_editor_only and not Engine.is_editor_hint():
		return
	_schedule_auto_update()

# generation_finished シグナル受信時の処理
func _on_layout_generation_finished(success: bool) -> void:
	print("[TerrainAtlasPatternPlacer] _on_layout_generation_finished: node=", str(name), " success=", str(success))
	if _layout_ref != null:
		var layout: Node = _layout_ref
		if not is_instance_valid(layout):
			return
		var handled_any: bool = bool(TerrainAtlasPatternPlacer._layout_manual_generation_handled.get(layout, false))
		var in_manual: bool = bool(TerrainAtlasPatternPlacer._layout_manual_generation_in_progress.get(layout, false))

		# 手動生成モード（run_on_editor_button やランタイム seed 変更など）
		if in_manual:
			if not handled_any:
				print("[TerrainAtlasPatternPlacer] _on_layout_generation_finished: manual generation OK, running all placers once for layout=", str(layout.name))
				TerrainAtlasPatternPlacer._layout_manual_generation_handled[layout] = true
				TerrainAtlasPatternPlacer._layout_manual_generation_in_progress[layout] = false
				TerrainAtlasPatternPlacer._layout_pending[layout] = false
				TerrainAtlasPatternPlacer._run_all_for_layout(layout)
			else:
				print("[TerrainAtlasPatternPlacer] _on_layout_generation_finished: manual generation already handled for layout=", str(layout.name), " node=", str(name))
			return

		# 手動生成が終わった後の generation_finished は無視
		if handled_any:
			print("[TerrainAtlasPatternPlacer] _on_layout_generation_finished: ignored after manual generation handled for layout=", str(layout.name), " node=", str(name))
			return

	# 通常ケースでは generation_finished では自動更新を行わない（layout_updated のみ使用）
	# ここで何もせず終了することで、1 回の生成につき _run_all_for_layout は 1 回だけになる
	return

# 自動更新をスケジュールする（batched update 要求）
func _schedule_auto_update() -> void:
	if _layout_ref == null:
		return
	if not is_instance_valid(self):
		return
	if not is_inside_tree():
		return
	if _pending_auto_update_local:
		return
	_pending_auto_update_local = true
	print("[TerrainAtlasPatternPlacer] _schedule_auto_update: node=", str(name))
	TerrainAtlasPatternPlacer._request_batched_update(_layout_ref, self)

# layout 単位でのバッチ処理本体
func _run_batched_update_for_layout(layout: Node) -> void:
	# シーン終了中などでツリーが無効なら何もしない
	if not is_inside_tree():
		_pending_auto_update_local = false
		return
	var tree: SceneTree = get_tree()
	if tree == null:
		_pending_auto_update_local = false
		return

	# 少なくとも 1 フレームは待つ（auto_update_debounce_frames が 0 でも）
	var frames: int = auto_update_debounce_frames
	if frames < 1:
		frames = 1
	while frames > 0:
		await tree.process_frame
		if not is_inside_tree():
			_pending_auto_update_local = false
			return
		if get_tree() == null:
			_pending_auto_update_local = false
			return
		frames -= 1

	_pending_auto_update_local = false
	if layout == null:
		return
	if not is_instance_valid(layout):
		return
	if not TerrainAtlasPatternPlacer._layout_pending.has(layout):
		return
	TerrainAtlasPatternPlacer._layout_pending[layout] = false
	if not layout.is_inside_tree():
		return
	print("[TerrainAtlasPatternPlacer] _run_batched_update_for_layout: node=", str(name), " layout=", str(layout.name))
	TerrainAtlasPatternPlacer._run_all_for_layout(layout)

# ===== レイアウト・レイヤ解決 =====

# layout_node から grid（2次元配列）を取得する
func _resolve_layout() -> bool:
	_grid = []
	if layout_node == NodePath(""):
		_err("layout_node is empty")
		return false
	var ref: Node = get_node_or_null(layout_node)
	if ref == null:
		_err("layout node not found: " + str(layout_node))
		return false
	if not ref.has_method("get_grid_copy"):
		_err("layout node has no get_grid_copy()")
		return false
	var g: Variant = ref.call("get_grid_copy")
	if not (g is Array):
		_err("get_grid_copy() did not return Array")
		return false
	_grid = g
	if _grid.is_empty():
		_err("layout grid is empty")
		return false
	return true

# target_layer_path から TileMapLayer を取得する
func _resolve_layer() -> bool:
	_target_layer = null
	if target_layer_path == NodePath(""):
		_err("target_layer_path is empty")
		return false
	var layer_any: Variant = get_node_or_null(target_layer_path)
	if not (layer_any is TileMapLayer):
		_err("target TileMapLayer not found: " + str(target_layer_path))
		return false
	_target_layer = layer_any
	if _target_layer.tile_set == null:
		_err("target layer has no TileSet")
		return false
	return true

# ===== メイン公開 API =====

# 即時配置を行うメインエントリポイント
func place_now() -> bool:
	print("[TerrainAtlasPatternPlacer] place_now() ENTER: node=", str(name))
	if not _resolve_layout():
		return false
	if not _resolve_layer():
		return false

	_last_used_cells.clear()
	_last_pattern_force_register = false

	if clear_before_place:
		_target_layer.clear()

	var all_cells: Array[Vector2i] = _collect_cells(target_kind)
	if all_cells.is_empty():
		_log(1, "place_now: no target cells; nothing to place (all_cells empty) node=" + str(name))
		return true

	var needs_free: bool = only_place_on_unoccupied
	_ensure_pattern_dicts_initialized()

	# パターン別 override に Force On があれば、グローバルが false でも free_cells を使う
	if not needs_free:
		for k in pattern_only_place_on_unoccupied_override.keys():
			var mode_any: Variant = pattern_only_place_on_unoccupied_override[k]
			var mode: int = int(mode_any)
			if mode == 1:
				needs_free = true
				break

	var free_cells: Array[Vector2i] = all_cells

	if needs_free:
		if layout_node == NodePath(""):
			_err("only_place_on_unoccupied もしくは pattern_only_place_on_unoccupied_override=Force On が指定されていますが layout_node が空です")
			return false
		var ref: Node = get_node_or_null(layout_node)
		if ref == null:
			_err("only_place_on_unoccupied 用の layout_node が見つかりません")
			return false
		if not ref.has_method("get_free_cells"):
			_err("layout_node に get_free_cells(kind:int) がありません")
			return false
		var kind_int: int = CELL_WALL
		if target_kind == TargetKind.FLOORS:
			kind_int = CELL_FLOOR
		var base_cells_any: Variant = ref.call("get_free_cells", kind_int)
		if not (base_cells_any is Array):
			_err("get_free_cells() が Array を返していません")
			return false
		var base_cells: Array = base_cells_any
		free_cells = []
		var i_free: int = 0
		while i_free < base_cells.size():
			var pos_any: Variant = base_cells[i_free]
			if pos_any is Vector2i:
				var pos: Vector2i = pos_any
				# TileMapLayer 側にも既にタイルが置かれていないか確認
				var src: int = _target_layer.get_cell_source_id(pos)
				if src == -1:
					free_cells.append(pos)
			i_free += 1
		if free_cells.is_empty():
			_log(1, "place_now: free_cells is empty; nothing to place (needs_free=true) node=" + str(name))
			return true

	var cells_base: Array[Vector2i] = free_cells
	if not needs_free:
		cells_base = all_cells

	if placement_type == PlacementType.TERRAIN:
		var ok_t: bool = _place_via_terrain(_target_layer, cells_base, terrain_set_index, terrain_index)
		if ok_t:
			_push_used_cells_to_layout()
		return ok_t

	# PATTERN モード
	var ok_p: bool = _place_via_patterns(
		_target_layer,
		cells_base,
		all_cells,
		pattern_indices,
		pattern_avoid_overlap,
		pattern_coverage_ratio,
		target_kind,
		only_place_on_unoccupied,
		free_cells
	)

	if ok_p:
		_push_used_cells_to_layout(_last_pattern_force_register)

	return ok_p

# ===== 使用セル書き戻し =====

# _last_used_cells を layout_node.register_used_cells() に送る
func _push_used_cells_to_layout(force_push: bool = false) -> void:
	if not register_used_cells_to_layout and not force_push:
		print("[TerrainAtlasPatternPlacer] _push_used_cells_to_layout: register_used_cells_to_layout=false and force_push=false, skip on node=", str(name))
		return
	if layout_node == NodePath(""):
		return
	var ref: Node = get_node_or_null(layout_node)
	if ref == null:
		return
	if not ref.has_method("register_used_cells"):
		return
	if _last_used_cells.is_empty():
		print("[TerrainAtlasPatternPlacer] _push_used_cells_to_layout: _last_used_cells is empty on node=", str(name))
		return
	print("[TerrainAtlasPatternPlacer] _push_used_cells_to_layout: calling layout.register_used_cells() on node=", str(name), " count=", str(_last_used_cells.size()), " force_push=", str(force_push))
	ref.call("register_used_cells", _last_used_cells)

# ===== セル収集（レイアウト grid ベース） =====

# レイアウト grid から WALL/FLOORS の対象セル一覧を抽出
func _collect_cells(kind: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var h: int = _grid.size()
	if h <= 0:
		return out
	var w: int = (_grid[0] as Array).size()
	var y: int = 0
	while y < h:
		var row_any: Variant = _grid[y]
		if not (row_any is Array):
			y += 1
			continue
		var row: Array = row_any
		var x: int = 0
		while x < w:
			var v_any: Variant = row[x]
			if v_any is int:
				var v: int = v_any
				if kind == TargetKind.WALLS:
					if v == CELL_WALL:
						out.append(Vector2i(x, y))
				else:
					if v == CELL_FLOOR or v == CELL_DOOR:
						out.append(Vector2i(x, y))
			x += 1
		y += 1
	return out

# ===== TERRAIN モード =====

# TileMapLayer に Terrain を一括配置する
func _place_via_terrain(layer: TileMapLayer, cells: Array[Vector2i], set_idx: int, terr_idx: int) -> bool:
	if layer == null:
		return false
	var ts: TileSet = layer.tile_set
	if ts == null:
		_err("tile_set is null")
		return false
	var set_count: int = ts.get_terrain_sets_count()
	if set_idx < 0 or set_idx >= set_count:
		_err("terrain_set_index out of range: " + str(set_idx) + " / " + str(set_count))
		return false
	var terr_count: int = ts.get_terrains_count(set_idx)
	if terr_idx < 0 or terr_idx >= terr_count:
		_err("terrain_index out of range: " + str(terr_idx) + " / " + str(terr_count))
		return false
	layer.set_cells_terrain_connect(cells, set_idx, terr_idx)
	_last_used_cells = cells.duplicate()
	_log(1, "_place_via_terrain: placed " + str(cells.size()) + " cells on node=" + str(name))
	print("[TerrainAtlasPatternPlacer] _place_via_terrain: placed ", str(cells.size()), " cells on node=", str(name))
	return true

# ===== Pattern 用辞書ヘルパー =====

# pattern_* 系 Dictionary の null/型チェックと初期化
func _ensure_pattern_dicts_initialized() -> void:
	if pattern_weights == null or typeof(pattern_weights) != TYPE_DICTIONARY:
		pattern_weights = {}
	if pattern_adjacent_dirs == null or typeof(pattern_adjacent_dirs) != TYPE_DICTIONARY:
		pattern_adjacent_dirs = {}
	if pattern_required_cells == null or typeof(pattern_required_cells) != TYPE_DICTIONARY:
		pattern_required_cells = {}
	if pattern_min_counts == null or typeof(pattern_min_counts) != TYPE_DICTIONARY:
		pattern_min_counts = {}
	if pattern_max_counts == null or typeof(pattern_max_counts) != TYPE_DICTIONARY:
		pattern_max_counts = {}
	if pattern_register_used_cells_override == null or typeof(pattern_register_used_cells_override) != TYPE_DICTIONARY:
		pattern_register_used_cells_override = {}
	if pattern_only_place_on_unoccupied_override == null or typeof(pattern_only_place_on_unoccupied_override) != TYPE_DICTIONARY:
		pattern_only_place_on_unoccupied_override = {}

# パターンの出現重みを取得（未設定なら 1.0）
func _get_pattern_weight(pat_index: int) -> float:
	_ensure_pattern_dicts_initialized()
	var d: Dictionary = pattern_weights
	if d.has(pat_index):
		var v: Variant = d[pat_index]
		var w: float = float(v)
		if w < 0.0:
			w = 0.0
		return w
	return 1.0

# パターンの接地方向ビットマスクを取得
func _get_pattern_adj_mask(pat_index: int) -> int:
	_ensure_pattern_dicts_initialized()
	var d: Dictionary = pattern_adjacent_dirs
	if d.has(pat_index):
		var v: Variant = d[pat_index]
		var m: int = int(v)
		if m < 0:
			m = 0
		return m
	return 0

# パターンの最低配置回数を取得
func _get_pattern_min_count(pat_index: int) -> int:
	_ensure_pattern_dicts_initialized()
	var d: Dictionary = pattern_min_counts
	if d.has(pat_index):
		var v: Variant = d[pat_index]
		var m: int = int(v)
		if m < 0:
			m = 0
		return m
	return 0

# パターンの最大配置回数を取得（-1 で制限なし）
func _get_pattern_max_count(pat_index: int) -> int:
	_ensure_pattern_dicts_initialized()
	var d: Dictionary = pattern_max_counts
	if d.has(pat_index):
		var v: Variant = d[pat_index]
		var m: int = int(v)
		if m < 0:
			return -1
		return m
	return -1

# register_used_cells_to_layout のパターン別オーバーライド取得
func _get_pattern_register_override(pat_index: int) -> int:
	_ensure_pattern_dicts_initialized()
	if pattern_register_used_cells_override.has(pat_index):
		var v: Variant = pattern_register_used_cells_override[pat_index]
		var m: int = int(v)
		if m < 0:
			m = 0
		if m > 2:
			m = 0
		return m
	return 0

# only_place_on_unoccupied のパターン別オーバーライド取得
func _get_pattern_only_unocc_override(pat_index: int) -> int:
	_ensure_pattern_dicts_initialized()
	if pattern_only_place_on_unoccupied_override.has(pat_index):
		var v: Variant = pattern_only_place_on_unoccupied_override[pat_index]
		var m: int = int(v)
		if m < 0:
			m = 0
		if m > 2:
			m = 0
		return m
	return 0

# pattern_required_cells からローカルな必須セル一覧を取得
func _get_required_cells_for_pattern_index(pat_index: int, pat: TileMapPattern) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	_ensure_pattern_dicts_initialized()
	if not pattern_required_cells.has(pat_index):
		return result
	var v: Variant = pattern_required_cells[pat_index]
	var size: Vector2i = pat.get_size()
	if size.x <= 0 or size.y <= 0:
		return result

	if v is PackedInt32Array:
		var arr_pi: PackedInt32Array = v
		var i: int = 0
		while i < arr_pi.size():
			var idx: int = arr_pi[i]
			if idx >= 0:
				var ry: int = idx / size.x
				var rx: int = idx % size.x
				if rx >= 0 and rx < size.x and ry >= 0 and ry < size.y:
					result.append(Vector2i(rx, ry))
			i += 1
	elif v is Array:
		var arr: Array = v
		var j: int = 0
		while j < arr.size():
			var e: Variant = arr[j]
			if e is Vector2i:
				var rv: Vector2i = e
				if rv.x >= 0 and rv.x < size.x and rv.y >= 0 and rv.y < size.y:
					result.append(rv)
			elif e is int:
				var idx2: int = e
				var ry2: int = idx2 / size.x
				var rx2: int = idx2 % size.x
				if rx2 >= 0 and rx2 < size.x and ry2 >= 0 and ry2 < size.y:
					result.append(Vector2i(rx2, ry2))
			j += 1
	elif v is Dictionary:
		var dummy: int = 0
		dummy += 1
		dummy -= 1

	return result

# 有効なパターン群の総重みを算出
func _pattern_update_total_weight(pats_in: Array) -> float:
	var sum_w: float = 0.0
	var ii: int = 0
	while ii < pats_in.size():
		var pinfo_any: Variant = pats_in[ii]
		if pinfo_any is Dictionary:
			var pinfo: Dictionary = pinfo_any
			var wv: float = 0.0
			if pinfo.has("weight"):
				wv = float(pinfo["weight"])
			if wv > 0.0:
				var cands_any: Variant = pinfo.get("candidates", [])
				if cands_any is Array:
					var arr_c: Array = cands_any
					if not arr_c.is_empty():
						var max_count: int = -1
						if pinfo.has("max_count"):
							max_count = int(pinfo["max_count"])
						var placed_count: int = 0
						if pinfo.has("placed_count"):
							placed_count = int(pinfo["placed_count"])
						var max_ok: bool = true
						if max_count >= 0 and placed_count >= max_count:
							max_ok = false
						if max_ok:
							sum_w += wv
		ii += 1
	return sum_w

# まだ min_count を満たしていないパターンが存在するかどうか
func _has_unfulfilled_min_patterns(pats_in: Array) -> bool:
	var ii: int = 0
	while ii < pats_in.size():
		var pinfo_any: Variant = pats_in[ii]
		if pinfo_any is Dictionary:
			var pinfo: Dictionary = pinfo_any
			var min_count: int = 0
			if pinfo.has("min_count"):
				min_count = int(pinfo["min_count"])
			if min_count > 0:
				var placed_count: int = 0
				if pinfo.has("placed_count"):
					placed_count = int(pinfo["placed_count"])
				if placed_count < min_count:
					var cands_any: Variant = pinfo.get("candidates", [])
					if cands_any is Array:
						var arr_c: Array = cands_any
						if not arr_c.is_empty():
							var max_count: int = -1
							if pinfo.has("max_count"):
								max_count = int(pinfo["max_count"])
							var max_ok: bool = true
							if max_count >= 0 and placed_count >= max_count:
								max_ok = false
							if max_ok:
								return true
		ii += 1
	return false

# パターンの中から重み付きランダムでインデックスを 1 つ選ぶ
func _pattern_pick_index_weighted(pats_in: Array, sum_w: float) -> int:
	var dummy_sum_w: float = sum_w
	dummy_sum_w = dummy_sum_w

	var ii: int = 0
	var has_min_priority: bool = false

	# まずは min_count を満たしていないパターンがあるかチェック
	while ii < pats_in.size():
		var pinfo_any: Variant = pats_in[ii]
		if pinfo_any is Dictionary:
			var pinfo: Dictionary = pinfo_any
			var wv: float = 0.0
			if pinfo.has("weight"):
				wv = float(pinfo["weight"])
			if wv > 0.0:
				var cands_any: Variant = pinfo.get("candidates", [])
				if cands_any is Array:
					var arr_c: Array = cands_any
					if not arr_c.is_empty():
						var max_count: int = -1
						if pinfo.has("max_count"):
							max_count = int(pinfo["max_count"])
						var placed_count: int = 0
						if pinfo.has("placed_count"):
							placed_count = int(pinfo["placed_count"])
						var max_ok: bool = true
						if max_count >= 0 and placed_count >= max_count:
							max_ok = false
						if max_ok:
							var min_count: int = 0
							if pinfo.has("min_count"):
								min_count = int(pinfo["min_count"])
							if min_count > 0 and placed_count < min_count:
								has_min_priority = true
								break
		ii += 1

	# min_count 優先モード
	if has_min_priority:
		var sum_min: float = 0.0
		ii = 0
		while ii < pats_in.size():
			var pinfo_any2: Variant = pats_in[ii]
			if pinfo_any2 is Dictionary:
				var pinfo2: Dictionary = pinfo_any2
				var wv2: float = 0.0
				if pinfo2.has("weight"):
					wv2 = float(pinfo2["weight"])
				if wv2 > 0.0:
					var cands_any2: Variant = pinfo2.get("candidates", [])
					if cands_any2 is Array:
						var arr_c2: Array = cands_any2
						if not arr_c2.is_empty():
							var max_count2: int = -1
							if pinfo2.has("max_count"):
								max_count2 = int(pinfo2["max_count"])
							var placed_count2: int = 0
							if pinfo2.has("placed_count"):
								placed_count2 = int(pinfo2["placed_count"])
							var max_ok2: bool = true
							if max_count2 >= 0 and placed_count2 >= max_count2:
								max_ok2 = false
							if max_ok2:
								var min_count2: int = 0
								if pinfo2.has("min_count"):
									min_count2 = int(pinfo2["min_count"])
								if min_count2 > 0 and placed_count2 < min_count2:
									sum_min += wv2
			ii += 1

		if sum_min <= 0.0:
			return -1

		var r_min: float = randf() * sum_min
		var acc_min: float = 0.0
		ii = 0
		while ii < pats_in.size():
			var pinfo_any3: Variant = pats_in[ii]
			if pinfo_any3 is Dictionary:
				var pinfo3: Dictionary = pinfo_any3
				var wv3: float = 0.0
				if pinfo3.has("weight"):
					wv3 = float(pinfo3["weight"])
				if wv3 > 0.0:
					var cands_any3: Variant = pinfo3.get("candidates", [])
					if cands_any3 is Array:
						var arr_c3: Array = cands_any3
						if not arr_c3.is_empty():
							var max_count3: int = -1
							if pinfo3.has("max_count"):
								max_count3 = int(pinfo3["max_count"])
							var placed_count3: int = 0
							if pinfo3.has("placed_count"):
								placed_count3 = int(pinfo3["placed_count"])
							var max_ok3: bool = true
							if max_count3 >= 0 and placed_count3 >= max_count3:
								max_ok3 = false
							if max_ok3:
								var min_count3: int = 0
								if pinfo3.has("min_count"):
									min_count3 = int(pinfo3["min_count"])
								if min_count3 > 0 and placed_count3 < min_count3:
									acc_min += wv3
									if r_min <= acc_min:
										return ii
			ii += 1

		return -1

	# 通常の重み付きランダム
	var sum_all: float = 0.0
	ii = 0
	while ii < pats_in.size():
		var pinfo_any4: Variant = pats_in[ii]
		if pinfo_any4 is Dictionary:
			var pinfo4: Dictionary = pinfo_any4
			var wv4: float = 0.0
			if pinfo4.has("weight"):
				wv4 = float(pinfo4["weight"])
			if wv4 > 0.0:
				var cands_any4: Variant = pinfo4.get("candidates", [])
				if cands_any4 is Array:
					var arr_c4: Array = cands_any4
					if not arr_c4.is_empty():
						var max_count4: int = -1
						if pinfo4.has("max_count"):
							max_count4 = int(pinfo4["max_count"])
						var placed_count4: int = 0
						if pinfo4.has("placed_count"):
							placed_count4 = int(pinfo4["placed_count"])
						var max_ok4: bool = true
						if max_count4 >= 0 and placed_count4 >= max_count4:
							max_ok4 = false
						if max_ok4:
							sum_all += wv4
		ii += 1

	if sum_all <= 0.0:
		return -1

	var r: float = randf() * sum_all
	var acc: float = 0.0
	ii = 0
	while ii < pats_in.size():
		var pinfo_any5: Variant = pats_in[ii]
		if pinfo_any5 is Dictionary:
			var pinfo5: Dictionary = pinfo_any5
			var wv5: float = 0.0
			if pinfo5.has("weight"):
				wv5 = float(pinfo5["weight"])
			if wv5 > 0.0:
				var cands_any5: Variant = pinfo5.get("candidates", [])
				if cands_any5 is Array:
					var arr_c5: Array = cands_any5
					if not arr_c5.is_empty():
						var max_count5: int = -1
						if pinfo5.has("max_count"):
							max_count5 = int(pinfo5["max_count"])
						var placed_count5: int = 0
						if pinfo5.has("placed_count"):
							placed_count5 = int(pinfo5["placed_count"])
						var max_ok5: bool = true
						if max_count5 >= 0 and placed_count5 >= max_count5:
							max_ok5 = false
						if max_ok5:
							acc += wv5
							if r <= acc:
								return ii
		ii += 1

	return -1

# ===== Adj 判定用ヘルパー =====

# 指定座標が「縁」かどうか（グリッド外 or target_kind 以外なら縁）
func _is_edge_cell_for_adj(nx: int, ny: int, kind: TargetKind) -> bool:
	if _grid.is_empty():
		return false
	var h_grid: int = _grid.size()
	if ny < 0 or ny >= h_grid:
		return true
	var row_any: Variant = _grid[ny]
	if not (row_any is Array):
		return true
	var row: Array = row_any
	var w_grid: int = row.size()
	if nx < 0 or nx >= w_grid:
		return true
	var v_any: Variant = row[nx]
	if not (v_any is int):
		return true
	var v: int = v_any
	var is_target: bool = false
	if kind == TargetKind.WALLS:
		if v == CELL_WALL:
			is_target = true
	else:
		if v == CELL_FLOOR or v == CELL_DOOR:
			is_target = true
	if not is_target:
		return true
	return false

# ===== PATTERN モード =====

# TileMapPattern を使ってターゲットセルにパターン貼り付けを行う
func _place_via_patterns(
	layer: TileMapLayer,
	cells_base: Array[Vector2i],
	all_cells: Array[Vector2i],
	indices: PackedInt32Array,
	avoid_overlap: bool,
	coverage_ratio: float,
	kind: TargetKind,
	only_place_on_unoccupied_global: bool,
	free_cells: Array[Vector2i]
) -> bool:
	if layer == null:
		return false
	var ts: TileSet = layer.tile_set
	if ts == null:
		_err("tile_set is null")
		return false

	_ensure_pattern_dicts_initialized()
	_last_pattern_force_register = false

	var pats: Array = []
	var count: int = ts.get_patterns_count()
	if count <= 0:
		_log(1, "no patterns in TileSet")
		return true

	# pattern_indices が空なら、有効な全パターンを候補にする
	if indices.size() == 0:
		var i0: int = 0
		while i0 < count:
			var p: TileMapPattern = ts.get_pattern(i0)
			if p != null and not p.is_empty():
				var info0: Dictionary = {
					"pattern_index": i0,
					"pattern": p
				}
				pats.append(info0)
			i0 += 1
	else:
		var j0: int = 0
		while j0 < indices.size():
			var idx: int = indices[j0]
			if idx >= 0 and idx < count:
				var p2: TileMapPattern = ts.get_pattern(idx)
				if p2 != null and not p2.is_empty():
					var info2: Dictionary = {
						"pattern_index": idx,
						"pattern": p2
					}
					pats.append(info2)
			j0 += 1

	if pats.is_empty():
		_log(1, "no valid patterns by indices")
		return true

	# 有効セルの範囲から幅・高さを推定
	var extent_cells: Array[Vector2i] = all_cells
	if extent_cells.is_empty():
		extent_cells = cells_base

	if extent_cells.is_empty():
		_log(1, "pattern: empty extent cells")
		return true

	var maxx: int = 0
	var maxy: int = 0
	var t0: int = 0
	while t0 < extent_cells.size():
		var cpos: Vector2i = extent_cells[t0]
		if cpos.x > maxx:
			maxx = cpos.x
		if cpos.y > maxy:
			maxy = cpos.y
		t0 += 1
	var w: int = maxx + 1
	var h: int = maxy + 1

	# 「未使用セルのみ」を対象とするマスク
	var allowed_free: Array = []
	var yy: int = 0
	while yy < h:
		var row_free: Array[bool] = []
		var xx: int = 0
		while xx < w:
			row_free.append(false)
			xx += 1
		allowed_free.append(row_free)
		yy += 1

	var i_free: int = 0
	while i_free < free_cells.size():
		var cp: Vector2i = free_cells[i_free]
		if cp.x >= 0 and cp.x < w and cp.y >= 0 and cp.y < h:
			var row_a_any: Variant = allowed_free[cp.y]
			if row_a_any is Array:
				var row_a: Array = row_a_any
				row_a[cp.x] = true
		i_free += 1

	# 「ターゲットセル全体」を対象とするマスク
	var allowed_all: Array = []
	yy = 0
	while yy < h:
		var row_all: Array[bool] = []
		var xx2: int = 0
		while xx2 < w:
			row_all.append(false)
			xx2 += 1
		allowed_all.append(row_all)
		yy += 1

	var src_for_all: Array[Vector2i] = all_cells
	if src_for_all.is_empty():
		src_for_all = cells_base

	var i2: int = 0
	while i2 < src_for_all.size():
		var cp2: Vector2i = src_for_all[i2]
		if cp2.x >= 0 and cp2.x < w and cp2.y >= 0 and cp2.y < h:
			var row_all_any2: Variant = allowed_all[cp2.y]
			if row_all_any2 is Array:
				var row_all2: Array = row_all_any2
				row_all2[cp2.x] = true
		i2 += 1

	# 実際にパターンが占有したセルを記録するためのマスク
	var occupied: Array = []
	yy = 0
	while yy < h:
		var row_o: Array[bool] = []
		var xx3: int = 0
		while xx3 < w:
			row_o.append(false)
			xx3 += 1
		occupied.append(row_o)
		yy += 1

	# パターンごとに候補配置位置を計算
	var pi: int = 0
	while pi < pats.size():
		var info_pat_any: Variant = pats[pi]
		var info_pat: Dictionary = info_pat_any
		var pat_index: int = info_pat["pattern_index"]
		var pat: TileMapPattern = info_pat["pattern"]

		var psize: Vector2i = pat.get_size()
		var used_cells_pat: Array[Vector2i] = pat.get_used_cells()
		var weight: float = _get_pattern_weight(pat_index)
		var adj_mask: int = _get_pattern_adj_mask(pat_index)
		var required_cells: Array[Vector2i] = _get_required_cells_for_pattern_index(pat_index, pat)
		var min_count: int = _get_pattern_min_count(pat_index)
		var max_count: int = _get_pattern_max_count(pat_index)

		var only_mode: int = _get_pattern_only_unocc_override(pat_index)
		var only_flag: bool = false
		if only_mode == 0:
			if only_place_on_unoccupied_global:
				only_flag = true
			else:
				only_flag = false
		elif only_mode == 1:
			only_flag = true
		elif only_mode == 2:
			only_flag = false

		if weight <= 0.0 or psize.x <= 0 or psize.y <= 0 or used_cells_pat.is_empty():
			info_pat["weight"] = 0.0
			info_pat["candidates"] = []
			info_pat["adj_mask"] = adj_mask
			info_pat["required_cells"] = required_cells
			info_pat["min_count"] = min_count
			info_pat["max_count"] = max_count
			info_pat["placed_count"] = 0
			info_pat["only_unocc_mode"] = only_mode
			info_pat["only_unocc_flag"] = only_flag
			info_pat["used_cells"] = used_cells_pat
			pats[pi] = info_pat
			pi += 1
			continue

		var cand: Array[Vector2i] = []

		var max_ox: int = w - psize.x
		var max_oy: int = h - psize.y
		if max_ox >= 0 and max_oy >= 0:
			var oy: int = 0
			while oy <= max_oy:
				var ox: int = 0
				while ox <= max_ox:
					var use_allowed_mask: Array = allowed_all
					if only_flag:
						use_allowed_mask = allowed_free
					if _can_paste_pattern_on_mask(
						used_cells_pat,
						ox,
						oy,
						use_allowed_mask,
						occupied,
						w,
						h,
						false, # 候補生成時は overlap 無視
						adj_mask,
						required_cells,
						kind
					):
						cand.append(Vector2i(ox, oy))
					ox += 1
				oy += 1

		# 候補をシャッフルして偏りを減らす
		if cand.size() > 1:
			var ci_shuffle: int = cand.size() - 1
			while ci_shuffle > 0:
				var rci: int = randi() % (ci_shuffle + 1)
				if rci != ci_shuffle:
					var tmpc: Vector2i = cand[ci_shuffle]
					cand[ci_shuffle] = cand[rci]
					cand[rci] = tmpc
				ci_shuffle -= 1

		info_pat["weight"] = weight
		info_pat["adj_mask"] = adj_mask
		info_pat["required_cells"] = required_cells
		info_pat["candidates"] = cand
		info_pat["min_count"] = min_count
		info_pat["max_count"] = max_count
		info_pat["placed_count"] = 0
		info_pat["only_unocc_mode"] = only_mode
		info_pat["only_unocc_flag"] = only_flag
		info_pat["used_cells"] = used_cells_pat
		pats[pi] = info_pat
		pi += 1

	# カバレッジ目標セル数
	var total_ok: int = cells_base.size()
	var ratio: float = clamp(coverage_ratio, 0.0, 1.0)
	var target_cover: int = int(floor(float(total_ok) * ratio))
	if target_cover < 0:
		target_cover = 0
	if target_cover > total_ok:
		target_cover = total_ok

	var used_cells: Array[Vector2i] = []
	var covered: int = 0

	var safety: int = 0
	var safety_limit: int = 100000

	# カバレッジ確保と min_count を満たすまで繰り返し
	while true:
		if not _has_unfulfilled_min_patterns(pats):
			if covered >= target_cover:
				break

		if safety > safety_limit:
			_warn("pattern placement safety break: too many iterations")
			break
		safety += 1

		var total_weight: float = _pattern_update_total_weight(pats)
		if total_weight <= 0.0:
			break

		var pick_i: int = _pattern_pick_index_weighted(pats, total_weight)
		if pick_i < 0 or pick_i >= pats.size():
			break

		var pinfo_pick_any: Variant = pats[pick_i]
		var pinfo_pick: Dictionary = pinfo_pick_any
		var cand_any: Variant = pinfo_pick.get("candidates", [])
		if not (cand_any is Array):
			pinfo_pick["weight"] = 0.0
			pats[pick_i] = pinfo_pick
			continue

		var cand_arr: Array = cand_any
		if cand_arr.is_empty():
			pinfo_pick["weight"] = 0.0
			pats[pick_i] = pinfo_pick
			continue

		var ci_use: int = randi() % cand_arr.size()
		var pos: Vector2i = cand_arr[ci_use]

		var pat_pick: TileMapPattern = pinfo_pick["pattern"]
		var used_cells_pick_any: Variant = pinfo_pick.get("used_cells", [])
		var used_cells_pick: Array[Vector2i] = []
		if used_cells_pick_any is Array:
			used_cells_pick = used_cells_pick_any

		var adj_mask_pick: int = int(pinfo_pick.get("adj_mask", 0))
		var required_cells_pick_any: Variant = pinfo_pick.get("required_cells", [])
		var required_cells_pick: Array[Vector2i] = []
		if required_cells_pick_any is Array:
			required_cells_pick = required_cells_pick_any

		var pat_index_pick: int = int(pinfo_pick.get("pattern_index", 0))

		var only_flag_pick: bool = false
		if pinfo_pick.has("only_unocc_flag"):
			only_flag_pick = bool(pinfo_pick["only_unocc_flag"])

		var use_allowed_mask_pick: Array = allowed_all
		if only_flag_pick:
			use_allowed_mask_pick = allowed_free

		if _can_paste_pattern_on_mask(
			used_cells_pick,
			pos.x,
			pos.y,
			use_allowed_mask_pick,
			occupied,
			w,
			h,
			avoid_overlap,
			adj_mask_pick,
			required_cells_pick,
			kind
		):
			layer.set_pattern(pos, pat_pick)

			var reg_mode: int = _get_pattern_register_override(pat_index_pick)

			var record_flag: bool = false
			if reg_mode == 0:
				record_flag = register_used_cells_to_layout
			elif reg_mode == 1:
				record_flag = true
				_last_pattern_force_register = true
			elif reg_mode == 2:
				record_flag = false

			var addc: int = _mark_occupied_and_collect(
				used_cells_pick,
				pos.x,
				pos.y,
				occupied,
				w,
				h,
				used_cells,
				record_flag
			)
			covered += addc

			var placed_count_pick: int = 0
			if pinfo_pick.has("placed_count"):
				placed_count_pick = int(pinfo_pick["placed_count"])
			placed_count_pick += 1
			pinfo_pick["placed_count"] = placed_count_pick

			cand_arr.remove_at(ci_use)
			pinfo_pick["candidates"] = cand_arr
			pats[pick_i] = pinfo_pick
		else:
			cand_arr.remove_at(ci_use)
			pinfo_pick["candidates"] = cand_arr
			pats[pick_i] = pinfo_pick

	_last_used_cells = used_cells
	var unused_cells_count: int = cells_base.size() - used_cells.size()
	if unused_cells_count < 0:
		unused_cells_count = 0
	var layer_name: String = "<null>"
	if layer != null:
		layer_name = layer.name
	_log(
		1,
		"PATTERN placed: covered~=" + str(covered) + "/" + str(target_cover) +
		" base_cells=" + str(cells_base.size()) +
		" used_cells=" + str(used_cells.size()) +
		" unused_cells=" + str(unused_cells_count) +
		" node=" + str(name) +
		" layer=" + layer_name
	)
	print(
		"[TerrainAtlasPatternPlacer] _place_via_patterns: covered~=",
		str(covered),
		"/",
		str(target_cover),
		" base_cells=",
		str(cells_base.size()),
		" node=",
		str(name)
	)
	return true

# ===== PATTERN 補助 =====

# マスクや Adj 条件を考慮して、指定位置にパターンを貼れるか判定
func _can_paste_pattern_on_mask(
	used: Array[Vector2i],
	ox: int,
	oy: int,
	allowed_for_place: Array,
	occupied: Array,
	w: int,
	h: int,
	avoid_overlap: bool,
	adj_mask: int,
	req_cells: Array[Vector2i],
	kind: TargetKind
) -> bool:
	var i: int = 0
	while i < used.size():
		var rel: Vector2i = used[i]
		var gx: int = ox + rel.x
		var gy: int = oy + rel.y
		if gx < 0 or gx >= w or gy < 0 or gy >= h:
			return false

		var allowed_row_any: Variant = allowed_for_place[gy]
		if not (allowed_row_any is Array):
			return false
		var allowed_row: Array = allowed_row_any
		if not bool(allowed_row[gx]):
			return false

		if avoid_overlap:
			var occ_row_any: Variant = occupied[gy]
			if not (occ_row_any is Array):
				return false
			var occ_row: Array = occ_row_any
			if bool(occ_row[gx]):
				return false

		i += 1

	# Adj 指定がなければここで確定
	if adj_mask == 0:
		return true

	var need_up: bool = (adj_mask & 1) != 0
	var need_right: bool = (adj_mask & 2) != 0
	var need_down: bool = (adj_mask & 4) != 0
	var need_left: bool = (adj_mask & 8) != 0

	# 必須接地セルが特に指定されていない場合、使用セルどれか 1 つでも縁に接していれば OK
	if req_cells.is_empty():
		var up_ok_any: bool = not need_up
		var right_ok_any: bool = not need_right
		var down_ok_any: bool = not need_down
		var left_ok_any: bool = not need_left

		var j0: int = 0
		while j0 < used.size():
			var rel_any: Vector2i = used[j0]
			var gx_any: int = ox + rel_any.x
			var gy_any: int = oy + rel_any.y

			if need_up and not up_ok_any:
				if _is_edge_cell_for_adj(gx_any, gy_any - 1, kind):
					up_ok_any = true

			if need_right and not right_ok_any:
				if _is_edge_cell_for_adj(gx_any + 1, gy_any, kind):
					right_ok_any = true

			if need_down and not down_ok_any:
				if _is_edge_cell_for_adj(gx_any, gy_any + 1, kind):
					down_ok_any = true

			if need_left and not left_ok_any:
				if _is_edge_cell_for_adj(gx_any - 1, gy_any, kind):
					left_ok_any = true

			j0 += 1

		if need_up and not up_ok_any:
			return false
		if need_right and not right_ok_any:
			return false
		if need_down and not down_ok_any:
			return false
		if need_left and not left_ok_any:
			return false

		return true

	# 必須接地セルが指定されている場合は、その中で上下左右の「端」セルを探す
	var top_y_for_x: Dictionary = {}
	var bottom_y_for_x: Dictionary = {}
	var left_x_for_y: Dictionary = {}
	var right_x_for_y: Dictionary = {}

	var k0: int = 0
	while k0 < req_cells.size():
		var rc: Vector2i = req_cells[k0]
		var rx: int = rc.x
		var ry: int = rc.y

		if need_up:
			if not top_y_for_x.has(rx) or ry < int(top_y_for_x[rx]):
				top_y_for_x[rx] = ry
		if need_down:
			if not bottom_y_for_x.has(rx) or ry > int(bottom_y_for_x[rx]):
				bottom_y_for_x[rx] = ry
		if need_left:
			if not left_x_for_y.has(ry) or rx < int(left_x_for_y[ry]):
				left_x_for_y[ry] = rx
		if need_right:
			if not right_x_for_y.has(ry) or rx > int(right_x_for_y[ry]):
				right_x_for_y[ry] = rx

		k0 += 1

	# 上方向の縁チェック
	if need_up:
		for x_key in top_y_for_x.keys():
			var uy_local: int = int(top_y_for_x[x_key])
			var ux_local: int = int(x_key)
			var gx_u: int = ox + ux_local
			var gy_u: int = oy + uy_local
			if not _is_edge_cell_for_adj(gx_u, gy_u - 1, kind):
				return false

	# 下方向の縁チェック
	if need_down:
		for x_key2 in bottom_y_for_x.keys():
			var dy_local: int = int(bottom_y_for_x[x_key2])
			var dx_local: int = int(x_key2)
			var gx_d: int = ox + dx_local
			var gy_d: int = oy + dy_local
			if not _is_edge_cell_for_adj(gx_d, gy_d + 1, kind):
				return false

	# 左方向の縁チェック
	if need_left:
		for y_key in left_x_for_y.keys():
			var lx_local: int = int(left_x_for_y[y_key])
			var ly_local: int = int(y_key)
			var gx_l: int = ox + lx_local
			var gy_l: int = oy + ly_local
			if not _is_edge_cell_for_adj(gx_l - 1, gy_l, kind):
				return false

	# 右方向の縁チェック
	if need_right:
		for y_key2 in right_x_for_y.keys():
			var rx_local: int = int(right_x_for_y[y_key2])
			var ry_local: int = int(y_key2)
			var gx_r: int = ox + rx_local
			var gy_r: int = oy + ry_local
			if not _is_edge_cell_for_adj(gx_r + 1, gy_r, kind):
				return false

	return true

# occupied マスクを更新し、必要なら used_cells にも追加
func _mark_occupied_and_collect(
	used: Array[Vector2i],
	ox: int,
	oy: int,
	occupied: Array,
	w: int,
	h: int,
	out_cells: Array[Vector2i],
	record_in_out_cells: bool
) -> int:
	var addc: int = 0
	var i: int = 0
	while i < used.size():
		var rel: Vector2i = used[i]
		var gx: int = ox + rel.x
		var gy: int = oy + rel.y
		if gx >= 0 and gx < w and gy >= 0 and gy < h:
			var row_o_any: Variant = occupied[gy]
			if row_o_any is Array:
				var row_o: Array = row_o_any
				var flag_any: Variant = row_o[gx]
				var flag: bool = bool(flag_any)
				if not flag:
					row_o[gx] = true
					addc += 1
			if record_in_out_cells:
				out_cells.append(Vector2i(gx, gy))
		i += 1
	return addc
