extends Panel

@onready var depth_label: Label = %LabelCanvasDepth
@onready var brush_settings = %BrushSettings
@onready var label_opacity_above: Label = %LabelOpacityAbove
@onready var label_opacity_below: Label = %LabelOpacityBelow
@onready var slider_opacity_above: HSlider = %OpacityAboveSlider
@onready var slider_opacity_below: HSlider = %OpacityBelowSlider
@onready var label_brush_size = %LabelBrushSize
@onready var label_brush_shape = %LabelBrushShape
@onready var label_stats = %LabelStats
@onready var label_tools = %LabelTools
@onready var tab_name_line_edit: LineEdit = %TabNameLineEdit
@onready var depth_slider: HSlider = %CanvasDepthSlider
@onready var res_w_spin: SpinBox = %ResolutionW
@onready var res_h_spin: SpinBox = %ResolutionH
@onready var res_apply_btn: Button = %ApplyResolutionButton

@onready var _parent = get_parent()
@onready var export_dialog: FileDialog = _parent.get_parent().get_node(^"SaveFileDialog")
@onready var save_project_dialog: FileDialog = _ensure_project_save_dialog()
@onready var load_project_dialog: FileDialog = _ensure_project_load_dialog()
@onready var paint_control = _parent.get_parent()

func _ready():
	# Assign all of the needed signals for the oppersation buttons.
	%ButtonUndo.pressed.connect(button_pressed.bind("undo_stroke"))
	%ButtonSave.pressed.connect(button_pressed.bind("export_picture"))
	%ButtonSaveProject.pressed.connect(button_pressed.bind("save_project"))
	%ButtonLoadProject.pressed.connect(button_pressed.bind("load_project"))
	%ButtonClear.pressed.connect(button_pressed.bind("clear_picture"))

	# Assign all of the needed signals for the brush buttons.
	%ButtonToolPen.pressed.connect(button_pressed.bind("mode_pen"))
	%ButtonToolPencil.pressed.connect(button_pressed.bind("mode_pencil"))
	if has_node(^"%ButtonToolCrayon"):
		%ButtonToolCrayon.pressed.connect(button_pressed.bind("mode_crayon"))
	%ButtonToolEraser.pressed.connect(button_pressed.bind("mode_eraser"))
	%ButtonToolRectangle.pressed.connect(button_pressed.bind("mode_rectangle"))
	%ButtonToolCircle.pressed.connect(button_pressed.bind("mode_circle"))
	%ButtonShapeBox.pressed.connect(button_pressed.bind("shape_rectangle"))
	%ButtonShapeCircle.pressed.connect(button_pressed.bind("shape_circle"))

	# Assign all of the needed signals for the other brush settings (and ColorPickerBackground).
	%ColorPickerBrush.color_changed.connect(brush_color_changed)
	%ColorPickerBackground.color_changed.connect(background_color_changed)
	%HScrollBarBrushSize.value_changed.connect(brush_size_changed)

	# Assign file dialogs
	export_dialog.file_selected.connect(save_file_selected)
	if save_project_dialog:
		save_project_dialog.file_selected.connect(_on_save_project_file)
	if load_project_dialog:
		load_project_dialog.file_selected.connect(_on_load_project_file)

	# Set physics process so we can update the status label.
	set_physics_process(true)
	# Ensure we receive global key events for shortcuts like Ctrl+Z.
	set_process_unhandled_input(true)

	# Connect tab name LineEdit if assigned
	if tab_name_line_edit:
		tab_name_line_edit.text_submitted.connect(_on_tab_name_submitted)
		tab_name_line_edit.focus_exited.connect(_on_tab_name_focus_exited)
		# Initialize its text to current active canvas title
		if paint_control.has_method(&"get_active_canvas_title"):
			tab_name_line_edit.text = paint_control.get_active_canvas_title()
	# Depth slider wiring
	if depth_slider:
		depth_slider.value_changed.connect(_on_depth_changed)
		# Initialize from active canvas if available
		if paint_control and paint_control.canvases.size() > 0 and paint_control.active_canvas_index >= 0:
			var c: PaintCanvasState = paint_control.canvases[paint_control.active_canvas_index]
			depth_slider.value = c.depth
	# React to active canvas changes to keep text in sync
	if paint_control.has_signal(&"active_canvas_changed"):
		paint_control.active_canvas_changed.connect(_on_active_canvas_changed)
		# When depth changes externally (e.g., from composition editor), keep slider synced
		if paint_control.has_signal(&"canvas_depth_changed"):
			paint_control.canvas_depth_changed.connect(_on_canvas_depth_changed)

	# Resolution controls wiring
	if res_apply_btn:
		res_apply_btn.pressed.connect(_on_apply_resolution)
	# Initialize resolution fields from active canvas
	_update_resolution_fields()

	# Wire and init opacity falloff sliders (Above/Below)
	if slider_opacity_above:
		slider_opacity_above.value_changed.connect(_on_above_falloff_changed)
	if slider_opacity_below:
		slider_opacity_below.value_changed.connect(_on_below_falloff_changed)
	_init_opacity_values_from_paint()


func _physics_process(_delta):
	# Update the status label with the newest brush element count.
	label_stats.text = "Brush objects: " + str(paint_control.brush_data_list.size())


func button_pressed(button_name):
	# If a brush mode button is pressed.
	var tool_name = null
	var shape_name = null

	if button_name == "mode_pen":
		paint_control.brush_mode = paint_control.BrushModes.PEN
		brush_settings.modulate = Color(1, 1, 1, 1)
		tool_name = "Pen"
	elif button_name == "mode_pencil":
		paint_control.brush_mode = paint_control.BrushModes.PENCIL
		brush_settings.modulate = Color(1, 1, 1, 1)
		tool_name = "Pencil"
	elif button_name == "mode_crayon":
		paint_control.brush_mode = paint_control.BrushModes.CRAYON
		brush_settings.modulate = Color(1, 1, 1, 1)
		tool_name = "Crayon"
	elif button_name == "mode_eraser":
		paint_control.brush_mode = paint_control.BrushModes.ERASER
		brush_settings.modulate = Color(1, 1, 1, 1)
		tool_name = "Eraser"
	elif button_name == "mode_rectangle":
		paint_control.brush_mode = paint_control.BrushModes.RECTANGLE_SHAPE
		brush_settings.modulate = Color(1, 1, 1, 0.5)
		tool_name = "Rectangle shape"
	elif button_name == "mode_circle":
		paint_control.brush_mode = paint_control.BrushModes.CIRCLE_SHAPE
		brush_settings.modulate = Color(1, 1, 1, 0.5)
		tool_name = "Circle shape"

	# If a brush shape button is pressed
	elif button_name == "shape_rectangle":
		paint_control.brush_shape = paint_control.BrushShapes.RECTANGLE
		shape_name = "Rectangle"
	elif button_name == "shape_circle":
		paint_control.brush_shape = paint_control.BrushShapes.CIRCLE
		shape_name = "Circle";

	# If a opperation button is pressed
	elif button_name == "clear_picture":
		paint_control.clear_canvas()
		paint_control.queue_redraw()
	elif button_name == "export_picture":
		export_dialog.popup_centered()
	elif button_name == "save_project":
		if save_project_dialog:
			save_project_dialog.popup_centered()
	elif button_name == "load_project":
		if load_project_dialog:
			load_project_dialog.popup_centered()
	elif button_name == "undo_stroke":
		paint_control.undo_stroke()

	# Update the labels (in case the brush mode or brush shape has changed).
	if tool_name != null:
		label_tools.text = "Selected tool: " + tool_name
	if shape_name != null:
		label_brush_shape.text = "Brush shape: " + shape_name


func brush_color_changed(color):
	# Change the brush color to whatever color the color picker is.
	paint_control.brush_color = color


func background_color_changed(color):
	# Change the background color to whatever colorthe background color picker is.
	# get_parent().get_node(^"DrawingAreaBG").modulate = color
	paint_control.bg_color = color
	# Because of how the eraser works we also need to redraw the paint control.
	paint_control.queue_redraw()


func brush_size_changed(value):
	# Change the size of the brush, and update the label to reflect the new value.
	paint_control.brush_size = ceil(value)
	label_brush_size.text = "Brush size: " + str(ceil(value)) + "px"


func save_file_selected(path):
	# Call export_picture in paint_control, passing in the path we received from SaveFileDialog.
	if paint_control.has_method(&"export_picture"):
		paint_control.export_picture(path)

func _on_save_project_file(path: String) -> void:
	if paint_control and paint_control.has_method(&"save_project"):
		paint_control.save_project(path)

func _on_load_project_file(path: String) -> void:
	if paint_control and paint_control.has_method(&"load_project"):
		paint_control.load_project(path)

func _ensure_project_save_dialog() -> FileDialog:
	var root := _parent.get_parent()
	if root.has_node(^"SaveProjectDialog"):
		return root.get_node(^"SaveProjectDialog")
	# Create a minimal dialog at runtime if not present in scene
	var dlg := FileDialog.new()
	dlg.name = "SaveProjectDialog"
	dlg.access = FileDialog.ACCESS_FILESYSTEM
	dlg.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	dlg.filters = PackedStringArray(["*.gdpaint,;GD Paint Project (*.gdpaint)"])
	dlg.current_dir = OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
	root.add_child.call_deferred(dlg)
	return dlg

func _ensure_project_load_dialog() -> FileDialog:
	var root := _parent.get_parent()
	if root.has_node(^"LoadProjectDialog"):
		return root.get_node(^"LoadProjectDialog")
	var dlg := FileDialog.new()
	dlg.name = "LoadProjectDialog"
	dlg.access = FileDialog.ACCESS_FILESYSTEM
	dlg.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	dlg.filters = PackedStringArray(["*.gdpaint,;GD Paint Project (*.gdpaint)"])
	dlg.current_dir = OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
	root.add_child.call_deferred(dlg)
	return dlg


func _unhandled_input(event):
	# Trigger undo when Ctrl+Z (or Cmd+Z) is pressed.
	if event is InputEventKey and event.pressed and not event.echo:
		if (event.ctrl_pressed or event.meta_pressed) and event.keycode == KEY_Z:
			paint_control.undo_stroke()


func _on_tab_name_submitted(txt: String) -> void:
	if paint_control and paint_control.has_method(&"rename_active_canvas"):
		paint_control.rename_active_canvas(txt)
		# keep LineEdit text normalized by whatever rename applied
		if tab_name_line_edit and paint_control.has_method(&"get_active_canvas_title"):
			tab_name_line_edit.text = paint_control.get_active_canvas_title()

func _on_tab_name_focus_exited() -> void:
	# Commit any edits on focus loss
	if tab_name_line_edit:
		_on_tab_name_submitted(tab_name_line_edit.text)

func _on_active_canvas_changed(_idx: int, title: String) -> void:
	if tab_name_line_edit:
		tab_name_line_edit.text = title
	if depth_slider and paint_control:
		var idx: int = paint_control.active_canvas_index
		if idx >= 0 and idx < paint_control.canvases.size():
			depth_slider.set_block_signals(true)
			depth_slider.value = paint_control.canvases[idx].depth
			depth_slider.set_block_signals(false)
	_update_resolution_fields()

func _on_depth_changed(value: float) -> void:
	if paint_control and paint_control.has_method(&"set_active_canvas_depth"):
		paint_control.set_active_canvas_depth(value)
		_update_depth_label()

func _on_canvas_depth_changed(index: int, value: float) -> void:
	# if the active canvas changed depth externally, mirror in slider
	if paint_control and index == paint_control.active_canvas_index and depth_slider:
		depth_slider.set_block_signals(true)
		depth_slider.value = value
		depth_slider.set_block_signals(false)

	_update_depth_label()

func _init_opacity_values_from_paint() -> void:
	if paint_control == null:
		return
	# Read current falloff values if available, else defaults
	var above := 0.7
	var below := 0.7
	if paint_control.has_method(&"get_preview_above_falloff"):
		above = float(paint_control.get_preview_above_falloff())
	if paint_control.has_method(&"get_preview_below_falloff"):
		below = float(paint_control.get_preview_below_falloff())
	if slider_opacity_above:
		slider_opacity_above.set_block_signals(true)
		slider_opacity_above.value = clampf(above, 0.0, 1.0)
		slider_opacity_above.set_block_signals(false)
	if slider_opacity_below:
		slider_opacity_below.set_block_signals(true)
		slider_opacity_below.value = clampf(below, 0.0, 1.0)
		slider_opacity_below.set_block_signals(false)
	_update_opacity_labels()

func _on_above_falloff_changed(value: float) -> void:
	if paint_control and paint_control.has_method(&"set_preview_above_falloff"):
		paint_control.set_preview_above_falloff(float(value))
	_update_opacity_labels()

func _on_below_falloff_changed(value: float) -> void:
	if paint_control and paint_control.has_method(&"set_preview_below_falloff"):
		paint_control.set_preview_below_falloff(float(value))
	_update_opacity_labels()

func _update_opacity_labels() -> void:
	if label_opacity_above and slider_opacity_above:
		label_opacity_above.text = "Opacity above falloff: %d%%" % int(round(slider_opacity_above.value * 100.0))
	if label_opacity_below and slider_opacity_below:
		label_opacity_below.text = "Opacity below falloff: %d%%" % int(round(slider_opacity_below.value * 100.0))

func _update_depth_label() -> void:
	if depth_label and paint_control:
		var idx: int = paint_control.active_canvas_index
		if idx >= 0 and idx < paint_control.canvases.size():
			depth_label.text = "Depth: %.2f" % paint_control.canvases[idx].depth

func _update_resolution_fields() -> void:
	if res_w_spin == null or res_h_spin == null or paint_control == null:
		return
	var idx: int = paint_control.active_canvas_index
	if idx >= 0 and idx < paint_control.canvases.size():
		var c: PaintCanvasState = paint_control.canvases[idx]
		res_w_spin.set_block_signals(true)
		res_h_spin.set_block_signals(true)
		res_w_spin.value = int(c.canvas_resolution.x)
		res_h_spin.value = int(c.canvas_resolution.y)
		res_w_spin.set_block_signals(false)
		res_h_spin.set_block_signals(false)

func _on_apply_resolution() -> void:
	if paint_control and paint_control.has_method(&"resize_active_canvas") and res_w_spin and res_h_spin:
		paint_control.resize_active_canvas(int(res_w_spin.value), int(res_h_spin.value))
