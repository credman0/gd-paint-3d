extends RefCounted

class_name PaintCanvasState

signal image_updated(image: Image)

# Canvas/Image state and history
var canvas_resolution: Vector2 = Vector2(1024, 1024)
var drawing_rect: Rect2i
var bg_color: Color = Color.WHITE
var canvas_name: String = "" # Human-readable name for UI (tabs, lists)
var depth: float = 0.0 # Parallax depth for composition (positive pulls forward)

var canvas_img: Image
var canvas_tex: ImageTexture

# Undo/redo (snapshots + parallel logs)
var undo_stack: Array[Image] = []
var redo_stack: Array[Image] = []
var undo_log_stack: Array = []	# Array<Array> snapshot of brush_data_list
var redo_log_stack: Array = []
var max_undo := 16

# Brush log, kept compact per stroke/shape for external consumers
var brush_data_list: Array = []

func init_canvas() -> void:
	var sz: Vector2 = canvas_resolution.floor()
	drawing_rect = Rect2i(Vector2i.ZERO, Vector2i(int(sz.x), int(sz.y)))
	canvas_img = Image.create(drawing_rect.size.x, drawing_rect.size.y, false, Image.FORMAT_RGBA8)
	# Start fully transparent; UI may show a backdrop behind this image
	canvas_img.fill(Color(0, 0, 0, 0))
	canvas_tex = ImageTexture.create_from_image(canvas_img)

func begin_stroke_snapshot() -> void:
	redo_stack.clear()
	redo_log_stack.clear()
	var snap: Image = canvas_img.duplicate()
	undo_stack.append(snap)
	# snapshot the external log as well
	undo_log_stack.append(brush_data_list.duplicate(true))
	if undo_stack.size() > max_undo:
		undo_stack.pop_front()
		undo_log_stack.pop_front()

func undo_stroke() -> bool:
	if undo_stack.is_empty():
		return false
	var current_img: Image = canvas_img.duplicate()
	var current_log: Array = brush_data_list.duplicate(true)
	var prev_img: Image = undo_stack.pop_back()
	var prev_log: Array = undo_log_stack.pop_back()
	redo_stack.append(current_img)
	redo_log_stack.append(current_log)
	canvas_img.blit_rect(prev_img, Rect2i(Vector2i.ZERO, prev_img.get_size()), Vector2i.ZERO)
	brush_data_list = prev_log
	return true

func redo_stroke() -> bool:
	if redo_stack.is_empty():
		return false
	var current_img: Image = canvas_img.duplicate()
	var current_log: Array = brush_data_list.duplicate(true)
	var nxt_img: Image = redo_stack.pop_back()
	var nxt_log: Array = redo_log_stack.pop_back()
	undo_stack.append(current_img)
	undo_log_stack.append(current_log)
	canvas_img.blit_rect(nxt_img, Rect2i(Vector2i.ZERO, nxt_img.get_size()), Vector2i.ZERO)
	brush_data_list = nxt_log
	return true

func save_png(path: String) -> void:
	canvas_img.save_png(path)

func emit_image_updated() -> void:
	image_updated.emit(canvas_img)

# --- Export/Serialization API ---

func export_png(path: String) -> void:
	# Alias for the old save_png to clarify that this writes an image file only.
	save_png(path)

func serialize() -> Dictionary:
	# Produce a JSON-serializable snapshot of this canvas.
	# Includes pixels (PNG as base64), metadata, and compact brush logs.
	var img_bytes: PackedByteArray = canvas_img.save_png_to_buffer()
	var img_b64: String = Marshalls.raw_to_base64(img_bytes)

	var data: Dictionary = {
		"version": 1,
		"canvas_resolution": [int(canvas_resolution.x), int(canvas_resolution.y)],
		"bg_color": _color_to_html(bg_color),
		"canvas_name": canvas_name,
		"depth": depth,
		"image_png_b64": img_b64,
		"brush_data_list": _serialize_brush_log(brush_data_list),
	}
	return data

static func deserialize(data: Dictionary) -> PaintCanvasState:
	# Create a new PaintCanvasState from serialized data.
	var s := PaintCanvasState.new()
	var _ver: int = int(data.get("version", 1))
	var res_arr: Array = data.get("canvas_resolution", [1024, 768])
	if res_arr is Array and res_arr.size() >= 2:
		s.canvas_resolution = Vector2(res_arr[0], res_arr[1])
	s.init_canvas()

	s.bg_color = _html_to_color(String(data.get("bg_color", s.bg_color.to_html(true))))
	s.canvas_name = String(data.get("canvas_name", ""))
	s.depth = float(data.get("depth", 0.0))

	# Restore image from embedded PNG
	var b64: String = String(data.get("image_png_b64", ""))
	if b64 != "":
		var bytes: PackedByteArray = Marshalls.base64_to_raw(b64)
		var img := Image.create(1, 1, false, Image.FORMAT_RGBA8)
		var err := img.load_png_from_buffer(bytes)
		if err == OK:
			s.canvas_img = img
			s.drawing_rect = Rect2i(Vector2i.ZERO, img.get_size())
			s.canvas_resolution = Vector2(img.get_size())
			s.canvas_tex = ImageTexture.create_from_image(img)
	# Restore brush logs
	s.brush_data_list = _deserialize_brush_log(data.get("brush_data_list", []))
	# Clear undo/redo stacks on load
	s.undo_stack.clear()
	s.redo_stack.clear()
	s.undo_log_stack.clear()
	s.redo_log_stack.clear()
	return s

# ---- Helpers: serialization of logs and colors ------------------------------

static func _color_to_html(c: Color) -> String:
	# Include alpha for fidelity.
	return c.to_html(true)

static func _html_to_color(s: String) -> Color:
	var c := Color.WHITE
	if s.is_empty():
		return c
	return Color.html(s)

static func _v2i_to_arr(v: Vector2i) -> Array:
	return [int(v.x), int(v.y)]

static func _arr_to_v2i(a: Array) -> Vector2i:
	if a is Array and a.size() >= 2:
		return Vector2i(int(a[0]), int(a[1]))
	return Vector2i.ZERO

static func _serialize_brush_log(log_items: Array) -> Array:
	var out: Array = []
	for rec in log_items:
		if typeof(rec) != TYPE_DICTIONARY:
			continue
		var kind := String(rec.get("kind", ""))
		var base := {"kind": kind}
		match kind:
			"stroke":
				base["brush_type"] = int(rec.get("brush_type", 0))
				base["brush_shape"] = int(rec.get("brush_shape", 0))
				base["color"] = _color_to_html(rec.get("color", Color.BLACK))
				base["base_size"] = int(rec.get("base_size", 1))
				base["pressure"] = bool(rec.get("pressure", false))
				var pts: PackedVector2Array = rec.get("points", PackedVector2Array())
				var arr_pts: Array = []
				for p in pts:
					arr_pts.append(_v2i_to_arr(Vector2i(p)))
				base["points"] = arr_pts
				base["sizes"] = Array(rec.get("sizes", PackedInt32Array()))
			"rect":
				base["color"] = _color_to_html(rec.get("color", Color.BLACK))
				base["tl"] = _v2i_to_arr(rec.get("tl", Vector2i.ZERO))
				base["br"] = _v2i_to_arr(rec.get("br", Vector2i.ZERO))
			"circle":
				base["color"] = _color_to_html(rec.get("color", Color.BLACK))
				base["center"] = _v2i_to_arr(rec.get("center", Vector2i.ZERO))
				base["radius"] = int(rec.get("radius", 0))
			_:
				# Unknown kinds, store as-is if possible
				for k in rec.keys():
					base[k] = rec[k]
		out.append(base)
	return out

static func _deserialize_brush_log(arr: Array) -> Array:
	var out: Array = []
	for rec in arr:
		if typeof(rec) != TYPE_DICTIONARY:
			continue
		var kind := String(rec.get("kind", ""))
		var base: Dictionary = {"kind": kind}
		match kind:
			"stroke":
				base["brush_type"] = int(rec.get("brush_type", 0))
				base["brush_shape"] = int(rec.get("brush_shape", 0))
				base["color"] = _html_to_color(String(rec.get("color", "#FFFFFFFF")))
				base["base_size"] = int(rec.get("base_size", 1))
				base["pressure"] = bool(rec.get("pressure", false))
				var pt_arr: Array = rec.get("points", [])
				var pts: PackedVector2Array = PackedVector2Array()
				for a in pt_arr:
					var v := _arr_to_v2i(a)
					pts.append(Vector2(v))
				base["points"] = pts
				var sizes_arr: Array = rec.get("sizes", [])
				var sizes_packed: PackedInt32Array = PackedInt32Array()
				for s in sizes_arr:
					sizes_packed.append(int(s))
				base["sizes"] = sizes_packed
			"rect":
				base["color"] = _html_to_color(String(rec.get("color", "#FFFFFFFF")))
				base["tl"] = _arr_to_v2i(rec.get("tl", [0, 0]))
				base["br"] = _arr_to_v2i(rec.get("br", [0, 0]))
			"circle":
				base["color"] = _html_to_color(String(rec.get("color", "#FFFFFFFF")))
				base["center"] = _arr_to_v2i(rec.get("center", [0, 0]))
				base["radius"] = int(rec.get("radius", 0))
			_:
				for k in rec.keys():
					base[k] = rec[k]
		out.append(base)
	return out