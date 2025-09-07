extends Control

signal image_updated(image: Image)

func _ready() -> void:
	var pc: Node = _resolve_paint_control()
	if pc and pc.has_signal("image_updated"):
		pc.connect("image_updated", Callable(self, "_on_paint_control_image_updated"))

func _resolve_paint_control() -> Node:
	if has_node("PaintControl"):
		return $PaintControl
	if has_node("../PaintControl"):
		return $"../PaintControl"
	return null

func _on_paint_control_image_updated(image: Image) -> void:
	image_updated.emit(image)