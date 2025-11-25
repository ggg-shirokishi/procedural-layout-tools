# Godot Roguelike Dungeon Layout Tools

Godot 4 系向けの **ダンジョン用レイアウト生成ツール群**です。  
以下のスクリプトとエディタプラグインをまとめたリポジトリです。

- `room_rayout_generator.gd`  
  - 2D グリッドベースの部屋＋通路レイアウトを生成するレイアウトジェネレータ
- `terrain_atlas_pattern_placer.gd`  
  - 生成済みレイアウトグリッドをもとに、TileMapLayer に Terrain Pattern を貼り付ける配置ツール
- `RuntimeLayoutKeyboardController.gd`  
  - ランタイム中にキーボード入力でレイアウト再生成＋プレイヤー移動＋カメラ制限を更新するコントローラ
- `addons/terrain_pattern_tools/terrain_pattern_placer_inspector.gd`  
  - `terrain_atlas_pattern_placer` 用のインスペクタ拡張（Pattern ごとの Weight / Adjacent / Required Cells / Min / Max / Reg / Unocc を編集）

Godot 4.4 / GDScript 2.0 をターゲットにしています。

---

## Features / 機能概要

### room_rayout_generator.gd

- 壁／床／通路を扱う 2D グリッドレイアウトを自動生成
- width / height / room_count / room_w_min / room_w_max / room_h_min / room_h_max / corridor_width などのパラメータで制御
- `seed` プロパティを変更することで再生成がトリガーされる設計（`set seed(value)` 内で `generate_now()` を呼ぶ想定）
- `get_grid_copy()` によるグリッド配列の取得
- `get_free_cells(kind: int)` による「未使用セル」の取得
- 生成完了時に `generation_finished(success: bool)` シグナルを emit

### terrain_atlas_pattern_placer.gd

- `room_rayout_generator` などから取得したレイアウトグリッドをもとに、1 枚の TileMapLayer に対して Terrain またはPattern を貼り付け
- 壁・床・ドアなどのセル種別に応じて Pattern を選択してランダム配置
- Pattern ごとの出現重み、接地条件、必須接地セル、最低配置数／最大配置数、`register_used_cells_to_layout` / `only_place_on_unoccupied` のパターン別オーバーライドに対応
- 実際に配置に使用したセル一覧をレイアウト側へ `register_used_cells(cells)` で返すことを想定

### runtime_rayout_controller.gd

- ゲーム実行中に、指定アクション（例：`dungeon_regen`）を押すたびにレイアウトを再生成
- 再生成前に下記をランダムに振り直すオプションを提供
  - レイアウト全体サイズ（width / height）
  - 部屋数（room_count）
  - 部屋サイズ（room_w_min / room_w_max / room_h_min / room_h_max）
  - 通路幅（corridor_width_min / corridor_width_max / corridor_width）
- 再生成完了後に以下の処理を自動で行う
  - プレイヤーなど任意の Node2D を、フロアの「未使用セル」または「壁に隣接した未使用フロアセル」に移動
  - Camera2D / ZoomCamera2D の `limit_left` / `limit_right` / `limit_top` / `limit_bottom` を、レイアウト外周に合わせて設定

### terrain_pattern_placer_inspector.gd (EditorInspectorPlugin)

- 対象：`terrain_atlas_pattern_placer` を付けたノード
- フィールド：`addons/terrain_pattern_tools/terrain_pattern_placer_inspector.gd`
- 機能：
  - target_layer_path で指定された TileMapLayer の TileSet から Pattern 一覧を取得
  - Pattern ごとに以下をインスペクタ上で編集可能
    - サムネイル（実際のタイル見た目、縮小なし）
    - グリッドプレビュー（使用セルのみを塗ったミニマップ）
    - 出現重み（SpinBox）
    - 上下左右の接地条件（U / R / D / L チェックボックス）
    - 必須接地セル（Pattern 内セルをボタンでトグル）
    - 最低配置回数（Min）
    - 最大配置回数（Max, -1 で無制限／未設定）
    - `register_used_cells_to_layout` オーバーライド（Inherit / Force On / Force Off）
    - `only_place_on_unoccupied` オーバーライド（Inherit / Force On / Force Off）

---

## Repository Structure / ディレクトリ構成例

このリポジトリの想定ディレクトリ構成例です。実際のプロジェクトに合わせて調整してください。

```text
godot-roguelike-dungeon-layout-tools/
  README.md
  addons/
    terrain_pattern_tools/
      terrain_pattern_placer_inspector.gd
      plugin.cfg
      icon.svg
  scripts/
    room_rayout_generator.gd
    terrain_atlas_pattern_placer.gd
    runtime_rayout_controller.gd
