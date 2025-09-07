class_name CompositedScene extends Node3D

signal layers_updated
signal depth_changed(index: int, depth: float)

@onready var camera: Camera3D = %Camera3D
@onready var layers_parent: Node3D = %Layers

var depths: Array[float] = []
var layers: Array[PaintedLayer] = []

const PAINTED_LAYER_SCENE: PackedScene = preload("res://scene_composition/painted_layer.tscn")

var view_angle: float = 0.0:
	set(value):
		view_angle = value
		var distance = camera.transform.origin.length()
		var rotated_pos = Vector3(0, 0, distance).rotated(Vector3.UP, deg_to_rad(view_angle))
		camera.transform.origin = rotated_pos
		camera.look_at(Vector3.ZERO, Vector3.UP)

func update_from_canvases(canvases: Array[PaintCanvasState], names: PackedStringArray = PackedStringArray()) -> void:
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
		var nm := (names[i] if i < names.size() else "")
		layer.layer_name = nm if nm != "" else "Layer " + str(i)
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
