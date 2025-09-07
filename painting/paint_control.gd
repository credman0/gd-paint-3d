extends Control

signal image_updated(image: Image)

const UNDO_NONE := -1

enum BrushModes { PEN, PENCIL, ERASER, CIRCLE_SHAPE, RECTANGLE_SHAPE }
enum BrushShapes { RECTANGLE, CIRCLE }

@onready var drawing_area: TextureRect = $"../DrawingArea" # TextureRect
var drawing_rect: Rect2i

# View transform (pan/zoom)
var canvas_resolution: Vector2 = Vector2(1024, 768) # logical pixel size of the canvas
var zoom: float = 1.0
var min_zoom: float = 0.25
var max_zoom: float = 8.0
var view_origin: Vector2 = Vector2.ZERO # top-left of the canvas in viewport coordinates
var panning: bool = false

# Raster
var canvas_img: Image
var canvas_tex: ImageTexture

# Input
var is_mouse_in_drawing_area := false
var last_mouse_pos: Vector2 = Vector2.ZERO
var mouse_click_start_pos: Vector2 = Vector2.INF
var last_paint_pos: Vector2 = Vector2.INF
var stroke_active := false

# Undo/redo (snapshots + parallel logs)
var undo_stack: Array[Image] = []
var redo_stack: Array[Image] = []
var undo_log_stack: Array = []    # Array<Array> snapshot of brush_data_list
var redo_log_stack: Array = []
var max_undo := 32

# Brush log, kept compact per stroke/shape for external consumers
var brush_data_list: Array = []

# Pressure
var pressure_enabled := true
var pressure_min_factor := 0.2
var pressure_max_factor := 1.0
var _current_pressure := 0.0

# Brush
var brush_mode := BrushModes.PEN
var brush_size := 32
var brush_color := Color.BLACK
var brush_shape := BrushShapes.CIRCLE
var bg_color := Color.WHITE

# Current stroke record
var _current_record: Dictionary = {}

func _ready() -> void:
	Input.use_accumulated_input = false
	_init_canvas()
	# Initialize view origin to current placement of DrawingArea (if any), then apply transform
	view_origin = drawing_area.position
	_apply_view_transform()

func _init_canvas() -> void:
	# Use configured canvas resolution rather than control size
	var sz: Vector2 = canvas_resolution.floor()
	drawing_rect = Rect2i(Vector2i.ZERO, Vector2i(int(sz.x), int(sz.y)))
	canvas_img = Image.create(drawing_rect.size.x, drawing_rect.size.y, false, Image.FORMAT_RGBA8)
	canvas_img.fill(bg_color)
	canvas_tex = ImageTexture.create_from_image(canvas_img)
	drawing_area.texture = canvas_tex
	# Ensure the TextureRect matches logical canvas pixel size; scale is applied separately via zoom
	drawing_area.size = Vector2(drawing_rect.size)
	_apply_view_transform()

func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		_current_pressure = clampf(mm.pressure, 0.0, 1.0)
		if mm.pen_inverted:
			brush_mode = BrushModes.ERASER
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
			if brush_mode == BrushModes.PEN or brush_mode == BrushModes.PENCIL or brush_mode == BrushModes.ERASER:
				_paint_line(last_paint_pos, mouse_pos_vp)
				last_paint_pos = mouse_pos_vp
	else:
		if stroke_active and _mouse_up_inside_canvas():
			if brush_mode == BrushModes.CIRCLE_SHAPE or brush_mode == BrushModes.RECTANGLE_SHAPE:
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
	return bg_color if brush_mode == BrushModes.ERASER else brush_color

func _size_from_pressure(base_size: int, is_pressure_brush: bool) -> int:
	if not pressure_enabled or not is_pressure_brush:
		return max(1, base_size)
	var min_size := base_size * pressure_min_factor
	var max_size := base_size * pressure_max_factor
	var sized := int(round(lerp(min_size, max_size, _current_pressure)))
	return max(1, sized)

func _is_pressure_brush() -> bool:
	return brush_mode == BrushModes.PEN or brush_mode == BrushModes.PENCIL or brush_mode == BrushModes.ERASER

func _paint_line(from_vp: Vector2, to_vp: Vector2) -> void:
	var p0: Vector2i = _viewport_to_canvas(from_vp)
	var p1: Vector2i = _viewport_to_canvas(to_vp)

	var pts: PackedVector2Array = Geometry2D.bresenham_line(Vector2(p0), Vector2(p1))
	if pts.is_empty():
		_stamp_and_log_point(p1)
		_update_texture()
		return

	# canvas_img.lock()
	for p in pts:
		var pi: Vector2i = Vector2i(p)
		_stamp_at_unsafe(pi)
		_log_point(pi)
	# canvas_img.unlock()
	_update_texture()

func _place_shape(to_vp: Vector2) -> void:
	var a: Vector2i = _viewport_to_canvas(mouse_click_start_pos)
	var b: Vector2i = _viewport_to_canvas(to_vp)

	match brush_mode:
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
	canvas_img.lock()
	_stamp_at_unsafe(p)
	canvas_img.unlock()
	_log_point(p)

func _stamp_at(p: Vector2i) -> void:
	canvas_img.lock()
	_stamp_at_unsafe(p)
	canvas_img.unlock()

func _stamp_at_unsafe(p: Vector2i) -> void:
	var is_pressure := _is_pressure_brush()
	var size_px := _size_from_pressure(brush_size, is_pressure)
	var col := _current_color()
	var use_textured := brush_mode == BrushModes.PENCIL
	match brush_shape:
		BrushShapes.RECTANGLE:
			var half := size_px >> 1
			var tl := Vector2i(p.x - half, p.y - half)
			if use_textured:
				_fill_rect_textured_unsafe(tl, Vector2i(size_px, size_px), col)
			else:
				_fill_rect_unsafe(tl, Vector2i(size_px, size_px), col)
		BrushShapes.CIRCLE:
			var r := size_px >> 1
			if use_textured:
				_fill_circle_textured_unsafe(p, r, col)
			else:
				_fill_circle_unsafe(p, r, col)

func _fill_rect(tl: Vector2i, sz: Vector2i, col: Color) -> void:
	canvas_img.lock()
	_fill_rect_unsafe(tl, sz, col)
	canvas_img.unlock()

func _fill_rect_unsafe(tl: Vector2i, sz: Vector2i, col: Color) -> void:
	var x0: int = clampi(tl.x, 0, drawing_rect.size.x - 1)
	var y0: int = clampi(tl.y, 0, drawing_rect.size.y - 1)
	var x1: int = clampi(tl.x + sz.x - 1, 0, drawing_rect.size.x - 1)
	var y1: int = clampi(tl.y + sz.y - 1, 0, drawing_rect.size.y - 1)
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			canvas_img.set_pixel(x, y, col)

func _fill_circle(center: Vector2i, r: int, col: Color) -> void:
	canvas_img.lock()
	_fill_circle_unsafe(center, r, col)
	canvas_img.unlock()

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
				canvas_img.set_pixel(x, y, col)

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
	if pressure_enabled:
		return clampf(lerp(0.18, 0.6, _current_pressure), 0.05, 0.85)
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
	var dst: Color = canvas_img.get_pixel(x, y)
	var out: Color = dst.lerp(col, a)
	canvas_img.set_pixel(x, y, out)

func _update_texture() -> void:
	canvas_tex.update(canvas_img)
	image_updated.emit(canvas_img)

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
	if brush_mode == BrushModes.PEN or brush_mode == BrushModes.PENCIL or brush_mode == BrushModes.ERASER:
		var rec: Dictionary = {
			"kind": "stroke",
			"brush_type": brush_mode,
			"brush_shape": brush_shape,
			"color": _current_color(),
			"base_size": brush_size,
			"pressure": pressure_enabled,
			"points": PackedVector2Array(),
			"sizes": PackedInt32Array(),
		}
		_current_record = rec
	# shapes are logged in _place_shape

func _log_point(pix: Vector2i) -> void:
	if _current_record.size() > 0 and _current_record["kind"] == "stroke":
		var is_pressure_brush := _is_pressure_brush()
		var size_px := _size_from_pressure(brush_size, is_pressure_brush)
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
	brush_data_list.append(rec)

func _log_circle(center: Vector2i, r: int, col: Color) -> void:
	var rec: Dictionary = {
		"kind": "circle",
		"color": col,
		"center": center,
		"radius": r
	}
	brush_data_list.append(rec)

func _finalize_record() -> void:
	if _current_record.size() > 0 and _current_record["kind"] == "stroke":
		var pts: PackedVector2Array = _current_record["points"]
		if pts.size() > 0:
			brush_data_list.append(_current_record.duplicate(true))
	_current_record.clear()

# ---- Undo / Redo -------------------------------------------------------------

func _begin_stroke_snapshot() -> void:
	redo_stack.clear()
	redo_log_stack.clear()
	var snap: Image = canvas_img.duplicate()
	undo_stack.append(snap)
	# snapshot the external log as well
	undo_log_stack.append(brush_data_list.duplicate(true))
	if undo_stack.size() > max_undo:
		undo_stack.pop_front()
		undo_log_stack.pop_front()

func undo_stroke() -> void:
	if undo_stack.is_empty():
		return
	var current_img: Image = canvas_img.duplicate()
	var current_log: Array = brush_data_list.duplicate(true)
	var prev_img: Image = undo_stack.pop_back()
	var prev_log: Array = undo_log_stack.pop_back()
	redo_stack.append(current_img)
	redo_log_stack.append(current_log)
	canvas_img.blit_rect(prev_img, Rect2i(Vector2i.ZERO, prev_img.get_size()), Vector2i.ZERO)
	brush_data_list = prev_log
	_update_texture()

func redo_stroke() -> void:
	if redo_stack.is_empty():
		return
	var current_img: Image = canvas_img.duplicate()
	var current_log: Array = brush_data_list.duplicate(true)
	var nxt_img: Image = redo_stack.pop_back()
	var nxt_log: Array = redo_log_stack.pop_back()
	undo_stack.append(current_img)
	undo_log_stack.append(current_log)
	canvas_img.blit_rect(nxt_img, Rect2i(Vector2i.ZERO, nxt_img.get_size()), Vector2i.ZERO)
	brush_data_list = nxt_log
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
	canvas_img.save_png(path)
