extends MarginContainer

@onready var composited_scene: CompositedScene = %CompositedScene
@onready var layer_list: ItemList = %LayerList
@onready var depth_slider: HSlider = %DepthSlider

var _selected_index: int = -1

func _ready() -> void:
	_populate_layers()
	layer_list.item_selected.connect(_on_layer_selected)
	depth_slider.value_changed.connect(_on_depth_changed)
	if composited_scene:
		composited_scene.layers_updated.connect(_on_layers_updated)
		composited_scene.depth_changed.connect(_on_depth_changed_external)
	if composited_scene and composited_scene.layers.size() > 0:
		layer_list.select(0)
		_on_layer_selected(0)
	else:
		_update_controls_enabled()

func _populate_layers() -> void:
	layer_list.clear()
	if composited_scene == null:
		return
	for i in range(composited_scene.layers.size()):
		var layer: PaintedLayer = composited_scene.layers[i]
		var layer_label := layer.layer_name if layer.layer_name != "" else "Layer %d" % i
		layer_list.add_item(layer_label)

func _on_layer_selected(index: int) -> void:
	_selected_index = index
	_sync_depth_ui()
	_update_controls_enabled()

func _sync_depth_ui() -> void:
	if _selected_index < 0 or _selected_index >= composited_scene.layers.size():
		return
	var layer: PaintedLayer = composited_scene.layers[_selected_index]
	# Depth in PaintedLayer is positive forward; CompositedScene stores in depths
	depth_slider.set_block_signals(true)
	depth_slider.value = layer.depth
	depth_slider.set_block_signals(false)

func _on_depth_changed(value: float) -> void:
	if _selected_index < 0:
		return
	composited_scene.set_depth(_selected_index, value)
	# reflect immediately in UI list if needed later

func _update_controls_enabled() -> void:
	var enabled := _selected_index >= 0
	depth_slider.mouse_filter = Control.MOUSE_FILTER_PASS if enabled else Control.MOUSE_FILTER_IGNORE
	depth_slider.modulate.a = 1.0 if enabled else 0.5

func _on_layers_updated() -> void:
	var prev := _selected_index
	_populate_layers()
	if prev >= 0 and prev < composited_scene.layers.size():
		_selected_index = prev
		layer_list.select(prev)
		_sync_depth_ui()
	else:
		_selected_index = -1
		_update_controls_enabled()

func _on_depth_changed_external(index: int, value: float) -> void:
	if index == _selected_index:
		depth_slider.set_block_signals(true)
		depth_slider.value = value
		depth_slider.set_block_signals(false)
