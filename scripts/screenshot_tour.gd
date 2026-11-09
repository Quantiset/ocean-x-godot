extends Node
## Renders the images in screenshots/ and quits. Does nothing in a normal run.
##   godot --path . --resolution 1920x1080 -- --screenshots

@export var camera: Camera3D
@export var probe: WaterColumnProbe

const OUT_DIR := "res://screenshots"

# name, camera target, distance, yaw, pitch, [cylinder search point, variable]
var shots := [
	["01_overview_top", Vector3(0, 0, 0), 205.0, 0.0, -89.0],
	["02_overview_angled", Vector3(0, 0, 15), 240.0, 0.0, -40.0],
	["03_northeast_seamounts", Vector3(105, -6, -85), 70.0, 200.0, -30.0],
	["04_west_survey", Vector3(-105, -8, 80), 80.0, -20.0, -35.0],
	["05_central_closeup", Vector3(20, -9, 28), 45.0, 30.0, -30.0],
	["06_water_column_speed", Vector3(20, -1.6, 28), 9.0, 35.0, -24.0, Vector2(20, 28), WaterColumnProbe.Variable.SPEED],
	["07_water_column_backscatter", Vector3(20, -1.6, 28), 9.0, 35.0, -24.0, Vector2(20, 28), WaterColumnProbe.Variable.BACKSCATTER],
]


func _ready() -> void:
	if "--screenshots" in OS.get_cmdline_user_args():
		_run.call_deferred()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	for s in shots:
		camera.set("target", s[1])
		camera.set("distance", s[2])
		camera.set("yaw", s[3])
		camera.set("pitch", s[4])
		camera.call("_apply")
		if s.size() > 5:
			var i := _best_profile_near(s[5])
			probe.variable = s[6]
			var p := probe._positions[i]
			camera.set("target", Vector3(p.x, s[1].y, p.y))
			camera.call("_apply")
			# Click on the seafloor under that profile, the same way a user would.
			var floor_pt := Vector3(p.x, 0, p.y)
			floor_pt.y = probe.terrain.world_y(probe.terrain.depth_at_world(floor_pt))
			probe.probe_screen(camera.unproject_position(floor_pt))
			if probe.current != i:
				push_error("Click landed on profile %d, expected %d" % [probe.current, i])
		else:
			probe.show_profile(-1)
		for f in 4:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var path := ProjectSettings.globalize_path("%s/%s.png" % [OUT_DIR, s[0]])
		get_viewport().get_texture().get_image().save_png(path)
		print("Saved ", path)
	get_tree().quit()


## The profile with the most good current bins within ~15 km of a point.
func _best_profile_near(xz: Vector2) -> int:
	var best := probe.nearest_profile(xz)
	var best_n := -1
	for i in probe.profiles.size():
		if probe._positions[i].distance_to(xz) > 15.0:
			continue
		var n := 0
		for k in probe.depths.size():
			if probe.profiles[i].u[k] != null:
				n += 1
		if n > best_n:
			best_n = n
			best = i
	return best
