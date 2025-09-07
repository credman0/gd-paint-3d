class_name CompositedScene extends Node3D

signal layers_updated
signal depth_changed(index: int, depth: float)

@onready var layers_parent: Node3D = %Layers

var depths: Array[float] = []
var layers: Array[PaintedLayer] = []

const PAINTED_LAYER_SCENE: PackedScene = preload("res://scene_composition/painted_layer.tscn")

func update_from_canvases(canvases: Array[PaintCanvasState]) -> void:
	# Clear out existing layers
	layers.clear()
	for child in layers_parent.get_children():
		child.queue_free()
	for i in range(canvases.size()):
		var layer := PAINTED_LAYER_SCENE.instantiate() as PaintedLayer
		layer.canvas = canvases[i]
		if depths.size() <= i:
			depths.append(0.0)
		layer.set_depth(depths[i])
		layer.layer_name = "Layer " + str(i)
		layers_parent.add_child(layer)
		layers.append(layer)

	emit_signal("layers_updated")

func set_depth(index: int, depth: float) -> void:
	if index < 0 or index >= depths.size():
		return
	depths[index] = depth
	if index < layers.size():
		layers[index].set_depth(depth)
	emit_signal("depth_changed", index, depth)
