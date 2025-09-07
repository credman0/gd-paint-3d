extends Control

@onready var paint_root: Node = $TabContainer/PaintRoot
@onready var composition_editor: Node = $TabContainer/CompositionEditor

func _ready() -> void:
	if paint_root and composition_editor:
		# Forward updates when canvases change (added/renamed)
		paint_root.canvases_updated.connect(_on_canvases_updated)
		# Forward depth changes from tools panel to the compositor
		if paint_root.has_signal(&"canvas_depth_changed"):
			paint_root.canvas_depth_changed.connect(_on_canvas_depth_changed)
		# Seed initial state in case the signal already fired
		var names := PackedStringArray()
		for i in range(paint_root.canvases.size()):
			var c: PaintCanvasState = paint_root.canvases[i]
			var n := c.canvas_name if c.canvas_name != "" else "Canvas %d" % (i + 1)
			names.append(n)
		composition_editor.set_canvases(paint_root.canvases, names)
		# Also listen to changes from the composition editor to reflect back to paint root
		if composition_editor.composited_scene and composition_editor.composited_scene.has_signal(&"depth_changed"):
			composition_editor.composited_scene.depth_changed.connect(_on_compositor_depth_changed)

func _on_canvases_updated(canvases: Array, names: PackedStringArray) -> void:
	if composition_editor:
		composition_editor.set_canvases(canvases, names)

func _on_canvas_depth_changed(index: int, depth: float) -> void:
	# Relay to composition editor to adjust the 3D layer depth immediately
	if composition_editor and composition_editor.composited_scene:
		composition_editor.composited_scene.set_depth(index, depth)

func _on_compositor_depth_changed(index: int, depth: float) -> void:
	# Update paint root's canvas to keep everything in sync
	if paint_root and paint_root.has_method(&"set_canvas_depth"):
		paint_root.set_canvas_depth(index, depth)
