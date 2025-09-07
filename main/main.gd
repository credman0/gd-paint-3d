extends Control

@onready var paint_root: Node = $TabContainer/PaintRoot
@onready var composition_editor: Node = $TabContainer/CompositionEditor

func _ready() -> void:
	if paint_root and composition_editor:
		# Forward updates when canvases change (added/renamed)
		paint_root.canvases_updated.connect(_on_canvases_updated)
		# Seed initial state in case the signal already fired
		var names := PackedStringArray()
		for n in paint_root.canvas_names:
			names.append(n)
		composition_editor.set_canvases(paint_root.canvases, names)

func _on_canvases_updated(canvases: Array, names: PackedStringArray) -> void:
	if composition_editor:
		composition_editor.set_canvases(canvases, names)
