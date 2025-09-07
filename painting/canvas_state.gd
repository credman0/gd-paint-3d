extends RefCounted

class_name PaintCanvasState

signal image_updated(image: Image)

# Canvas/Image state and history
var canvas_resolution: Vector2 = Vector2(1024, 768)
var drawing_rect: Rect2i
var bg_color: Color = Color.WHITE

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