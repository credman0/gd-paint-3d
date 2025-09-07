extends Control

signal image_updated(image: Image)
signal active_canvas_changed(index: int, title: String)
signal canvases_updated(canvases: Array, names: PackedStringArray)
signal canvas_depth_changed(index: int, depth: float)

const UNDO_NONE := -1

# Use global classes declared via class_name in canvas_state.gd and tools_state.gd

# Public enums (API compatibility for other scripts like tools_panel.gd)
enum BrushModes { PEN, PENCIL, CRAYON, ERASER, CIRCLE_SHAPE, RECTANGLE_SHAPE }
enum BrushShapes { RECTANGLE, CIRCLE }

@onready var drawing_area: TextureRect = $"DrawingArea" # TextureRect
@onready var backdrop: ColorRect = $"Backdrop" # Neutral gray underlay
@onready var canvas_tabs: TabBar = %CanvasTabBar
var underlay_container: Control = null # Holds preview TextureRects for other layers
var drawing_rect: Rect2i
var _is_rebuilding_tabs: bool = false

# View transform (pan/zoom)
var zoom: float = 1.0
var min_zoom: float = 0.25
var max_zoom: float = 8.0
var view_origin: Vector2 = Vector2.ZERO # top-left of the canvas in viewport coordinates
var panning: bool = false

# State holders
# Multiple canvases managed via tabs; `canvas` always points to the active one
var canvases: Array[PaintCanvasState] = []
var active_canvas_index: int = -1
var canvas: PaintCanvasState
var tools: PaintToolsState
var canvas_names: Array[String] = [] # Deprecated: kept to build names array for signals; source of truth is canvas.canvas_name

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

# Throttled image-updated signaling
const IMAGE_UPDATED_INTERVAL_MS: int = 250
var _image_update_pending: bool = false
var _last_image_emit_ts_ms: int = 0

func _ready() -> void:
	Input.use_accumulated_input = false
	tools = PaintToolsState.new()
	# Initialize neutral gray backdrop
	if backdrop:
		backdrop.color = tools.bg_color
	# Tabs: create initial canvas and wire up switching
	canvas_tabs.tab_selected.connect(_on_canvas_tabs_tab_selected)
	_add_new_canvas()
	# Initialize view origin to current placement of DrawingArea (if any), then apply transform
	view_origin = drawing_area.position
	# Create an underlay container for showing other layers beneath the active one
	_setup_underlay_container()
	_apply_view_transform()
	# Initialize image update throttle clock
	_last_image_emit_ts_ms = Time.get_ticks_msec()
	# Inform listeners (e.g., composition editor) of initial canvas list
	_emit_canvases_updated()

func _init_canvas() -> void:
	# Bind TextureRect to canvas state
	drawing_rect = canvas.drawing_rect
	drawing_area.texture = canvas.canvas_tex
	# Ensure the TextureRect matches logical canvas pixel size; scale is applied separately via zoom
	drawing_area.size = Vector2(drawing_rect.size)
	# Backdrop mirrors the drawing area footprint
	backdrop.size = drawing_area.size
	_apply_view_transform()
	# Rebuild the underlay list to reflect the newly-active canvas
	_rebuild_underlay_layers()

# ---- Multi-canvas management -----------------------------------------------

func _sync_tabs() -> void:
	# Rebuild tabs: one per canvas + a trailing '+' tab
	canvas_tabs.clear_tabs()
	_is_rebuilding_tabs = true
	canvas_tabs.set_block_signals(true)
	# Ensure names helper array stays in sync in length (derive from canvas state)
	canvas_names.resize(canvases.size())
	for i in range(canvases.size()):
		var c: PaintCanvasState = canvases[i]
		var title := (c.canvas_name if c.canvas_name != "" else "Canvas %d" % (i + 1))
		canvas_names[i] = title
		canvas_tabs.add_tab(title)
	canvas_tabs.add_tab("+")
	# Keep selection on the active canvas (not the '+')
	if active_canvas_index >= 0 and active_canvas_index < canvases.size():
		canvas_tabs.current_tab = active_canvas_index
	else:
		canvas_tabs.current_tab = (0 if canvases.size() > 0 else -1)
	canvas_tabs.set_block_signals(false)
	_is_rebuilding_tabs = false

func _add_new_canvas() -> void:
	var s := PaintCanvasState.new()
	s.canvas_resolution = Vector2(1024, 1024)
	s.init_canvas()
	canvases.append(s)
	# Default name for the new canvas lives in canvas state
	s.canvas_name = "Canvas %d" % canvases.size()
	# Resort and refresh state so ordering by depth/name is enforced
	_resort_and_refresh(s)

func _set_active_canvas(idx: int) -> void:
	if canvases.is_empty():
		return
	idx = clampi(idx, 0, canvases.size() - 1)
	if active_canvas_index == idx and canvas == canvases[idx]:
		# Still update UI bindings in case only texture/size changed
		_init_canvas()
		return
	active_canvas_index = idx
	canvas = canvases[idx]
	# Keep current backdrop color; don't override tools' bg on canvas switch
	if backdrop != null and tools != null:
		backdrop.color = tools.bg_color
	# Re-bind drawing area to active canvas
	_init_canvas()
	# Ensure tab selection matches
	if canvas_tabs.get_tab_count() > 0 and active_canvas_index < canvas_tabs.get_tab_count():
		if canvas_tabs.current_tab != active_canvas_index:
			canvas_tabs.set_block_signals(true)
			canvas_tabs.current_tab = active_canvas_index
			canvas_tabs.set_block_signals(false)
	# Notify listeners (e.g., tools panel) about active canvas change
	var title := canvas.canvas_name if canvas.canvas_name != "" else "Canvas %d" % (active_canvas_index + 1)
	active_canvas_changed.emit(active_canvas_index, title)

func _on_canvas_tabs_tab_selected(idx: int) -> void:
	# Ignore spurious selections during rebuild or invalid indices
	if _is_rebuilding_tabs or idx < 0:
		return
	# If the '+' tab is clicked, create a new canvas instead of selecting it
	if idx == canvases.size():
		_add_new_canvas()
		return
	_set_active_canvas(idx)

func rename_active_canvas(title: String) -> void:
	if canvases.is_empty() or active_canvas_index < 0:
		return
	title = title.strip_edges()
	if title.is_empty():
		title = "Untitled"
	# Store name on the canvas itself
	canvases[active_canvas_index].canvas_name = title
	# Resort and refresh because name may affect ordering
	_resort_and_refresh(canvases[active_canvas_index])

func _emit_canvases_updated() -> void:
	# Emit a snapshot of canvases and their names for external consumers
	var names_psa := PackedStringArray()
	for i in range(canvases.size()):
		var c: PaintCanvasState = canvases[i]
		var n := c.canvas_name if c.canvas_name != "" else "Canvas %d" % (i + 1)
		names_psa.append(n)
	canvases_updated.emit(canvases, names_psa)

func get_active_canvas_title() -> String:
	if canvases.is_empty() or active_canvas_index < 0:
		return ""
	var c := canvases[active_canvas_index]
	return c.canvas_name if c.canvas_name != "" else "Canvas %d" % (active_canvas_index + 1)

func set_active_canvas_depth(value: float) -> void:
	if canvases.is_empty() or active_canvas_index < 0:
		return
	var c := canvases[active_canvas_index]
	c.depth = value
	# Depth affects ordering and underlay composition
	_resort_and_refresh(c)
	# Compute new index of this canvas after resort
	var new_idx := canvases.find(c)
	canvas_depth_changed.emit(new_idx, value)

func set_canvas_depth(index: int, value: float) -> void:
	if index < 0 or index >= canvases.size():
		return
	var c := canvases[index]
	c.depth = value
	_resort_and_refresh(c)
	# Emit with the canvas' new index
	var new_idx := canvases.find(c)
	canvas_depth_changed.emit(new_idx, value)

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
	# Flush pending image-updated signal at most once per interval
	_maybe_emit_image_update()

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
			if tools.brush_mode == BrushModes.PEN or tools.brush_mode == BrushModes.PENCIL or tools.brush_mode == BrushModes.CRAYON or tools.brush_mode == BrushModes.ERASER:
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

	# In case there was no input this frame but an update is pending, try again
	_maybe_emit_image_update()

# ---- Ordering and underlay composition -------------------------------------

func _setup_underlay_container() -> void:
	if underlay_container == null:
		underlay_container = Control.new()
		underlay_container.name = "UnderlayContainer"
		underlay_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(underlay_container)
		# Ensure stacking order: backdrop (0) < underlay (5) < drawing (10)
		backdrop.z_index = 0
		underlay_container.z_index = 5
		drawing_area.z_index = 10

func _canvas_display_name(c: PaintCanvasState, idx: int) -> String:
	var n := c.canvas_name
	return n if n != "" else "Canvas %d" % (idx + 1)

func _canvas_less_than(a: PaintCanvasState, b: PaintCanvasState) -> bool:
	if a.depth == b.depth:
		var an := (a.canvas_name if a.canvas_name != "" else "").to_lower()
		var bn := (b.canvas_name if b.canvas_name != "" else "").to_lower()
		return an < bn
	return a.depth < b.depth

func _resort_and_refresh(prefer_canvas: PaintCanvasState = null) -> void:
	# Keep track of which canvas should stay active
	var keep := prefer_canvas if prefer_canvas != null else (canvas if canvas != null else null)
	# Sort in-place by depth then name
	canvases.sort_custom(Callable(self, "_canvas_less_than"))
	# Recompute active index
	if keep != null:
		active_canvas_index = canvases.find(keep)
		if active_canvas_index == -1 and canvases.size() > 0:
			active_canvas_index = 0
	else:
		active_canvas_index = min(active_canvas_index, canvases.size() - 1)
	# Apply active canvas binding and tabs
	_set_active_canvas(active_canvas_index)
	_sync_tabs()
	_emit_canvases_updated()
	# Refresh underlays (depth-based set may have changed)
	_rebuild_underlay_layers()

func _rebuild_underlay_layers() -> void:
	if underlay_container == null:
		return
	# Clear previous preview layers
	for child in underlay_container.get_children():
		child.queue_free()
	underlay_container.visible = false
	if canvas == null:
		return
	var active_depth := canvas.depth
	# Build list of canvases with depth greater than active
	var preview_list: Array[PaintCanvasState] = []
	for c in canvases:
		if c != canvas and c.depth > active_depth:
			preview_list.append(c)
	# Sort that subset by the same rule (depth, then name)
	preview_list.sort_custom(Callable(self, "_canvas_less_than"))
	# Create TextureRects for each
	for c in preview_list:
		var tex_rect := TextureRect.new()
		tex_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tex_rect.texture = c.canvas_tex
		tex_rect.size = c.canvas_resolution
		tex_rect.position = Vector2.ZERO
		tex_rect.stretch_mode = TextureRect.STRETCH_KEEP
		underlay_container.add_child(tex_rect)
	underlay_container.visible = not preview_list.is_empty()

# ---- Raster painting ---------------------------------------------------------

func _viewport_to_canvas(p: Vector2) -> Vector2i:
	# Inverse of display transform: (p - origin) / zoom -> pixel coords
	# Use the drawing area's GLOBAL position to account for parent layout offsets (e.g., TabContainer)
	var origin_vp: Vector2 = drawing_area.global_position
	return Vector2i(
		clampi(int(floor((p.x - origin_vp.x) / zoom)), 0, drawing_rect.size.x - 1),
		clampi(int(floor((p.y - origin_vp.y) / zoom)), 0, drawing_rect.size.y - 1)
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
	var use_textured: bool = tools.brush_mode == BrushModes.PENCIL or tools.brush_mode == BrushModes.CRAYON
	match tools.brush_shape:
		BrushShapes.RECTANGLE:
			var half: int = size_px >> 1
			var tl := Vector2i(p.x - half, p.y - half)
			if use_textured:
				if tools.brush_mode == BrushModes.CRAYON:
					_fill_rect_crayon_unsafe(tl, Vector2i(size_px, size_px), col)
				else:
					_fill_rect_textured_unsafe(tl, Vector2i(size_px, size_px), col)
			else:
				_fill_rect_unsafe(tl, Vector2i(size_px, size_px), col)
		BrushShapes.CIRCLE:
			var r: int = size_px >> 1
			if use_textured:
				if tools.brush_mode == BrushModes.CRAYON:
					_fill_circle_crayon_unsafe(p, r, col)
				else:
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
				# Sharper falloff near the edge for clearer definition
				var t := 1.0 - sqrt(float(d2)) / float(r)
				t = clampf(t, 0.0, 1.0)
				t = t * t  # Quadratic for sharper falloff
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

# --- Crayon (heavily textured, waxy fill across whole stroke interior) ------
func _crayon_base_alpha() -> float:
	# Crayon lays down heavier pigment than pencil; pressure scales opacity wide
	if tools.pressure_enabled:
		return clampf(lerp(0.35, 0.95, tools.current_pressure), 0.15, 1.0)
	return 0.6

func _crayon_grain(x: int, y: int) -> float:
	# Combine a stable hash, a coarse cellular variation, and subtle banding
	var n: int = x * 1103515245 + y * 12345
	n = int(n ^ (n >> 13)) * 196314165
	n = int(n ^ (n >> 16))
	var h: float = float(n & 0xFF) / 255.0
	# Coarse blockiness to mimic wax catching on paper tooth
	var block: float = float((((x >> 2) * 73) ^ ((y >> 2) * 151)) & 255) / 255.0
	# Subtle directional streaks
	var streak: float = abs(sin(float(x + y) * 0.025))
	# Mix with weights; bias up so interior is richly textured, not just edges
	return clampf(0.35 * h + 0.45 * block + 0.30 * streak, 0.0, 1.4)

func _fill_rect_crayon_unsafe(tl: Vector2i, sz: Vector2i, col: Color) -> void:
	var x0: int = clampi(tl.x, 0, drawing_rect.size.x - 1)
	var y0: int = clampi(tl.y, 0, drawing_rect.size.y - 1)
	var x1: int = clampi(tl.x + sz.x - 1, 0, drawing_rect.size.x - 1)
	var y1: int = clampi(tl.y + sz.y - 1, 0, drawing_rect.size.y - 1)
	var base: float = _crayon_base_alpha()
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			# Strong interior texture; slightly stronger toward center
			var cx: float = (x0 + x1) * 0.5
			var cy: float = (y0 + y1) * 0.5
			var dx: float = abs(float(x) - cx)
			var dy: float = abs(float(y) - cy)
			var mx: float = max(1.0, float(x1 - x0))
			var my: float = max(1.0, float(y1 - y0))
			var center_boost: float = 1.0 - 0.35 * ((dx / (mx * 0.5)) + (dy / (my * 0.5)))
			var a: float = base * _crayon_grain(x, y) * clampf(center_boost, 0.6, 1.25)
			_blend_pixel(x, y, col, a)

func _fill_circle_crayon_unsafe(center: Vector2i, r: int, col: Color) -> void:
	if r <= 0:
		return
	var r2: int = r * r
	var minx: int = clampi(center.x - r, 0, drawing_rect.size.x - 1)
	var maxx: int = clampi(center.x + r, 0, drawing_rect.size.x - 1)
	var miny: int = clampi(center.y - r, 0, drawing_rect.size.y - 1)
	var maxy: int = clampi(center.y + r, 0, drawing_rect.size.y - 1)
	var base: float = _crayon_base_alpha()
	for y in range(miny, maxy + 1):
		var dy: int = y - center.y
		var dy2: int = dy * dy
		for x in range(minx, maxx + 1):
			var dx: int = x - center.x
			var d2 := dx * dx + dy2
			if d2 <= r2:
				# Inside the circle, crayon should be rich throughout, not just edges
				var t: float = 1.0 - float(d2) / float(r2)  # 1 at center -> 0 at edge
				# Mild center emphasis, but keep edge coverage
				var center_boost: float = 0.8 + 0.4 * t
				var a: float = base * _crayon_grain(x, y) * center_boost
				_blend_pixel(x, y, col, a)

func _update_texture() -> void:
	canvas.canvas_tex.update(canvas.canvas_img)
	# Mark that an image update occurred; emission is throttled from _process
	_image_update_pending = true

func _maybe_emit_image_update() -> void:
	if not _image_update_pending:
		return
	var now := Time.get_ticks_msec()
	if now - _last_image_emit_ts_ms < IMAGE_UPDATED_INTERVAL_MS:
		return
	# Emit both the local and canvas-level signals once
	image_updated.emit(canvas.canvas_img)
	canvas.emit_image_updated()
	_last_image_emit_ts_ms = now
	_image_update_pending = false

# ---- View transform helpers -------------------------------------------------

func _display_rect_vp() -> Rect2:
	# Rect in viewport coordinates that the canvas occupies
	# Use global position so layout parents don't introduce a fixed offset
	return Rect2(drawing_area.global_position, Vector2(drawing_rect.size) * zoom)

func _apply_view_transform() -> void:
	# Apply pan/zoom to the drawing area for visual feedback
	drawing_area.position = view_origin
	drawing_area.scale = Vector2(zoom, zoom)
	# Keep the control sized to the logical canvas pixels
	drawing_area.size = Vector2(drawing_rect.size)
	# Keep backdrop behind and matching transform
	backdrop.position = view_origin
	backdrop.size = Vector2(drawing_rect.size) * zoom
	# Move/scale underlay container to match
	if underlay_container != null:
		underlay_container.position = view_origin
		underlay_container.scale = Vector2(zoom, zoom)

func _set_zoom(target: float, pivot_vp: Vector2) -> void:
	var old_zoom := zoom
	zoom = clampf(target, min_zoom, max_zoom)
	if abs(zoom - old_zoom) < 0.0001:
		return
	# Keep the cursor position stable relative to the canvas while zooming
	var factor := zoom / old_zoom
	# Compute in GLOBAL space to avoid parent layout offsets
	var origin_global: Vector2 = drawing_area.global_position
	var new_origin_global: Vector2 = pivot_vp - (pivot_vp - origin_global) * factor
	var delta: Vector2 = new_origin_global - origin_global
	# Apply delta to local position (for Controls, local/global deltas are identical for translation)
	view_origin += delta
	_apply_view_transform()

# ---- Stroke record logging ---------------------------------------------------

func _begin_record() -> void:
	_current_record.clear()
	if tools.brush_mode == BrushModes.PEN or tools.brush_mode == BrushModes.PENCIL or tools.brush_mode == BrushModes.CRAYON or tools.brush_mode == BrushModes.ERASER:
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
	return is_visible_in_tree() and mouse_click_start_pos != Vector2.INF \
		and _display_rect_vp().has_point(mouse_click_start_pos)

func _mouse_inside_canvas_now() -> bool:
	return is_visible_in_tree() and is_mouse_in_drawing_area

func _mouse_up_inside_canvas() -> bool:
	return is_visible_in_tree() and is_mouse_in_drawing_area

func export_picture(path: String) -> void:
	await RenderingServer.frame_post_draw
	if canvas != null:
		canvas.export_png(path)

func save_project(path: String) -> void:
	# Serialize all canvases into a single JSON file.
	# Path should typically have a custom extension, e.g. .gdpaint
	var payload: Dictionary = {
		"version": 1,
		"active_canvas_index": active_canvas_index,
		"canvases": []
	}
	for c in canvases:
		payload["canvases"].append(c.serialize())
	var json_text := JSON.stringify(payload)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(json_text)
		f.close()

func load_project(path: String) -> void:
	# Load from a JSON file and replace current canvases.
	if not FileAccess.file_exists(path):
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var txt := f.get_as_text()
	f.close()
	var parse: Variant = JSON.parse_string(txt)
	if typeof(parse) != TYPE_DICTIONARY:
		return
	var data: Dictionary = parse
	var new_canvases: Array[PaintCanvasState] = []
	var arr: Array = data.get("canvases", [])
	for item in arr:
		if typeof(item) == TYPE_DICTIONARY:
			var s := PaintCanvasState.deserialize(item)
			new_canvases.append(s)
	if new_canvases.is_empty():
		return
	canvases = new_canvases
	active_canvas_index = -1
	# Resort loaded canvases and restore active selection if possible
	var desired_idx: int = int(data.get("active_canvas_index", 0))
	if desired_idx >= 0 and desired_idx < canvases.size():
		var target := canvases[desired_idx]
		_resort_and_refresh(target)
	else:
		_resort_and_refresh(null)

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
	if backdrop != null:
		backdrop.color = v

func get_bg_color() -> Color:
	return tools.bg_color if tools != null else Color.WHITE

func set_brush_data_list(v: Array) -> void:
	if canvas == null:
		return
	canvas.brush_data_list = v

func get_brush_data_list() -> Array:
	return canvas.brush_data_list if canvas != null else []

# ---- Resolution editing -----------------------------------------------------

func resize_active_canvas(new_w: int, new_h: int) -> void:
	if canvas == null:
		return
	new_w = max(1, new_w)
	new_h = max(1, new_h)
	var old_img: Image = canvas.canvas_img
	var new_img := Image.create(new_w, new_h, false, Image.FORMAT_RGBA8)
	new_img.fill(Color(0, 0, 0, 0))
	# Copy the overlapping region (top-left anchor)
	var copy_w: int = min(new_w, old_img.get_width())
	var copy_h: int = min(new_h, old_img.get_height())
	if copy_w > 0 and copy_h > 0:
		var src_rect := Rect2i(Vector2i.ZERO, Vector2i(copy_w, copy_h))
		new_img.blit_rect(old_img, src_rect, Vector2i.ZERO)
	# Swap into canvas state
	canvas.canvas_img = new_img
	canvas.canvas_tex = ImageTexture.create_from_image(new_img)
	canvas.canvas_resolution = Vector2(new_w, new_h)
	canvas.drawing_rect = Rect2i(Vector2i.ZERO, Vector2i(new_w, new_h))
	# Clear undo/redo stacks as their sizes no longer match
	canvas.undo_stack.clear()
	canvas.redo_stack.clear()
	canvas.undo_log_stack.clear()
	canvas.redo_log_stack.clear()
	# Rebind visuals and notify
	_init_canvas()
	image_updated.emit(canvas.canvas_img)
	canvas.emit_image_updated()
	_emit_canvases_updated()

# Remove all contents of the selected canvas
func clear_canvas() -> void:
	for _canvas in canvases:
		_canvas.clear()
