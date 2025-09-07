extends Control

signal image_updated(image: Image)

const UNDO_NONE := -1

# Load named classes for type hints and instantiation
const PaintCanvasState := preload("res://painting/canvas_state.gd")
const PaintToolsState := preload("res://painting/tools_state.gd")

# Public enums (API compatibility for other scripts like tools_panel.gd)
enum BrushModes { PEN, PENCIL, ERASER, CIRCLE_SHAPE, RECTANGLE_SHAPE }
enum BrushShapes { RECTANGLE, CIRCLE }

@onready var drawing_area: TextureRect = $"../DrawingArea" # TextureRect
var drawing_rect: Rect2i

# View transform (pan/zoom)
var zoom: float = 1.0
var min_zoom: float = 0.25
var max_zoom: float = 8.0
var view_origin: Vector2 = Vector2.ZERO # top-left of the canvas in viewport coordinates
var panning: bool = false

# State holders
var canvas: PaintCanvasState
var tools: PaintToolsState

# Public proxy properties (map to tools/canvas)
var brush_mode: int:
	set(value):
		set_brush_mode(value)
	get:
		return get_brush_mode()
var brush_shape: int:
	set(value):
		set_brush_shape(value)
	get:
		return get_brush_shape()
var brush_size: int:
	set(value):
		set_brush_size(value)
	get:
		return get_brush_size()
var brush_color: Color:
	set(value):
		set_brush_color(value)
	get:
		return get_brush_color()
var bg_color: Color:
	set(value):
		set_bg_color(value)
	get:
		return get_bg_color()
var brush_data_list: Array:
	set(value):
		set_brush_data_list(value)
	get:
		return get_brush_data_list()

# Input
var is_mouse_in_drawing_area := false
var last_mouse_pos: Vector2 = Vector2.ZERO
var mouse_click_start_pos: Vector2 = Vector2.INF
var last_paint_pos: Vector2 = Vector2.INF
var stroke_active := false

# All canvas history/log lives in `canvas`, all brush/pressure in `tools`.

# Current stroke record
var _current_record: Dictionary = {}

func _ready() -> void:
	Input.use_accumulated_input = false
	canvas = PaintCanvasState.new()
	tools = PaintToolsState.new()
	# Initialize canvas resolution and sync bg color -> tools
	canvas.canvas_resolution = Vector2(1024, 768)
	canvas.init_canvas()
	tools.bg_color = canvas.bg_color
	_init_canvas()
	# Initialize view origin to current placement of DrawingArea (if any), then apply transform
	view_origin = drawing_area.position
	_apply_view_transform()

func _init_canvas() -> void:
	# Bind TextureRect to canvas state
	drawing_rect = canvas.drawing_rect
	drawing_area.texture = canvas.canvas_tex
	# Ensure the TextureRect matches logical canvas pixel size; scale is applied separately via zoom
	drawing_area.size = Vector2(drawing_rect.size)
	_apply_view_transform()

func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		tools.update_pressure_from_event(mm)
		# Handle panning with middle-mouse drag
		if panning:
			view_origin += mm.relative
			_apply_view_transform()

	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_MIDDLE:
			panning = mb.pressed
			return
		# Wheel zoom (cursor-centric)
		if mb.pressed and (mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN):
			var factor := 1.1
			var target_zoom := zoom * (factor if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / factor)
			_set_zoom(target_zoom, get_viewport().get_mouse_position())

func _process(_dt: float) -> void:
	var mouse_pos_vp: Vector2 = get_viewport().get_mouse_position()
	var area_rect_vp := _display_rect_vp()
	is_mouse_in_drawing_area = area_rect_vp.has_point(mouse_pos_vp)

	# When panning, don't process painting
	if panning:
		last_mouse_pos = mouse_pos_vp
		return

	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		if mouse_click_start_pos == Vector2.INF:
			mouse_click_start_pos = mouse_pos_vp
			last_paint_pos = mouse_pos_vp
			if _mouse_down_inside_canvas():
				_begin_stroke_snapshot()
				_begin_record()
				stroke_active = true

		if stroke_active and _mouse_inside_canvas_now():
			if tools.brush_mode == BrushModes.PEN or tools.brush_mode == BrushModes.PENCIL or tools.brush_mode == BrushModes.ERASER:
				_paint_line(last_paint_pos, mouse_pos_vp)
				last_paint_pos = mouse_pos_vp
	else:
		if stroke_active and _mouse_up_inside_canvas():
			if tools.brush_mode == BrushModes.CIRCLE_SHAPE or tools.brush_mode == BrushModes.RECTANGLE_SHAPE:
				_place_shape(mouse_pos_vp)
		_finalize_record()
		stroke_active = false
		mouse_click_start_pos = Vector2.INF
		last_paint_pos = Vector2.INF

	last_mouse_pos = mouse_pos_vp

# ---- Raster painting ---------------------------------------------------------

func _viewport_to_canvas(p: Vector2) -> Vector2i:
	# Inverse of display transform: (p - origin) / zoom -> pixel coords
	return Vector2i(
		clampi(int(floor((p.x - view_origin.x) / zoom)), 0, drawing_rect.size.x - 1),
		clampi(int(floor((p.y - view_origin.y) / zoom)), 0, drawing_rect.size.y - 1)
	)

func _current_color() -> Color:
	return tools.current_color()

func _is_pressure_brush() -> bool:
	return tools.is_pressure_brush()

func _paint_line(from_vp: Vector2, to_vp: Vector2) -> void:
	var p0: Vector2i = _viewport_to_canvas(from_vp)
	var p1: Vector2i = _viewport_to_canvas(to_vp)

	var pts: PackedVector2Array = Geometry2D.bresenham_line(Vector2(p0), Vector2(p1))
	if pts.is_empty():
		_stamp_and_log_point(p1)
		_update_texture()
		return

	# canvas image locked per call in stamp methods
	for p in pts:
		var pi: Vector2i = Vector2i(p)
		_stamp_at_unsafe(pi)
		_log_point(pi)
	# unlock handled inside stamp functions when needed
	_update_texture()

func _place_shape(to_vp: Vector2) -> void:
	var a: Vector2i = _viewport_to_canvas(mouse_click_start_pos)
	var b: Vector2i = _viewport_to_canvas(to_vp)

	match tools.brush_mode:
		BrushModes.RECTANGLE_SHAPE:
			var tl := Vector2i(min(a.x, b.x), min(a.y, b.y))
			var br := Vector2i(max(a.x, b.x), max(a.y, b.y))
			_fill_rect(tl, br - tl + Vector2i.ONE, _current_color())
			_log_rect(tl, br, _current_color())
		BrushModes.CIRCLE_SHAPE:
			var center := Vector2i(((a.x + b.x) >> 1), ((a.y + b.y) >> 1))
			var r := int(round(Vector2(center.x, b.y).distance_to(center)))
			_fill_circle(center, r, _current_color())
			_log_circle(center, r, _current_color())

	_update_texture()

func _stamp_and_log_point(p: Vector2i) -> void:
	canvas.canvas_img.lock()
	_stamp_at_unsafe(p)
	canvas.canvas_img.unlock()
	_log_point(p)

func _stamp_at(p: Vector2i) -> void:
	canvas.canvas_img.lock()
	_stamp_at_unsafe(p)
	canvas.canvas_img.unlock()

func _stamp_at_unsafe(p: Vector2i) -> void:
	var size_px: int = tools.size_from_pressure(tools.brush_size)
	var col := _current_color()
	var use_textured: bool = tools.brush_mode == BrushModes.PENCIL
	match tools.brush_shape:
		BrushShapes.RECTANGLE:
			var half: int = size_px >> 1
			var tl := Vector2i(p.x - half, p.y - half)
			if use_textured:
				_fill_rect_textured_unsafe(tl, Vector2i(size_px, size_px), col)
			else:
				_fill_rect_unsafe(tl, Vector2i(size_px, size_px), col)
		BrushShapes.CIRCLE:
			var r: int = size_px >> 1
			if use_textured:
				_fill_circle_textured_unsafe(p, r, col)
			else:
				_fill_circle_unsafe(p, r, col)

func _fill_rect(tl: Vector2i, sz: Vector2i, col: Color) -> void:
	canvas.canvas_img.lock()
	_fill_rect_unsafe(tl, sz, col)
	canvas.canvas_img.unlock()

func _fill_rect_unsafe(tl: Vector2i, sz: Vector2i, col: Color) -> void:
	var x0: int = clampi(tl.x, 0, drawing_rect.size.x - 1)
	var y0: int = clampi(tl.y, 0, drawing_rect.size.y - 1)
	var x1: int = clampi(tl.x + sz.x - 1, 0, drawing_rect.size.x - 1)
	var y1: int = clampi(tl.y + sz.y - 1, 0, drawing_rect.size.y - 1)
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			canvas.canvas_img.set_pixel(x, y, col)

func _fill_circle(center: Vector2i, r: int, col: Color) -> void:
	canvas.canvas_img.lock()
	_fill_circle_unsafe(center, r, col)
	canvas.canvas_img.unlock()

func _fill_circle_unsafe(center: Vector2i, r: int, col: Color) -> void:
	if r <= 0:
		return
	var r2: int = r * r
	var minx: int = clampi(center.x - r, 0, drawing_rect.size.x - 1)
	var maxx: int = clampi(center.x + r, 0, drawing_rect.size.x - 1)
	var miny: int = clampi(center.y - r, 0, drawing_rect.size.y - 1)
	var maxy: int = clampi(center.y + r, 0, drawing_rect.size.y - 1)
	for y in range(miny, maxy + 1):
		var dy: int = y - center.y
		var dy2: int = dy * dy
		for x in range(minx, maxx + 1):
			var dx: int = x - center.x
			if dx * dx + dy2 <= r2:
				canvas.canvas_img.set_pixel(x, y, col)

# Textured pencil fill (grainy, semi-transparent, pressure-reactive)
func _fill_rect_textured_unsafe(tl: Vector2i, sz: Vector2i, col: Color) -> void:
	var x0: int = clampi(tl.x, 0, drawing_rect.size.x - 1)
	var y0: int = clampi(tl.y, 0, drawing_rect.size.y - 1)
	var x1: int = clampi(tl.x + sz.x - 1, 0, drawing_rect.size.x - 1)
	var y1: int = clampi(tl.y + sz.y - 1, 0, drawing_rect.size.y - 1)
	var base_alpha := _pencil_base_alpha()
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			var a := base_alpha * _pencil_grain(x, y)
			_blend_pixel(x, y, col, a)

func _fill_circle_textured_unsafe(center: Vector2i, r: int, col: Color) -> void:
	if r <= 0:
		return
	var r2: int = r * r
	var minx: int = clampi(center.x - r, 0, drawing_rect.size.x - 1)
	var maxx: int = clampi(center.x + r, 0, drawing_rect.size.x - 1)
	var miny: int = clampi(center.y - r, 0, drawing_rect.size.y - 1)
	var maxy: int = clampi(center.y + r, 0, drawing_rect.size.y - 1)
	var base_alpha := _pencil_base_alpha()
	for y in range(miny, maxy + 1):
		var dy: int = y - center.y
		var dy2: int = dy * dy
		for x in range(minx, maxx + 1):
			var dx: int = x - center.x
			var d2 := dx * dx + dy2
			if d2 <= r2:
				# Soft falloff near the edge
				var t := 1.0 - sqrt(float(d2)) / float(r)
				t = clampf(t, 0.0, 1.0)
				var a := base_alpha * (0.5 + 0.5 * t) * _pencil_grain(x, y)
				_blend_pixel(x, y, col, a)

func _pencil_base_alpha() -> float:
	if tools.pressure_enabled:
		return clampf(lerp(0.18, 0.6, tools.current_pressure), 0.05, 0.85)
	return 0.35

func _pencil_grain(x: int, y: int) -> float:
	# Cheap, stable coordinate hash -> 0..1
	var n: int = x * 374761393 + y * 668265263
	n = int(n ^ (n >> 13)) * 1274126177
	n = int(n ^ (n >> 16))
	var v := float(n & 0xFF) / 255.0
	# Bias to avoid too transparent results
	return 0.6 + 0.4 * v

func _blend_pixel(x: int, y: int, col: Color, a: float) -> void:
	a = clampf(a, 0.0, 1.0)
	if a <= 0.001:
		return
	var dst: Color = canvas.canvas_img.get_pixel(x, y)
	var out: Color = dst.lerp(col, a)
	canvas.canvas_img.set_pixel(x, y, out)

func _update_texture() -> void:
	canvas.canvas_tex.update(canvas.canvas_img)
	image_updated.emit(canvas.canvas_img)

# ---- View transform helpers -------------------------------------------------

func _display_rect_vp() -> Rect2:
	# Rect in viewport coordinates that the canvas occupies
	return Rect2(view_origin, Vector2(drawing_rect.size) * zoom)

func _apply_view_transform() -> void:
	# Apply pan/zoom to the drawing area for visual feedback
	drawing_area.position = view_origin
	drawing_area.scale = Vector2(zoom, zoom)
	# Keep the control sized to the logical canvas pixels
	drawing_area.size = Vector2(drawing_rect.size)

func _set_zoom(target: float, pivot_vp: Vector2) -> void:
	var old_zoom := zoom
	zoom = clampf(target, min_zoom, max_zoom)
	if abs(zoom - old_zoom) < 0.0001:
		return
	# Keep the cursor position stable relative to the canvas while zooming
	var factor := zoom / old_zoom
	view_origin = pivot_vp - (pivot_vp - view_origin) * factor
	_apply_view_transform()

# ---- Stroke record logging ---------------------------------------------------

func _begin_record() -> void:
	_current_record.clear()
	if tools.brush_mode == BrushModes.PEN or tools.brush_mode == BrushModes.PENCIL or tools.brush_mode == BrushModes.ERASER:
		var rec: Dictionary = {
			"kind": "stroke",
			"brush_type": tools.brush_mode,
			"brush_shape": tools.brush_shape,
			"color": _current_color(),
			"base_size": tools.brush_size,
			"pressure": tools.pressure_enabled,
			"points": PackedVector2Array(),
			"sizes": PackedInt32Array(),
		}
		_current_record = rec
	# shapes are logged in _place_shape

func _log_point(pix: Vector2i) -> void:
	if _current_record.size() > 0 and _current_record["kind"] == "stroke":
		var size_px: int = tools.size_from_pressure(tools.brush_size)
		var pts: PackedVector2Array = _current_record["points"]
		var sizes: PackedInt32Array = _current_record["sizes"]
		pts.append(pix)
		sizes.append(size_px)
		_current_record["points"] = pts
		_current_record["sizes"] = sizes

func _log_rect(tl: Vector2i, br: Vector2i, col: Color) -> void:
	var rec: Dictionary = {
		"kind": "rect",
		"color": col,
		"tl": tl,
		"br": br
	}
	canvas.brush_data_list.append(rec)

func _log_circle(center: Vector2i, r: int, col: Color) -> void:
	var rec: Dictionary = {
		"kind": "circle",
		"color": col,
		"center": center,
		"radius": r
	}
	canvas.brush_data_list.append(rec)

func _finalize_record() -> void:
	if _current_record.size() > 0 and _current_record["kind"] == "stroke":
		var pts: PackedVector2Array = _current_record["points"]
		if pts.size() > 0:
			canvas.brush_data_list.append(_current_record.duplicate(true))
	_current_record.clear()

# ---- Undo / Redo -------------------------------------------------------------

func _begin_stroke_snapshot() -> void:
	canvas.begin_stroke_snapshot()

func undo_stroke() -> void:
	if canvas.undo_stroke():
		_update_texture()

func redo_stroke() -> void:
	if canvas.redo_stroke():
		_update_texture()

# ---- Helpers ----------------------------------------------------------------

func _mouse_down_inside_canvas() -> bool:
	return mouse_click_start_pos != Vector2.INF \
		and _display_rect_vp().has_point(mouse_click_start_pos)

func _mouse_inside_canvas_now() -> bool:
	return is_mouse_in_drawing_area

func _mouse_up_inside_canvas() -> bool:
	return is_mouse_in_drawing_area

func save_picture(path: String) -> void:
	await RenderingServer.frame_post_draw
	canvas.save_png(path)

# ---- Public proxy methods ---------------------------------------------------

func set_brush_mode(v: int) -> void:
	if tools == null:
		return
	tools.brush_mode = int(v)

func get_brush_mode() -> int:
	return int(tools.brush_mode) if tools != null else int(BrushModes.PEN)

func set_brush_shape(v: int) -> void:
	if tools == null:
		return
	tools.brush_shape = int(v)

func get_brush_shape() -> int:
	return int(tools.brush_shape) if tools != null else int(BrushShapes.CIRCLE)

func set_brush_size(v: int) -> void:
	if tools == null:
		return
	tools.brush_size = max(1, v)

func get_brush_size() -> int:
	return tools.brush_size if tools != null else 32

func set_brush_color(v: Color) -> void:
	if tools == null:
		return
	tools.brush_color = v

func get_brush_color() -> Color:
	return tools.brush_color if tools != null else Color.BLACK

func set_bg_color(v: Color) -> void:
	if tools != null:
		tools.bg_color = v
	if canvas != null:
		canvas.bg_color = v

func get_bg_color() -> Color:
	return tools.bg_color if tools != null else Color.WHITE

func set_brush_data_list(v: Array) -> void:
	if canvas == null:
		return
	canvas.brush_data_list = v

func get_brush_data_list() -> Array:
	return canvas.brush_data_list if canvas != null else []
