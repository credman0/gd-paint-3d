class_name ImageUtil

# Generates an SDF from 'src' and returns an image that is bg_color
# wherever distance_to_nearest_foreground <= radius, else transparent.
# Foreground is defined by alpha >= alpha_threshold.
static func sdf_flood_fill(src: Image, radius: float, bg_color: Color, alpha_threshold := 0.5) -> Image:
	# ---- validate ----
	assert(src != null)
	var w := src.get_width()
	var h := src.get_height()
	assert(w > 0 and h > 0)
	assert(radius >= 0.0)

	# ---- build binary mask: 0 where foreground, INF elsewhere ----
	var inf := 1.0e20
	var fgrid := PackedFloat32Array()
	fgrid.resize(w * h)

	# src.lock()
	for y in range(h):
		for x in range(w):
			var a := src.get_pixel(x, y).a
			var idx := y * w + x
			fgrid[idx] = 0.0 if a >= alpha_threshold else inf
	# src.unlock()

	# ---- vertical pass (per column) ----
	var tmp := PackedFloat32Array()
	tmp.resize(w * h)
	for x in range(w):
		var col := PackedFloat32Array()
		col.resize(h)
		for y in range(h):
			col[y] = fgrid[y * w + x]
		var dcol := _edt_1d(col, h)
		for y in range(h):
			tmp[y * w + x] = dcol[y]

	# ---- horizontal pass (per row) ----
	var dist2 := PackedFloat32Array()
	dist2.resize(w * h)
	for y in range(h):
		var row := PackedFloat32Array()
		row.resize(w)
		for x in range(w):
			row[x] = tmp[y * w + x]
		var drow := _edt_1d(row, w)
		for x in range(w):
			dist2[y * w + x] = drow[x]  # still squared distance

	# ---- threshold by radius and compose output ----
	var r2 := radius * radius
	var out := Image.create(w, h, false, Image.FORMAT_RGBA8)
	# out.lock()
	var transparent := Color(0, 0, 0, 0)
	for y in range(h):
		for x in range(w):
			var idx := y * w + x
			# If any foreground pixel is within 'radius'
			if dist2[idx] <= r2:
				out.set_pixel(x, y, bg_color)
			else:
				out.set_pixel(x, y, transparent)
	# out.unlock()
	return out

# ---- helpers: 1D exact EDT by Felzenszwalb & Huttenlocher (squared distances) ----
static func _edt_1d(f: PackedFloat32Array, n: int) -> PackedFloat32Array:
	var k := 0
	var v := PackedInt32Array()
	v.resize(n)
	var z := PackedFloat32Array()
	z.resize(n + 1)
	var d := PackedFloat32Array()
	d.resize(n)

	v[0] = 0
	z[0] = -INF
	z[1] = INF

	for q in range(1, n):
		var s := 0.0
		while true:
			# intersection with parabola at v[k]
			var vk := v[k]
			s = ((f[q] + q * q) - (f[vk] + vk * vk)) / (2.0 * q - 2.0 * vk)
			if s > z[k]:
				break
			k -= 1
			if k < 0:
				k = 0
				break
		k += 1
		v[k] = q
		z[k] = s
		z[k + 1] = INF

	# Reset k before evaluation pass
	k = 0
	for q in range(0, n):
		while z[k + 1] < q:
			k += 1
		var dist := q - float(v[k])
		d[q] = dist * dist + f[v[k]]
	return d

# Fills all enclosed background regions (holes) with `fill_color`.
# Foreground is alpha >= alpha_threshold. Background is alpha < alpha_threshold.
# Connectivity: 4 or 8.
static func fill_enclosed_areas(src: Image, fill_color: Color, alpha_threshold := 0.5, connectivity := 4) -> Image:
	assert(src != null)
	var w := src.get_width()
	var h := src.get_height()
	assert(w > 0 and h > 0)
	assert(connectivity == 4 or connectivity == 8)

	# Build background mask
	var bg := PackedByteArray() # 1 = background, 0 = foreground
	bg.resize(w * h)
	# src.lock()
	for y in range(h):
		for x in range(w):
			var idx := y * w + x
			bg[idx] = 1 if src.get_pixel(x, y).a < alpha_threshold else 0
	# src.unlock()

	# Mark outside-connected background via BFS from borders
	var outside := PackedByteArray() # 1 = outside background, 0 = unknown/inside
	outside.resize(w * h)
	var q := [] # int queue of linear indices
	q.resize(0)

	# Helper to enqueue if background and not yet marked
	var _try_enqueue := func(ix: int, iy: int) -> void:
		if ix < 0 or iy < 0 or ix >= w or iy >= h:
			return
		var i := iy * w + ix
		if bg[i] == 1 and outside[i] == 0:
			outside[i] = 1
			q.push_back(i)

	# Seed with all border pixels that are background
	for x in range(w):
		_try_enqueue.call(x, 0)
		_try_enqueue.call(x, h - 1)
	for y in range(h):
		_try_enqueue.call(0, y)
		_try_enqueue.call(w - 1, y)

	# Neighborhood
	var dirs := [[1,0],[-1,0],[0,1],[0,-1]]
	if connectivity == 8:
		dirs += [[1,1],[1,-1],[-1,1],[-1,-1]]

	# BFS flood from border background
	var head := 0
	while head < q.size():
		var idx: int = q[head]
		head += 1
		var x := idx % w
		var y := floori(float(idx) / float(w))
		for d in dirs:
			_try_enqueue.call(x + d[0], y + d[1])

	# Fill enclosed background (bg==1 and not outside)
	var out := src.duplicate()
	# out.lock()
	for y in range(h):
		for x in range(w):
			var i := y * w + x
			if bg[i] == 1 and outside[i] == 0:
				out.set_pixel(x, y, fill_color)
	# out.unlock()
	return out


# Computes the smallest axis-aligned bounding box that contains all non-transparent
# pixels (alpha >= alpha_threshold) across the provided images, assuming they are
# all aligned to the same origin.
# Returns an empty Rect2i (size 0,0) if no non-transparent pixels are found.
static func compute_combined_bounds(images: Array, alpha_threshold := 0.5) -> Rect2i:
	assert(images != null)
	if images.is_empty():
		return Rect2i(0, 0, 0, 0)

	var min_x := 2147483647
	var min_y := 2147483647
	var max_x := -1
	var max_y := -1

	for img in images:
		if img == null:
			continue
		var image: Image = img as Image
		if image == null:
			continue
		var w: int = image.get_width()
		var h: int = image.get_height()
		if w <= 0 or h <= 0:
			continue
		# img.lock()
		for y in range(h):
			for x in range(w):
				if image.get_pixel(x, y).a >= alpha_threshold:
					if x < min_x:
						min_x = x
					if y < min_y:
						min_y = y
					if x > max_x:
						max_x = x
					if y > max_y:
						max_y = y
		# img.unlock()

	if max_x < 0 or max_y < 0:
		return Rect2i(0, 0, 0, 0)

	# Convert inclusive max to size
	return Rect2i(min_x, min_y, max(0, max_x - min_x + 1), max(0, max_y - min_y + 1))


# Crops each image to the given bounding box and uniformly scales the cropped region
# so that it fits within target_size while preserving aspect ratio.
# Returns a new Array of Images, one per input image. Areas outside the image bounds
# during cropping are treated as transparent. Each returned image has exactly target_size.
# If bbox is empty or target_size has non-positive dimensions, returns empty array.
static func scale_images_to_fit_from_bbox(images: Array, bbox: Rect2i, target_size: Vector2i, interpolation: int = Image.INTERPOLATE_BILINEAR) -> Array:
	assert(images != null)
	var result := []
	if bbox.size.x <= 0 or bbox.size.y <= 0:
		return result
	if target_size.x <= 0 or target_size.y <= 0:
		return result

	# Compute uniform scale to fit bbox into target_size while preserving aspect ratio.
	var sx: float = float(target_size.x) / float(bbox.size.x)
	var sy: float = float(target_size.y) / float(bbox.size.y)
	var scale: float = min(sx, sy)
	var scaled_w: int = int(round(float(bbox.size.x) * scale))
	var scaled_h: int = int(round(float(bbox.size.y) * scale))
	scaled_w = max(1, scaled_w)
	scaled_h = max(1, scaled_h)

	for img in images:
		if img == null:
			result.push_back(null)
			continue
		var image: Image = img as Image
		if image == null:
			result.push_back(null)
			continue

		# Prepare a transparent crop the size of the bbox, then blit the intersection
		var cropped: Image = Image.create(bbox.size.x, bbox.size.y, false, Image.FORMAT_RGBA8)
		cropped.fill(Color(0, 0, 0, 0))

		# Intersect bbox with image bounds (bbox is in the same origin as image)
		var src_rect := Rect2i(0, 0, image.get_width(), image.get_height())
		var isect := bbox.intersection(src_rect)
		if isect.size.x > 0 and isect.size.y > 0:
			var dst_pos := isect.position - bbox.position
			# blit the portion from source image into the cropped canvas
			cropped.blit_rect(image, isect, dst_pos)

		# Resize uniformly to scaled size
		cropped.resize(scaled_w, scaled_h, interpolation)

		# Compose final image of exactly target_size, centering the scaled content and padding with transparency
		var out_img: Image = Image.create(target_size.x, target_size.y, false, Image.FORMAT_RGBA8)
		out_img.fill(Color(0, 0, 0, 0))
		var dst_x := int(floor((float(target_size.x) - float(scaled_w)) * 0.5))
		var dst_y := int(floor((float(target_size.y) - float(scaled_h)) * 0.5))
		if scaled_w > 0 and scaled_h > 0:
			out_img.blit_rect(cropped, Rect2i(0, 0, scaled_w, scaled_h), Vector2i(dst_x, dst_y))

		result.push_back(out_img)

	return result
