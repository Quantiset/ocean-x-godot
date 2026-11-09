class_name WaterColumnProbe
extends Node3D
## Click the seafloor to see a water-column cylinder built from the ship's ADCP
## (data/adcp.json, made by tools/convert_adcp.py). ADCP only exists along the
## ship track (drawn on the seafloor), so the click snaps to the nearest
## 5-minute profile.
##   V  switch variable (current speed / backscatter)
##   T  show or hide the ADCP track
##   Esc  clear the cylinder

enum Variable { SPEED, BACKSCATTER }

@export var terrain: BathymetryTerrain
@export var camera: Camera3D
@export_file("*.json") var adcp_path := "res://data/adcp.json"
## Clicks farther than this from any ADCP profile are ignored.
@export var max_snap_km := 8.0
@export var radius_m := 600.0
## Arrow length per 1 m/s of current, in metres.
@export var arrow_m_per_mps := 6000.0
@export var variable := Variable.SPEED:
	set(v): variable = v; _refresh()

const VAR_INFO := {
	Variable.SPEED: {"name": "Current speed", "unit": "m/s", "fmt": "%.2f"},
	Variable.BACKSCATTER: {"name": "Relative backscatter", "unit": "dB, uncalibrated", "fmt": "%.0f"},
}
const NO_DATA := Color(0.35, 0.37, 0.4)

var depths: PackedFloat32Array
var profiles: Array
var ranges := {}  # Variable -> Vector2(min, max) for the colour scale
var current := -1  # index of the profile on display

var _positions := PackedVector2Array()  # profile x,z in local space
var _column: MeshInstance3D
var _track: MeshInstance3D
var _info: Label
var _legend: TextureRect
var _legend_lo: Label
var _legend_hi: Label
var _press_pos := Vector2.ZERO


func _ready() -> void:
	_build_ui()
	if not _load():
		return
	if terrain.mesh:
		_on_terrain_rebuilt()
	terrain.rebuilt.connect(_on_terrain_rebuilt)


func _load() -> bool:
	var text := FileAccess.get_file_as_string(adcp_path)
	if text.is_empty():
		_info.text = "No ADCP data. Run tools/convert_adcp.py"
		return false
	var data: Dictionary = JSON.parse_string(text)
	depths = PackedFloat32Array(data.depth_m)
	profiles = data.profiles
	for v in Variable.values():
		var vals: Array[float] = []
		for p in profiles:
			for k in depths.size():
				var x := _value(p, k, v)
				if not is_nan(x):
					vals.append(x)
		vals.sort()
		ranges[v] = Vector2(vals[int(vals.size() * 0.02)], vals[int(vals.size() * 0.98)])
	ranges[Variable.SPEED] = Vector2(0.0, ranges[Variable.SPEED].y)
	return true


func _on_terrain_rebuilt() -> void:
	_positions.resize(profiles.size())
	for i in profiles.size():
		var p := terrain.utm_to_world(profiles[i].easting, profiles[i].northing)
		_positions[i] = Vector2(p.x, p.z)
	_build_track()
	_refresh()


## Value of a variable at depth bin k, or NAN.
func _value(p: Dictionary, k: int, v: int) -> float:
	if v == Variable.SPEED:
		if p.u[k] == null:
			return NAN
		return Vector2(p.u[k], p.v[k]).length()
	return NAN if p.backscatter[k] == null else float(p.backscatter[k])


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_press_pos = event.position
		elif event.position.distance_to(_press_pos) < 4.0:
			probe_screen(event.position)
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_V:
				variable = ((variable + 1) % Variable.size()) as Variable
			KEY_T:
				_track.visible = not _track.visible
			KEY_ESCAPE:
				show_profile(-1)


## Cast a ray from the camera through a screen point and probe where it lands.
func probe_screen(screen_pos: Vector2) -> void:
	var from := terrain.to_local(camera.project_ray_origin(screen_pos))
	var dir := terrain.global_basis.inverse() * camera.project_ray_normal(screen_pos)
	var hit = terrain.intersect_ray(from, dir, camera.far)
	if hit == null:
		return
	var i := nearest_profile(Vector2(hit.x, hit.z))
	var km := _positions[i].distance_to(Vector2(hit.x, hit.z)) / terrain.world_per_meter() / 1000.0
	if km > max_snap_km:
		_info.text = "No ADCP data here (nearest ship track is %.0f km away).\nClick closer to the ship's path (thin line)." % km
		return
	show_profile(i, km)


func nearest_profile(xz: Vector2) -> int:
	var best := -1
	var best_d := INF
	for i in _positions.size():
		var d := _positions[i].distance_squared_to(xz)
		if d < best_d:
			best_d = d
			best = i
	return best


## Show profile i as a cylinder (-1 clears). snap_km is only used for the label.
func show_profile(i: int, snap_km := 0.0) -> void:
	current = i
	_refresh(snap_km)


func _refresh(snap_km := 0.0) -> void:
	if not is_node_ready() or profiles.is_empty():
		return
	var info: Dictionary = VAR_INFO[variable]
	var rng: Vector2 = ranges[variable]
	_legend.texture = _legend_texture(variable)
	_legend_lo.text = info.fmt % rng.x
	_legend_hi.text = (info.fmt % rng.y) + " " + info.unit
	_build_track()
	if current < 0:
		_column.mesh = null
		_info.text = "Water column: ship ADCP (75 kHz)\nClick the seafloor near the ship track.\n[V] variable  [T] track  [Esc] clear"
		return
	var p: Dictionary = profiles[current]
	var base := Vector3(_positions[current].x, 0.0, _positions[current].y)
	var floor_m := terrain.depth_at_world(base)
	_column.mesh = _build_column(p, floor_m)
	_column.position = base

	var good := 0
	var deepest := 0.0
	for k in depths.size():
		if not is_nan(_value(p, k, variable)):
			good += 1
			deepest = depths[k]
	var surf := _first_valid(p)
	var lines := [
		"%s: ship ADCP (75 kHz)" % info.name,
		"%s   %.4f°N  %.4f°E" % [p.time, p.lat, p.lon],
		"Seafloor %.0f m · data to %.0f m (%d bins)" % [-floor_m, deepest, good],
	]
	if surf >= 0:
		var uv := Vector2(p.u[surf], p.v[surf])
		lines.append("Near-surface current %.2f m/s toward %03.0f°" % [uv.length(), fposmod(rad_to_deg(atan2(uv.x, uv.y)), 360.0)])
	if snap_km > 0.05:
		lines.append("Snapped %.1f km to nearest profile" % snap_km)
	lines.append("[V] variable  [T] track  [Esc] clear")
	_info.text = "\n".join(lines)


func _first_valid(p: Dictionary) -> int:
	for k in depths.size():
		if p.u[k] != null:
			return k
	return -1


func color_for(v: int, x: float) -> Color:
	if is_nan(x):
		return NO_DATA
	var rng: Vector2 = ranges[v]
	return _ramp(v, inverse_lerp(rng.x, rng.y, x))


static func _ramp(v: int, t: float) -> Color:
	# Speed: dark purple -> teal -> yellow. Backscatter: black-red -> orange -> pale yellow.
	var stops := [Color("2c1e50"), Color("3b528b"), Color("21918c"), Color("5ec962"), Color("fde725")] \
		if v == Variable.SPEED else \
		[Color("1b0c41"), Color("721f81"), Color("cd4071"), Color("fb8761"), Color("fcfdbf")]
	var x := clampf(t, 0.0, 1.0) * (stops.size() - 1)
	var i := mini(int(x), stops.size() - 2)
	return stops[i].lerp(stops[i + 1], x - i)


func _build_column(p: Dictionary, floor_m: float) -> ArrayMesh:
	var r := radius_m * terrain.world_per_meter()
	var bin := depths[1] - depths[0] if depths.size() > 1 else 16.0
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Bands of colour, one per depth bin, then grey from the last bin to the seafloor.
	var top := 0.0
	for k in depths.size():
		var lo := minf(depths[k] + bin * 0.5, -floor_m)
		var c := color_for(variable, _value(p, k, variable))
		if k == 0:
			_band(st, r, 0.0, depths[0] - bin * 0.5, NO_DATA)
			top = depths[0] - bin * 0.5
		_band(st, r, top, lo, c)
		top = lo
		if top >= -floor_m:
			break
	if top < -floor_m:
		_band(st, r * 0.6, top, -floor_m, NO_DATA.darkened(0.3))
	_disc(st, r, 0.0, Color.WHITE)
	_disc(st, r * 1.6, -floor_m, Color.WHITE)

	# Current arrows every few bins, pointing the way the water moves.
	if variable == Variable.SPEED:
		for k in range(0, depths.size(), 4):
			if p.u[k] == null or depths[k] > -floor_m:
				continue
			var uv := Vector2(p.u[k], p.v[k])
			var dir := Vector3(uv.x, 0, -uv.y).normalized()  # north is -Z
			var length := r + uv.length() * arrow_m_per_mps * terrain.world_per_meter()
			_arrow(st, terrain.world_y(-depths[k]), dir, r, length, color_for(Variable.SPEED, uv.length()))

	st.generate_normals()
	var m := st.commit()
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.vertex_color_is_srgb = true
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.surface_set_material(0, mat)
	return m


## A cylinder section between two depths (m, positive down).
func _band(st: SurfaceTool, r: float, d0: float, d1: float, c: Color, sides := 32) -> void:
	if d1 <= d0:
		return
	var y0 := terrain.world_y(-d0)
	var y1 := terrain.world_y(-d1)
	# Light side shading so the round shape reads even though the material is unshaded.
	for s in sides:
		var a0 := TAU * s / sides
		var a1 := TAU * (s + 1) / sides
		var p0 := Vector3(cos(a0) * r, 0, sin(a0) * r)
		var p1 := Vector3(cos(a1) * r, 0, sin(a1) * r)
		var shade := 0.75 + 0.25 * cos((a0 + a1) * 0.5 - 2.4)
		st.set_color(Color(c.r * shade, c.g * shade, c.b * shade))
		st.add_vertex(p0 + Vector3(0, y0, 0))
		st.add_vertex(p1 + Vector3(0, y0, 0))
		st.add_vertex(p1 + Vector3(0, y1, 0))
		st.add_vertex(p0 + Vector3(0, y0, 0))
		st.add_vertex(p1 + Vector3(0, y1, 0))
		st.add_vertex(p0 + Vector3(0, y1, 0))


## A flat ring marking a depth.
func _disc(st: SurfaceTool, r: float, d: float, c: Color, sides := 32) -> void:
	var y := terrain.world_y(-d) + 0.002
	var inner := r * 0.85
	st.set_color(c)
	for s in sides:
		var o0 := Vector3(cos(TAU * s / sides), 0, sin(TAU * s / sides))
		var o1 := Vector3(cos(TAU * (s + 1) / sides), 0, sin(TAU * (s + 1) / sides))
		var lift := Vector3(0, y, 0)
		for v in [o0 * r, o1 * r, o1 * inner, o0 * r, o1 * inner, o0 * inner]:
			st.add_vertex(v + lift)


## A flat horizontal arrow from radius r0 out to `length` along dir.
func _arrow(st: SurfaceTool, y: float, dir: Vector3, r0: float, length: float, c: Color) -> void:
	var side := dir.cross(Vector3.UP) * (r0 * 0.25)
	var head := minf(r0 * 0.9, (length - r0) * 0.6)
	var a := dir * r0 + Vector3(0, y, 0)
	var b := dir * (length - head) + Vector3(0, y, 0)
	var tip := dir * length + Vector3(0, y, 0)
	st.set_color(c)
	for v in [a - side, b - side, b + side, a - side, b + side, a + side,
			b - side * 2.5, tip, b + side * 2.5]:
		st.add_vertex(v)


func _build_track() -> void:
	if _positions.is_empty():
		return
	var im := ImmediateMesh.new()
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.vertex_color_is_srgb = true
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var gap := 5000.0 * terrain.world_per_meter()  # break the line where the ship wasn't logging
	var lift := 0.06  # sit just above the seafloor so the terrain doesn't hide it
	var open := false
	for i in profiles.size():
		if open and _positions[i].distance_to(_positions[i - 1]) > gap:
			im.surface_end()
			open = false
		if not open:
			im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP, mat)
			open = true
		var k := _first_valid(profiles[i])
		var c := Color.WHITE if variable != Variable.SPEED or k < 0 \
			else color_for(Variable.SPEED, Vector2(profiles[i].u[k], profiles[i].v[k]).length())
		im.surface_set_color(c.lightened(0.2))
		var at := Vector3(_positions[i].x, 0.0, _positions[i].y)
		var d := terrain.depth_at_world(at)
		at.y = (terrain.world_y(minf(d, 0.0)) if not is_nan(d) else 0.0) + lift
		im.surface_add_vertex(at)
	if open:
		im.surface_end()
	_track.mesh = im


func _legend_texture(v: int) -> GradientTexture2D:
	var g := Gradient.new()
	var offsets := PackedFloat32Array()
	var colors := PackedColorArray()
	for s in 9:
		offsets.append(s / 8.0)
		colors.append(_ramp(v, s / 8.0))
	g.offsets = offsets
	g.colors = colors
	var tex := GradientTexture2D.new()
	tex.gradient = g
	tex.width = 256
	tex.height = 12
	return tex


func _build_ui() -> void:
	_column = MeshInstance3D.new()
	_column.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_column)
	_track = MeshInstance3D.new()
	_track.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_track)

	var layer := CanvasLayer.new()
	add_child(layer)
	var panel := PanelContainer.new()
	panel.position = Vector2(16, 16)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.04, 0.07, 0.12, 0.78)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(12)
	panel.add_theme_stylebox_override("panel", style)
	layer.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	panel.add_child(box)
	_info = Label.new()
	_info.add_theme_font_size_override("font_size", 15)
	box.add_child(_info)
	_legend = TextureRect.new()
	_legend.custom_minimum_size = Vector2(300, 12)
	_legend.stretch_mode = TextureRect.STRETCH_SCALE
	box.add_child(_legend)
	var row := HBoxContainer.new()
	box.add_child(row)
	_legend_lo = Label.new()
	_legend_hi = Label.new()
	_legend_hi.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_legend_hi.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	for l in [_legend_lo, _legend_hi]:
		l.add_theme_font_size_override("font_size", 13)
		row.add_child(l)
