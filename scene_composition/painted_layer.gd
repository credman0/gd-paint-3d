class_name PaintedLayer extends Node3D

var canvas: PaintCanvasState = null
@onready var texture_rect: TextureRect = %TextureRect
@onready var sub_viewport: SubViewport = %SubViewport

var layer_name: String = ""
var depth: float = 0.0

func _ready() -> void:
	assert(canvas != null, "Canvas is not set")
	texture_rect.texture = canvas.canvas_tex
	texture_rect.size = canvas.canvas_resolution
	sub_viewport.set_size(canvas.canvas_resolution)
	transform.origin.z = -depth

func set_depth(value: float) -> void:
	depth = value
	var t := transform
	t.origin.z = -depth
	transform = t
