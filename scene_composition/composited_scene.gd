extends Node3D

@onready var layers_parent: Node3D = %Layers

var depths: Array[float] = []
var layers: Array[PaintedLayer] = []

func update_from_canvases(canvases: Array[PaintCanvasState]) -> void:
	# Clear out existing layers
	layers.clear()
	for child in layers_parent.get_children():
		child.queue_free()
	for i in range(canvases.size()):
		var layer := PaintedLayer.new()
		layer.canvas = canvases[i]
		if depths.size() <= i:
			depths.append(0.0)
		layer.depth = depths[i]
		layers_parent.add_child(layer)
		layers.append(layer)

func set_depth(index: int, depth: float) -> void:
	if index < 0 or index >= depths.size():
		return
	depths[index] = depth
	layers[index].depth = depth
