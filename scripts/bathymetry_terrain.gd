@tool
class_name BathymetryTerrain
extends MeshInstance3D
## Builds a seafloor mesh from the heightmap made by tools/convert_bathymetry.py.
## With fill_gaps on, it uses the gap-filled grid from tools/fill_gaps.py and
## shades the public-data areas more muted so the ship's own data stands out.
## World units are kilometres by default; the mesh is centred on the origin.
## +X is east, -Z is north.

@export_file("*.json") var metadata_path := "res://data/bathy.json"
@export_file("*.r32") var heights_path := "res://data/bathy.r32"
## Fill gaps between swaths with SRTM15+ (needs tools/fill_gaps.py output).
@export var fill_gaps := true:
	set(v): fill_gaps = v; heights.clear(); _queue_rebuild()
## How muted the filled areas look. 0 = same as ship data.
@export_range(0.0, 1.0) var fill_tint := 0.55:
	set(v): fill_tint = v; _queue_rebuild()
## Use every Nth grid cell. 1 = full 75 m resolution (about 14M vertices, heavy).
@export_range(1, 32) var step := 4:
	set(v): step = v; _queue_rebuild()
@export var meters_per_unit := 1000.0:
	set(v): meters_per_unit = v; _queue_rebuild()
@export var vertical_exaggeration := 3.0:
	set(v): vertical_exaggeration = v; _queue_rebuild()
@export_tool_button("Rebuild") var rebuild_button := rebuild

signal rebuilt

var meta: Dictionary
var heights: PackedFloat32Array
## 255 where the ship measured the depth, 0 where it was filled. Empty if not filled.
var source_mask: PackedByteArray
var _pending := false
var _center := Vector2.ZERO  # grid (col,row) that sits at the world origin


func _ready() -> void:
	rebuild()


func _queue_rebuild() -> void:
	if is_inside_tree() and not _pending:
		_pending = true
		rebuild.call_deferred()


func load_data() -> bool:
	var text := FileAccess.get_file_as_string(metadata_path)
	if text.is_empty():
		push_error("Bathymetry: cannot read %s (run tools/convert_bathymetry.py)" % metadata_path)
		return false
	meta = JSON.parse_string(text)
	var path := heights_path
	source_mask = PackedByteArray()
	if fill_gaps:
		if meta.has("filled"):
			var dir := metadata_path.get_base_dir()
			path = dir.path_join(meta.filled.heights)
			source_mask = FileAccess.get_file_as_bytes(dir.path_join(meta.filled.source_mask))
		else:
			push_warning("Bathymetry: no gap-filled grid yet (run tools/fill_gaps.py)")
	heights = FileAccess.get_file_as_bytes(path).to_float32_array()
	return heights.size() == int(meta.width) * int(meta.height)


## Depth in metres at a grid cell, or NAN where there is no sounding.
func depth_at(col: int, row: int) -> float:
	var d := heights[row * int(meta.width) + col]
	return NAN if d <= float(meta.nodata) + 1.0 else d


## True where the ship measured this cell (always true when not gap-filled).
func is_measured(col: int, row: int) -> bool:
	return source_mask.is_empty() or source_mask[row * int(meta.width) + col] > 127


func world_per_meter() -> float:
	return 1.0 / meters_per_unit


func world_y(depth_m: float) -> float:
	return depth_m * vertical_exaggeration / meters_per_unit


## Grid (col,row), fractional, to local position on the y=0 plane.
func grid_to_world(cr: Vector2) -> Vector3:
	var s: float = meta.cell_size_m[0] / meters_per_unit
	return Vector3((cr.x - _center.x) * s, 0.0, (cr.y - _center.y) * s)


func world_to_grid(p: Vector3) -> Vector2:
	var s: float = meta.cell_size_m[0] / meters_per_unit
	return Vector2(p.x / s + _center.x, p.z / s + _center.y)


## UTM 53N easting/northing (m) to local position on the y=0 plane.
func utm_to_world(easting: float, northing: float) -> Vector3:
	var cs: float = meta.cell_size_m[0]
	var o: Array = meta.origin_utm_top_left
	return grid_to_world(Vector2((easting - o[0]) / cs - 0.5, (o[1] - northing) / cs - 0.5))


## Bilinear depth in metres under a local position, or NAN off the grid / no data.
func depth_at_world(p: Vector3) -> float:
	var g := world_to_grid(p)
	var w := int(meta.width)
	var h := int(meta.height)
	if g.x < 0 or g.y < 0 or g.x > w - 1 or g.y > h - 1:
		return NAN
	var c := mini(int(g.x), w - 2)
	var r := mini(int(g.y), h - 2)
	var fx := g.x - c
	var fy := g.y - r
	var a := depth_at(c, r)
	var b := depth_at(c + 1, r)
	var d := depth_at(c, r + 1)
	var e := depth_at(c + 1, r + 1)
	return lerpf(lerpf(a, b, fx), lerpf(d, e, fx), fy)


## First point where a local-space ray hits the terrain, or null.
func intersect_ray(origin: Vector3, dir: Vector3, max_dist := 5000.0) -> Variant:
	dir = dir.normalized()
	var ytop := world_y(float(meta.get("filled", meta).depth_max_m)) + 0.01
	var ybot := world_y(float(meta.get("filled", meta).depth_min_m)) - 0.01
	# Only march the part of the ray between the highest and lowest terrain.
	var t0 := 0.0
	var t1 := max_dist
	if absf(dir.y) > 1e-6:
		var ta := (ytop - origin.y) / dir.y
		var tb := (ybot - origin.y) / dir.y
		t0 = maxf(0.0, minf(ta, tb))
		t1 = minf(max_dist, maxf(ta, tb))
	elif origin.y > ytop or origin.y < ybot:
		return null
	var dt: float = meta.cell_size_m[0] / meters_per_unit * 0.5
	var prev := t0
	var t := t0
	while t <= t1:
		var p := origin + dir * t
		var d := depth_at_world(p)
		if not is_nan(d) and p.y <= world_y(d):
			# Refine between the last point above and this one.
			var lo := prev
			var hi := t
			for i in 12:
				var mid := (lo + hi) * 0.5
				var q := origin + dir * mid
				var dq := depth_at_world(q)
				if not is_nan(dq) and q.y <= world_y(dq):
					hi = mid
				else:
					lo = mid
			return origin + dir * hi
		prev = t
		t += dt
	return null


func rebuild() -> void:
	_pending = false
	if heights.is_empty() and not load_data():
		return
	var w := int(meta.width)
	var h := int(meta.height)
	var gw := (w - 1) / step + 1
	var gh := (h - 1) / step + 1
	_center = Vector2((gw - 1) * step, (gh - 1) * step) * 0.5
	var cell: float = meta.cell_size_m[0] * step / meters_per_unit
	var vscale := vertical_exaggeration / meters_per_unit
	# Colour ramp spans the ship data's depth range so filled trenches don't wash it out.
	var dmin: float = meta.depth_min_m
	var dmax: float = 0.0
	var floor_d: float = meta.get("filled", meta).depth_min_m
	var half := Vector2((gw - 1) * cell, (gh - 1) * cell) * 0.5

	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	var valid := PackedByteArray()
	verts.resize(gw * gh)
	colors.resize(gw * gh)
	valid.resize(gw * gh)
	for r in gh:
		for c in gw:
			var i := r * gw + c
			var d := depth_at(c * step, r * step)
			var ok := not is_nan(d)
			valid[i] = 1 if ok else 0
			verts[i] = Vector3(c * cell - half.x, (d if ok else floor_d) * vscale, r * cell - half.y)
			var col := _land_color(d) if ok and d > 0.0 else _depth_color(inverse_lerp(dmin, dmax, d) if ok else 0.0)
			if ok and not source_mask.is_empty():
				var t := fill_tint * (1.0 - source_mask[c * step + r * step * w] / 255.0)
				var grey := col.get_luminance()
				col = col.lerp(Color(grey, grey, grey), t).darkened(t * 0.35)
			colors[i] = col

	# Normals from neighbouring heights (central differences).
	var normals := PackedVector3Array()
	normals.resize(gw * gh)
	for r in gh:
		for c in gw:
			var i := r * gw + c
			var l := verts[r * gw + maxi(c - 1, 0)] if valid[r * gw + maxi(c - 1, 0)] else verts[i]
			var rt := verts[r * gw + mini(c + 1, gw - 1)] if valid[r * gw + mini(c + 1, gw - 1)] else verts[i]
			var u := verts[maxi(r - 1, 0) * gw + c] if valid[maxi(r - 1, 0) * gw + c] else verts[i]
			var dn := verts[mini(r + 1, gh - 1) * gw + c] if valid[mini(r + 1, gh - 1) * gw + c] else verts[i]
			normals[i] = Vector3(l.y - rt.y, 2.0 * cell, u.y - dn.y).normalized()

	# Only emit triangles whose corners all have data.
	var indices := PackedInt32Array()
	for r in gh - 1:
		for c in gw - 1:
			var a := r * gw + c
			var b := a + 1
			var e := a + gw
			var f := e + 1
			if valid[a] and valid[f]:
				if valid[e]:
					indices.append_array([a, f, e])
				if valid[b]:
					indices.append_array([a, b, f])

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.vertex_color_is_srgb = true
	mat.roughness = 0.9
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.surface_set_material(0, mat)
	mesh = m
	print("Bathymetry: %dx%d grid, %d triangles%s" % [gw, gh, indices.size() / 3,
		" (gaps filled)" if not source_mask.is_empty() else ""])
	rebuilt.emit()


## Deep = dark blue, shallow = cyan/sand. Below the ramp's deep end it keeps darkening.
static func _depth_color(t: float) -> Color:
	var stops := [Color("0b1a3a"), Color("1f4e8c"), Color("2f9fb3"), Color("8fd6b4"), Color("e8d9a0")]
	if t < 0.0:
		return stops[0].darkened(clampf(-t, 0.0, 0.6))
	var x := clampf(t, 0.0, 1.0) * (stops.size() - 1)
	var i := mini(int(x), stops.size() - 2)
	return stops[i].lerp(stops[i + 1], x - i)


## Islands: green lowland to brown hills.
static func _land_color(elev: float) -> Color:
	return Color("4f7a3a").lerp(Color("8a7350"), clampf(elev / 300.0, 0.0, 1.0))
