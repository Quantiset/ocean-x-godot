extends Camera3D
## Drag with left mouse to orbit, right/middle mouse to pan, wheel to zoom.

@export var target := Vector3.ZERO
@export var distance := 250.0
@export var yaw := 0.0
@export var pitch := -50.0


func _ready() -> void:
	_apply()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		if event.button_mask & MOUSE_BUTTON_MASK_LEFT:
			yaw -= event.relative.x * 0.3
			pitch = clampf(pitch - event.relative.y * 0.3, -89.0, -5.0)
		elif event.button_mask & (MOUSE_BUTTON_MASK_RIGHT | MOUSE_BUTTON_MASK_MIDDLE):
			var s := distance * 0.002
			target -= global_basis.x * event.relative.x * s
			target += Vector3(global_basis.z.x, 0, global_basis.z.z).normalized() * -event.relative.y * s
		_apply()
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			distance = maxf(distance * 0.9, 1.0)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			distance *= 1.1
		_apply()


func _apply() -> void:
	var rot := Basis.from_euler(Vector3(deg_to_rad(pitch), deg_to_rad(yaw), 0))
	look_at_from_position(target + rot * Vector3(0, 0, distance), target)
