@tool
extends EditorPlugin

var _insp: EditorInspectorPlugin = null

func _enter_tree() -> void:
	var insp_script: Script = load("res://addons/terrain_pattern_tools/terrain_pattern_placer_inspector.gd")
	if insp_script != null:
		_insp = insp_script.new()
		add_inspector_plugin(_insp)

func _exit_tree() -> void:
	if _insp != null:
		remove_inspector_plugin(_insp)
		_insp = null
