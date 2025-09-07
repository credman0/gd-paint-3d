class_name CompositedScene extends Node3D

signal layers_updated
signal depth_changed(index: int, depth: float)

@onready var camera: Camera3D = %Camera3D
@onready var layers_parent: Node3D = %Layers

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
		# Depth and name come from the canvas itself
		layer.set_depth(canvases[i].depth)
		var nm := canvases[i].canvas_name
		if nm == "":
			nm = (names[i] if i < names.size() else "")
		layer.layer_name = nm if nm != "" else "Layer " + str(i)
		layers_parent.add_child(layer)
		layers.append(layer)

	emit_signal("layers_updated")

func set_depth(index: int, depth: float) -> void:
	if index < 0 or index >= layers.size():
		return
	# No-op if unchanged to prevent feedback loops
	if layers[index].depth == depth:
		return
	# Update both the layer node and its backing canvas for persistence
	layers[index].set_depth(depth)
	if layers[index].canvas:
		layers[index].canvas.depth = depth
	emit_signal("depth_changed", index, depth)

# --- glTF (JSON .gltf) Export -------------------------------------------------

## Export the current composited scene as a glTF 2.0 JSON (.gltf) file with
## embedded PNG images and buffers. Each layer becomes a textured quad placed
## at its depth (negative Z like in the runtime).
## pixels_per_unit controls size normalization (e.g., 1024 -> a 1024x1024 image is 1x1 units).
## If scale_depth is true, the same normalization is applied to Z translation.
func export_gltf(path: String, pixels_per_unit: float = 1024.0, scale_depth: bool = false) -> int:
	var doc := _build_gltf_document(pixels_per_unit, scale_depth)
	if doc.is_empty():
		return ERR_INVALID_DATA
	var json := JSON.stringify(doc, "\t")
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return ERR_CANT_OPEN
	f.store_string(json)
	f.flush()
	f.close()
	return OK

func _build_gltf_document(pixels_per_unit: float, scale_depth: bool) -> Dictionary:
	var gltf: Dictionary = {
		"asset": {"version": "2.0", "generator": "gdpaint-composited-scene"},
		"extensionsUsed": ["KHR_materials_unlit"],
		"scenes": [],
		"scene": 0,
		"nodes": [],
		"meshes": [],
		"materials": [],
		"textures": [],
		"images": [],
		"samplers": [{
			"magFilter": 9729, # LINEAR
			"minFilter": 9729, # LINEAR
			"wrapS": 10497,    # REPEAT
			"wrapT": 10497     # REPEAT
		}],
		"buffers": [],
		"bufferViews": [],
		"accessors": [],
	}

	var scene_node_indices: Array[int] = []

	# Early out: nothing to export
	if layers.size() == 0:
		gltf.scenes = [{"nodes": []}]
		return gltf

	# --- Pre-scale images using ImageUtil helpers ---
	# Collect exportable layers and their source images
	var export_indices: Array[int] = []
	var src_images: Array = []
	var max_canvas_w: int = 0
	var max_canvas_h: int = 0
	for i in range(layers.size()):
		var layer_i: PaintedLayer = layers[i]
		if layer_i == null or layer_i.canvas == null or layer_i.canvas.canvas_img == null:
			continue
		export_indices.append(i)
		src_images.append(layer_i.canvas.canvas_img)
		var res: Vector2 = layer_i.canvas.canvas_resolution
		max_canvas_w = max(max_canvas_w, int(res.x))
		max_canvas_h = max(max_canvas_h, int(res.y))

	var scaled_map := {}
	if export_indices.size() > 0 and max_canvas_w > 0 and max_canvas_h > 0:
		var bbox: Rect2i = ImageUtil.compute_combined_bounds(src_images, 0.5)
		if bbox.size.x > 0 and bbox.size.y > 0:
			var target_size := Vector2i(max_canvas_w, max_canvas_h)
			var scaled_list: Array = ImageUtil.scale_images_to_fit_from_bbox(src_images, bbox, target_size, Image.INTERPOLATE_BILINEAR)
			if scaled_list.size() == export_indices.size():
				for j in range(export_indices.size()):
					scaled_map[export_indices[j]] = scaled_list[j]

	for i in range(layers.size()):
		var layer: PaintedLayer = layers[i]
		if layer == null or layer.canvas == null or layer.canvas.canvas_img == null:
			continue

		var layer_name_ := layer.layer_name if layer.layer_name != "" else "Layer %d" % i

		# Use pre-scaled image if available, else fall back to original
		var src_img: Image = layer.canvas.canvas_img
		if scaled_map.has(i):
			var cand: Image = scaled_map[i]
			if cand != null:
				src_img = cand
		var w_px := float(src_img.get_width())
		var h_px := float(src_img.get_height())
		var inv_ppu: float = 1.0 / max(pixels_per_unit, 1.0)
		var w: float = w_px * inv_ppu
		var h: float = h_px * inv_ppu

		# 1) Build a single-quad mesh buffer for this layer
		var quad := _build_textured_quad_bytes(w, h)
		var buffer_index: int = gltf.buffers.size()
		gltf.buffers.append({
			"byteLength": quad.bytes.size(),
			"uri": "data:application/octet-stream;base64," + Marshalls.raw_to_base64(quad.bytes),
			"name": layer_name_ + "_buf"
		})

		# BufferViews
		var bv_pos: int = gltf.bufferViews.size()
		gltf.bufferViews.append({
			"buffer": buffer_index,
			"byteOffset": quad.pos_offset,
			"byteLength": quad.pos_length,
			"target": 34962 # ARRAY_BUFFER
		})
		var bv_uv: int = gltf.bufferViews.size()
		gltf.bufferViews.append({
			"buffer": buffer_index,
			"byteOffset": quad.uv_offset,
			"byteLength": quad.uv_length,
			"target": 34962 # ARRAY_BUFFER
		})
		var bv_idx: int = gltf.bufferViews.size()
		gltf.bufferViews.append({
			"buffer": buffer_index,
			"byteOffset": quad.idx_offset,
			"byteLength": quad.idx_length,
			"target": 34963 # ELEMENT_ARRAY_BUFFER
		})

		# Accessors
		var minx: float = -w * 0.5
		var maxx: float = w * 0.5
		var miny: float = -h * 0.5
		var maxy: float = h * 0.5
		var acc_pos: int = gltf.accessors.size()
		gltf.accessors.append({
			"bufferView": bv_pos,
			"componentType": 5126, # FLOAT
			"count": 4,
			"type": "VEC3",
			"min": [minx, miny, 0.0],
			"max": [maxx, maxy, 0.0]
		})
		var acc_uv: int = gltf.accessors.size()
		gltf.accessors.append({
			"bufferView": bv_uv,
			"componentType": 5126, # FLOAT
			"count": 4,
			"type": "VEC2"
		})
		var acc_idx: int = gltf.accessors.size()
		gltf.accessors.append({
			"bufferView": bv_idx,
			"componentType": 5123, # UNSIGNED_SHORT
			"count": 6,
			"type": "SCALAR"
		})

		# Image/Texture/Material
		# Compose a white SDF-based fill (10px) behind the layer before export
		var img_to_export: Image = _composite_with_sdf_fill(src_img, 10.0, Color(1, 1, 1, 1))
		var img_b64 := Marshalls.raw_to_base64(img_to_export.save_png_to_buffer())
		var img_index: int = gltf.images.size()
		gltf.images.append({
			"uri": "data:image/png;base64," + img_b64,
			"mimeType": "image/png",
			"name": layer_name_ + "_img"
		})
		var tex_index: int = gltf.textures.size()
		gltf.textures.append({
			"sampler": 0,
			"source": img_index,
			"name": layer_name_ + "_tex"
		})
		var mat_index: int = gltf.materials.size()
		gltf.materials.append({
			"name": layer_name_ + "_mat",
			"pbrMetallicRoughness": {
				"baseColorTexture": {"index": tex_index},
				"metallicFactor": 0.0,
				"roughnessFactor": 1.0
			},
			"doubleSided": true,
			"alphaMode": "BLEND",
			"extensions": {"KHR_materials_unlit": {}}
		})

		# Mesh
		var mesh_index: int = gltf.meshes.size()
		gltf.meshes.append({
			"name": layer_name_ + "_mesh",
			"primitives": [{
				"attributes": {
					"POSITION": acc_pos,
					"TEXCOORD_0": acc_uv
				},
				"indices": acc_idx,
				"material": mat_index,
				"mode": 4 # TRIANGLES
			}]
		})

		# Node placed at negative Z depth (as shown in runtime)
		var node_index: int = gltf.nodes.size()
		gltf.nodes.append({
			"name": layer_name_,
			"mesh": mesh_index,
			"translation": [0.0, 0.0, -(float(layer.depth) * (inv_ppu if scale_depth else 1.0))]
		})
		scene_node_indices.append(node_index)

	gltf.scenes = [{"nodes": scene_node_indices}]
	return gltf

static func _composite_with_sdf_fill(src: Image, radius: float, fill_color: Color, alpha_threshold := 0.5) -> Image:
	if src == null:
		return Image.new()
	var w := src.get_width()
	var h := src.get_height()
	if w <= 0 or h <= 0:
		return Image.new()

	# Generate background fill where within 'radius' of any opaque pixel
	var fill_img: Image = ImageUtil.sdf_flood_fill(src, radius, fill_color, alpha_threshold)
	var enclosed_img: Image = ImageUtil.fill_enclosed_areas(fill_img, fill_color, alpha_threshold)

	# Composite: src over (enclosed over fill)
	var out := Image.create(w, h, false, Image.FORMAT_RGBA8)
	# out.lock()
	# src.lock()
	# fill_img.lock()
	# enclosed_img.lock()
	for y in range(h):
		for x in range(w):
			# Compose enclosed_img over fill_img to form the final background
			var enc := enclosed_img.get_pixel(x, y)
			var fl := fill_img.get_pixel(x, y)
			var bg_a := clampf(enc.a + fl.a * (1.0 - enc.a), 0.0, 1.0)
			var bg_r := 0.0
			var bg_g := 0.0
			var bg_b := 0.0
			if bg_a > 0.0:
				bg_r = (enc.r * enc.a + fl.r * fl.a * (1.0 - enc.a)) / bg_a
				bg_g = (enc.g * enc.a + fl.g * fl.a * (1.0 - enc.a)) / bg_a
				bg_b = (enc.b * enc.a + fl.b * fl.a * (1.0 - enc.a)) / bg_a
			var bg := Color(bg_r, bg_g, bg_b, bg_a)

			# Now composite src over that background (straight alpha)
			var fg := src.get_pixel(x, y)
			var out_a: float = clampf(fg.a + bg.a * (1.0 - fg.a), 0.0, 1.0)
			var out_r: float = 0.0
			var out_g: float = 0.0
			var out_b: float = 0.0
			if out_a > 0.0:
				out_r = (fg.r * fg.a + bg.r * bg.a * (1.0 - fg.a)) / out_a
				out_g = (fg.g * fg.a + bg.g * bg.a * (1.0 - fg.a)) / out_a
				out_b = (fg.b * fg.a + bg.b * bg.a * (1.0 - fg.a)) / out_a
			out.set_pixel(x, y, Color(out_r, out_g, out_b, out_a))
	# enclosed_img.unlock()
	# fill_img.unlock()
	# src.unlock()
	# out.unlock()
	return out

static func _align4(n: int) -> int:
	var r := n % 4
	return n if r == 0 else (n + (4 - r))

static func _build_textured_quad_bytes(width: float, height: float) -> Dictionary:
	# Build a single quad centered at origin, lying on the XY plane (Z=0):
	# v0(-w/2,  h/2)  v1(w/2,  h/2)
	# v3(-w/2, -h/2)  v2(w/2, -h/2)
	# UVs are mapped so that top-left of the image is (0,0).
	var hw := width * 0.5
	var hh := height * 0.5

	var sp_pos := StreamPeerBuffer.new()
	sp_pos.big_endian = false
	# v0
	sp_pos.put_float(-hw); sp_pos.put_float(hh); sp_pos.put_float(0.0)
	# v1
	sp_pos.put_float(hw); sp_pos.put_float(hh); sp_pos.put_float(0.0)
	# v2
	sp_pos.put_float(hw); sp_pos.put_float(-hh); sp_pos.put_float(0.0)
	# v3
	sp_pos.put_float(-hw); sp_pos.put_float(-hh); sp_pos.put_float(0.0)
	var bytes_pos: PackedByteArray = sp_pos.get_data_array()

	var sp_uv := StreamPeerBuffer.new()
	sp_uv.big_endian = false
	# Using V=0 at top to match typical 2D image coordinates
	sp_uv.put_float(0.0); sp_uv.put_float(0.0) # v0
	sp_uv.put_float(1.0); sp_uv.put_float(0.0) # v1
	sp_uv.put_float(1.0); sp_uv.put_float(1.0) # v2
	sp_uv.put_float(0.0); sp_uv.put_float(1.0) # v3
	var bytes_uv: PackedByteArray = sp_uv.get_data_array()

	var sp_idx := StreamPeerBuffer.new()
	sp_idx.big_endian = false
	# Two triangles: (0,1,2) and (0,2,3)
	sp_idx.put_u16(0); sp_idx.put_u16(1); sp_idx.put_u16(2)
	sp_idx.put_u16(0); sp_idx.put_u16(2); sp_idx.put_u16(3)
	var bytes_idx: PackedByteArray = sp_idx.get_data_array()

	# Concatenate with 4-byte alignment between views
	var pos_offset := 0
	var uv_offset := _align4(bytes_pos.size())
	var idx_offset := _align4(uv_offset + bytes_uv.size())
	var _total_len := idx_offset + bytes_idx.size()

	var all_bytes := PackedByteArray()
	# Positions
	all_bytes.append_array(bytes_pos)
	all_bytes.resize(uv_offset) # pad with zeros to UV offset
	# UVs
	all_bytes.append_array(bytes_uv)
	all_bytes.resize(idx_offset) # pad to index offset
	# Indices
	all_bytes.append_array(bytes_idx)

	return {
		"bytes": all_bytes,
		"pos_offset": pos_offset,
		"pos_length": bytes_pos.size(),
		"uv_offset": uv_offset,
		"uv_length": bytes_uv.size(),
		"idx_offset": idx_offset,
		"idx_length": bytes_idx.size(),
	}
