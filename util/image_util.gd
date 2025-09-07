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
