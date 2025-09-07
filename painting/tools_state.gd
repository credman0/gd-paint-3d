extends RefCounted

class_name PaintToolsState

enum BrushModes { PEN, PENCIL, ERASER, CIRCLE_SHAPE, RECTANGLE_SHAPE }
enum BrushShapes { RECTANGLE, CIRCLE }

# Pressure
var pressure_enabled := true
var pressure_min_factor := 0.2
var pressure_max_factor := 1.0
var current_pressure := 0.0

# Brush
var brush_mode: int = BrushModes.PEN
var brush_size: int = 32
var brush_color: Color = Color.BLACK
var brush_shape: int = BrushShapes.CIRCLE
var bg_color: Color = Color(0.5, 0.5, 0.5, 1.0)

func update_pressure_from_event(mm: InputEventMouseMotion) -> void:
	current_pressure = clampf(mm.pressure, 0.0, 1.0)
	if mm.pen_inverted:
		brush_mode = BrushModes.ERASER

func current_color() -> Color:
	# Eraser clears to transparency; background is a separate UI backdrop
	return Color(0, 0, 0, 0) if brush_mode == BrushModes.ERASER else brush_color

func is_pressure_brush() -> bool:
	return brush_mode == BrushModes.PEN or brush_mode == BrushModes.PENCIL or brush_mode == BrushModes.ERASER

func size_from_pressure(base_size: int) -> int:
	if not pressure_enabled or not is_pressure_brush():
		return max(1, base_size)
	var min_size := base_size * pressure_min_factor
	var max_size := base_size * pressure_max_factor
	var sized := int(round(lerp(min_size, max_size, current_pressure)))
	return max(1, sized)
