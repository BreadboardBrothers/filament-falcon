class_name CamFeedView
extends SubViewportContainer
## A live camera picture for the console / Commander screen (docking, arm or chase camera).
## Only renders while it is actually visible, so hidden pages cost nothing.

var kind := "DOCKING CAMERA"     # DOCKING CAMERA | ARM CAMERA | CHASE CAMERA | HELMET CAM | EVA DRONE | AUTO (follows the Ops mode)
var _drone_t := 0.0
var vp: SubViewport
var cam: Camera3D
var overlay: CameraOverlay


func _ready() -> void:
	stretch = true
	vp = SubViewport.new()
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	vp.msaa_3d = Viewport.MSAA_2X
	vp.audio_listener_enable_3d = false
	add_child(vp)
	cam = Camera3D.new()
	cam.near = 0.3
	cam.far = 2.5e5
	vp.add_child(cam)
	cam.current = true
	overlay = CameraOverlay.new()
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vp.add_child(overlay)


func current_kind() -> String:
	if kind != "AUTO":
		return kind
	match Game.ops_mode:
		1:
			return "ARM CAMERA"
		0:
			return "DOCKING CAMERA"
	return "CHASE CAMERA"


func _process(_dt: float) -> void:
	_drone_t += _dt
	var on := is_visible_in_tree() and size.x > 8.0
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS if on else SubViewport.UPDATE_DISABLED
	if not on:
		return
	var w: WorldView = get_tree().get_first_node_in_group("world")
	if w == null or Game.sim == null:
		return
	var k := current_kind()
	overlay.kind = k
	cam.fov = 60.0 if k == "CHASE CAMERA" else 55.0
	# spacewalk cameras: the helmet cam hides its own wearer (helmet + body layers)
	cam.cull_mask = 0xFFFFF & ~(Eva.EVA_HEAD_LAYER | Eva.EVA_BODY_LAYER) if k == "HELMET CAM" else 0xFFFFF
	var eva_cam := k == "HELMET CAM" or k == "EVA DRONE"
	cam.near = 0.08 if eva_cam else 0.3
	cam.far = 1.0e6 if eva_cam else 2.5e5
	if eva_cam:
		var xf := eva_cam_xform(w, k, _dt)
		if xf != Transform3D():
			cam.global_transform = xf
			cam.fov = 80.0 if k == "HELMET CAM" else 62.0
			return
		k = "CHASE CAMERA"
	match k:
		"DOCKING CAMERA":
			cam.global_transform = w.docking_cam_xform()
		"ARM CAMERA":
			cam.global_transform = w.arm_cam_xform()
		_:
			# Same chase framing as the OTW chase view (single-monitor feed: no bezel yaw).
			cam.global_transform = w.chase_xform(Game.sim)


## HELMET CAM: the spacewalker's eyes. EVA DRONE: a little camera drone that hovers behind
## and above the astronaut, slowly circling (one of the VR ideas, also a flat-mode view).
func eva_cam_xform(w: WorldView, k: String, _dt: float) -> Transform3D:
	if w.eva_view == null:
		return Transform3D()
	var pose: Dictionary = w.eva_view.current_pose()
	if pose.is_empty():
		return Transform3D()
	var to_world := w.eva_view.global_transform
	var head: Transform3D = pose["head"]
	if k == "HELMET CAM":
		return to_world * Transform3D(head.basis.orthonormalized(), head.origin - head.basis.z * 0.12)
	return drone_xform(to_world, pose, _drone_t)


static func drone_xform(to_world: Transform3D, pose: Dictionary, t: float) -> Transform3D:
	var head: Transform3D = pose["head"]
	var up: Vector3 = pose.get("up", Vector3.UP)
	var fwd := (-head.basis.z).slide(up).normalized()
	if fwd.length() < 0.1:
		fwd = Vector3.FORWARD
	var right := fwd.cross(up).normalized()
	var a := sin(t * 0.13) * 0.9
	var off := (-fwd * cos(a) + right * sin(a)) * 3.2 + up * 1.4
	var target := head.origin - up * 0.5
	var p := head.origin + off
	return to_world * Transform3D(Basis.looking_at(target - p, up), p)
