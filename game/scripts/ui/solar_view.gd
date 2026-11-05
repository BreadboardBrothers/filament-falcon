class_name SolarView
extends Control
## Commander SOLAR page 3D view: true-scale (optional exaggerated) solar system from
## SolarEphemeris, orbit lines, warp/follow, time scrub, WASD+mouse camera, ship trajectory.
## Floating origin: the camera focus is the world origin; body positions are translated by -focus.

signal time_changed(jd: float)
signal status(msg: String)

const AU_KM := 149597870.7
const DAY := 86400.0
## Exaggerated radii: visual radius = true * factor, clamped so Mercury stays visible at AU scale.
const EXAG_MIN_PX := 3.0

var eph := SolarEphemeris.new()
var jd := 2451545.0                    # J2000
var time_rate := 0.0                   # simulated seconds per real second (0 = pause)
var exaggerated := false
var show_orbits := true
var show_planet_orbits := true
var show_moon_orbits := false
var show_moons := true
var show_ship_path := true
var follow_id := ""                    # attach viewpoint to body
var follow_rotating := false
var pred_span_s := DAY * 7.0
var cam_speed := 5e5                   # km/s translation (auto-adjusted)
var auto_speed := true

var _vp: SubViewport
var _root: Node3D
var _cam: Camera3D
var _sun_light: DirectionalLight3D
var _body_nodes := {}                  # id -> Node3D
var _orbit_mesh: MeshInstance3D
var _ship_mesh: MeshInstance3D
var _ship_path_mesh: MeshInstance3D
var _focus := Vector3.ZERO             # km, floating origin
var _yaw := 0.3
var _pitch := -0.4
var _dist := AU_KM * 3.0               # camera distance from focus (km)
var _look := Vector3.ZERO
var _rmb := false
var _keys := {}
var _tex_cache := {}
var _mat_body: Shader
var _mat_ring: Shader
var _last_rebuild_moons := true
var _ship_marker_id := ""
var last_warp_id := "earth"


func _ready() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_ALL
	_mat_body = load("res://shaders/solar/body.gdshader")
	_mat_ring = load("res://shaders/solar/ring.gdshader")
	_vp = SubViewport.new()
	_vp.own_world_3d = true
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_vp.size = Vector2i(16, 16)
	var host := SubViewportContainer.new()
	host.set_anchors_preset(Control.PRESET_FULL_RECT)
	host.stretch = false   # we size the SubViewport ourselves on resize
	host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(host)
	host.add_child(_vp)
	_root = Node3D.new()
	_root.name = "SolarRoot"
	_vp.add_child(_root)
	_cam = Camera3D.new()
	_cam.current = true
	_cam.far = 1e12
	_cam.near = 100.0
	_root.add_child(_cam)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.01, 0.015, 0.03)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.03, 0.04, 0.06)
	e.ambient_light_energy = 0.4
	e.tonemap_mode = Environment.TONE_MAPPER_ACES
	e.glow_enabled = true
	e.glow_intensity = 0.4
	env.environment = e
	_root.add_child(env)
	_sun_light = DirectionalLight3D.new()
	_sun_light.light_energy = 1.6
	_sun_light.shadow_enabled = true
	_root.add_child(_sun_light)
	_orbit_mesh = MeshInstance3D.new()
	var omat := StandardMaterial3D.new()
	omat.vertex_color_use_as_albedo = true
	omat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	omat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_orbit_mesh.material_override = omat
	_root.add_child(_orbit_mesh)
	_ship_path_mesh = MeshInstance3D.new()
	var pmat := StandardMaterial3D.new()
	pmat.vertex_color_use_as_albedo = true
	pmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	pmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ship_path_mesh.material_override = pmat
	_root.add_child(_ship_path_mesh)
	_ship_mesh = MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 1.0
	sm.height = 2.0
	_ship_mesh.mesh = sm
	var smat := StandardMaterial3D.new()
	smat.albedo_color = Color(1.0, 0.4, 0.1)
	smat.emission_enabled = true
	smat.emission = Color(1.0, 0.5, 0.1)
	_ship_mesh.material_override = smat
	_root.add_child(_ship_mesh)
	if not eph.load_catalog():
		status.emit("solar catalog missing")
		return
	_build_bodies()
	set_to_now()
	_rebuild_orbits()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and _vp:
		_vp.size = Vector2i(maxi(int(size.x), 16), maxi(int(size.y), 16))


func set_to_now() -> void:
	jd = SolarEphemeris.unix_to_jd(Time.get_unix_time_from_system())
	time_changed.emit(jd)
	queue_redraw()


func set_jd(j: float) -> void:
	jd = j
	time_changed.emit(jd)


func warp_to(id: String) -> void:
	if not eph.bodies.has(id):
		return
	follow_id = ""
	var st := eph.state(id, jd)
	if not st.get("ok", false) and id != "sun":
		return
	_focus = st.get("pos", Vector3.ZERO) if id != "sun" else Vector3.ZERO
	var R := eph.radius_km(id)
	_dist = maxf(R * 8.0, R + 500.0)
	if exaggerated:
		_dist = maxf(_dist, AU_KM * 0.02)
	last_warp_id = id
	status.emit("warped to " + str(eph.bodies[id].get("name", id)))


func attach(id: String, rotating := false) -> void:
	follow_id = id
	follow_rotating = rotating
	status.emit(("attached (rotating)" if rotating else "attached") + " to " + id)


func detach() -> void:
	follow_id = ""
	status.emit("camera free")


func _build_bodies() -> void:
	for id: String in _body_nodes.keys():
		(_body_nodes[id] as Node).queue_free()
	_body_nodes.clear()
	for id: Variant in eph.bodies.keys():
		var b: Dictionary = eph.bodies[id]
		var kind := str(b.get("kind", ""))
		if kind == "moon" and not show_moons:
			continue
		var n := Node3D.new()
		n.name = str(id)
		_root.add_child(n)
		var mesh := MeshInstance3D.new()
		var sphere := SphereMesh.new()
		sphere.radius = 1.0
		sphere.height = 2.0
		var big_moon := kind == "moon" and float(b.get("radius_km", 0.0)) >= 200.0
		sphere.radial_segments = 64 if kind == "star" or kind == "planet" else (32 if big_moon else 12)
		sphere.rings = 32 if kind == "star" or kind == "planet" else (16 if big_moon else 8)
		mesh.mesh = sphere
		var mat := ShaderMaterial.new()
		mat.shader = _mat_body
		var col: Array = b.get("color", [0.6, 0.6, 0.6])
		mat.set_shader_parameter("albedo_color", Color(col[0], col[1], col[2]))
		mat.set_shader_parameter("is_star", kind == "star")
		mat.set_shader_parameter("emissive_boost", 2.0 if kind == "star" else 0.0)
		mat.set_shader_parameter("atmosphere", 0.6 if id == "earth" else (0.35 if id == "venus" else (0.25 if kind == "planet" else 0.0)))
		if id == "earth":
			mat.set_shader_parameter("atmo_color", Vector3(0.35, 0.6, 1.0))
		_apply_textures(mat, b)
		mesh.material_override = mat
		n.add_child(mesh)
		if b.get("has_rings", false):
			var ring := MeshInstance3D.new()
			var rm := TorusMesh.new()
			rm.inner_radius = 1.2
			rm.outer_radius = 2.3
			rm.rings = 64
			rm.ring_segments = 24
			ring.mesh = rm
			var rmat := ShaderMaterial.new()
			rmat.shader = _mat_ring
			rmat.set_shader_parameter("inner", 1.2)
			rmat.set_shader_parameter("outer", 2.3)
			ring.material_override = rmat
			ring.rotation_degrees.x = 90.0 + float(b.get("tilt_deg", 0.0)) * 0.2
			n.add_child(ring)
		# axial tilt
		n.rotation_degrees.z = float(b.get("tilt_deg", 0.0))
		_body_nodes[str(id)] = n


func _apply_textures(mat: ShaderMaterial, b: Dictionary) -> void:
	var tex_name := str(b.get("texture", ""))
	if tex_name == "":
		return
	var path := Geo.asset_dir() + "/solar/" + tex_name
	var tex := _load_tex(path)
	if tex:
		mat.set_shader_parameter("day_tex", tex)
		mat.set_shader_parameter("use_day", true)
	if b.get("has_night", false):
		var nt := _load_tex(Geo.asset_dir() + "/solar/earth_night.jpg")
		if nt:
			mat.set_shader_parameter("night_tex", nt)
			mat.set_shader_parameter("use_night", true)
	if b.get("has_clouds", false) and str(b.get("id", "")) == "earth":
		var ct := _load_tex(Geo.asset_dir() + "/solar/earth_clouds.jpg")
		if ct:
			mat.set_shader_parameter("cloud_tex", ct)
			mat.set_shader_parameter("use_clouds", true)
	var nrm := str(b.get("normal", ""))
	if nrm != "":
		var nt2 := _load_tex(Geo.asset_dir() + "/solar/" + nrm)
		if nt2:
			mat.set_shader_parameter("normal_tex", nt2)
			mat.set_shader_parameter("use_normal", true)


func _load_tex(path: String) -> Texture2D:
	if _tex_cache.has(path):
		return _tex_cache[path]
	if not FileAccess.file_exists(path):
		_tex_cache[path] = null
		return null
	var img := Image.load_from_file(path)
	if img == null:
		_tex_cache[path] = null
		return null
	var t := ImageTexture.create_from_image(img)
	_tex_cache[path] = t
	return t


func _visual_radius(id: String) -> float:
	var R := eph.radius_km(id)
	if not exaggerated:
		return maxf(R, 1.0)
	# Exaggerated: keep planets visible at AU scales (Earth ~ 0.005 AU visual)
	return maxf(R * 1200.0, AU_KM * 0.0008)


func _rebuild_orbits() -> void:
	var imm := ImmediateMesh.new()
	if show_orbits:
		if show_planet_orbits:
			for id: String in ["mercury", "venus", "earth", "mars", "jupiter", "saturn", "uranus", "neptune", "pluto", "ceres"]:
				_orbit_line(imm, id, Color(0.4, 0.7, 1.0, 0.35), 180)
		if show_moon_orbits and show_moons:
			for m: Dictionary in eph.moons:
				if m.get("placeholder", false):
					continue
				if float(m.get("radius_km", 0.0)) < 100.0 and not bool(m.get("tidally_locked", false)):
					continue
				_orbit_line(imm, str(m["id"]), Color(0.7, 0.7, 0.5, 0.25), 96)
	_orbit_mesh.mesh = imm


func _orbit_line(imm: ImmediateMesh, id: String, col: Color, steps: int) -> void:
	if not eph.bodies.has(id):
		return
	var b: Dictionary = eph.bodies[id]
	imm.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	imm.surface_set_color(col)
	var kind := str(b.get("kind", ""))
	for i in steps + 1:
		var frac := float(i) / float(steps)
		var jdx := jd
		var st: Dictionary
		if kind == "moon":
			# sample by mean anomaly offset
			var period := float(b.get("period_d", 1.0))
			jdx = jd + frac * period
			st = eph.moon_state(id, jdx)
		else:
			# advance mean longitude roughly one orbit
			var dL := float(b.get("dL_deg_cy", 360.0))
			var days_per_orbit := 360.0 / maxf(absf(dL) / 36525.0, 1e-6)
			jdx = jd + frac * days_per_orbit
			st = eph.planet_state(id, jdx)
		if st.get("ok", false):
			imm.surface_add_vertex(st["pos"] - _focus)
	imm.surface_end()


func _process(dt: float) -> void:
	if not is_visible_in_tree():
		return
	if absf(time_rate) > 0.0:
		jd += time_rate * dt / DAY
		time_changed.emit(jd)
	_update_follow()
	_update_bodies()
	_update_camera(dt)
	_update_ship()
	# auto clip planes from distance
	_cam.near = clampf(_dist * 1e-5, 0.1, 1e6)
	_cam.far = maxf(_dist * 200.0, AU_KM * 100.0)


func _update_follow() -> void:
	if follow_id == "" or not eph.bodies.has(follow_id):
		return
	var st := eph.state(follow_id, jd)
	if follow_id == "sun":
		_focus = Vector3.ZERO
	elif st.get("ok", false):
		_focus = st["pos"]


func _update_bodies() -> void:
	if show_moons != _last_rebuild_moons:
		_last_rebuild_moons = show_moons
		_build_bodies()
		_rebuild_orbits()
	for id: String in _body_nodes.keys():
		var n: Node3D = _body_nodes[id]
		var st := eph.state(id, jd) if id != "sun" else {"pos": Vector3.ZERO, "ok": true}
		var pos: Vector3 = st.get("pos", Vector3.ZERO) - _focus
		n.position = pos
		var R := _visual_radius(id)
		n.scale = Vector3.ONE * R
		# spin
		var mesh := n.get_child(0) as Node3D
		if mesh:
			mesh.rotation.y = eph.spin_angle(id, jd)
		# LOD: hide tiny distant moons
		if str(eph.bodies[id].get("kind", "")) == "moon":
			var d := pos.length()
			n.visible = show_moons and (d < _dist * 40.0 or float(eph.bodies[id].get("radius_km", 0.0)) > 200.0)
	var sun_dir := (-_focus) if _focus.length() > 1.0 else Vector3(1, 0.3, 0.2)
	_sun_light.position = sun_dir.normalized() * 100.0
	_sun_light.look_at(Vector3.ZERO)


func _update_camera(dt: float) -> void:
	var forward := Vector3(-sin(_yaw) * cos(_pitch), sin(_pitch), -cos(_yaw) * cos(_pitch))
	var right := Vector3(cos(_yaw), 0.0, -sin(_yaw))
	var up := Vector3.UP
	var spd := cam_speed
	if auto_speed:
		var nearest := _dist
		for id: String in ["sun", "mercury", "venus", "earth", "mars", "jupiter", "saturn", "uranus", "neptune"]:
			if not _body_nodes.has(id):
				continue
			nearest = minf(nearest, (_body_nodes[id] as Node3D).position.length())
		spd = clampf(nearest * 0.5, 100.0, AU_KM * 2.0)
		cam_speed = spd
	var move := Vector3.ZERO
	if _keys.get("W", false): move += forward
	if _keys.get("S", false): move -= forward
	if _keys.get("A", false): move -= right
	if _keys.get("D", false): move += right
	if _keys.get("Q", false): move -= up
	if _keys.get("E", false): move += up
	if move != Vector3.ZERO and follow_id == "":
		_focus += move.normalized() * spd * dt
		_rebuild_orbits()
	_look = _focus
	_cam.position = - forward * _dist
	_cam.look_at(Vector3.ZERO, Vector3.UP)


func _update_ship() -> void:
	var sim: ShipSim = Game.sim if Game else null
	if sim == null or sim.pos == null:
		_ship_mesh.visible = false
		_ship_path_mesh.mesh = null
		return
	# Game uses BigVec metres around Earth; map to ecliptic km with Earth state.
	var earth := eph.planet_state("earth", jd)
	if not earth.get("ok", false):
		return
	var epos: Vector3 = earth["pos"]
	# Game: Earth at origin-ish with Moon; ship pos is metres from floating origin. Use geocentric.
	var geocentric_km := Vector3(sim.pos.x(), sim.pos.y(), sim.pos.z()) * 0.001
	# Align game Y-up with ecliptic Y-up: game Earth doesn't use true ecliptic; place relative to Earth along game axes.
	var ship_ecl := epos + geocentric_km
	_ship_mesh.visible = true
	_ship_mesh.position = ship_ecl - _focus
	_ship_mesh.scale = Vector3.ONE * maxf(_visual_radius("earth") * 0.05, 50.0)
	if not show_ship_path:
		_ship_path_mesh.mesh = null
		return
	var evel: Vector3 = earth.get("vel", Vector3.ZERO)
	var v_km_s := sim.vel * 0.001 + evel
	var path: Array = eph.propagate_ship(ship_ecl, v_km_s, jd, pred_span_s, 256)
	var imm := ImmediateMesh.new()
	imm.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	imm.surface_set_color(Color(1.0, 0.55, 0.15, 0.9))
	for pt: Dictionary in path:
		imm.surface_add_vertex(pt["pos"] - _focus)
	imm.surface_end()
	# time ticks every ~span/8
	imm.surface_begin(Mesh.PRIMITIVE_LINES)
	imm.surface_set_color(Color(1.0, 0.8, 0.3, 0.8))
	var n := path.size()
	for i in 8:
		var idx := int(float(i) / 8.0 * float(n - 1))
		var p: Vector3 = path[idx]["pos"] - _focus
		imm.surface_add_vertex(p)
		imm.surface_add_vertex(p + Vector3(0, maxf(_dist * 0.002, 200.0), 0))
	imm.surface_end()
	_ship_path_mesh.mesh = imm


func _gui_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton:
		var mb := ev as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT:
			_rmb = mb.pressed
			accept_event()
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_dist = maxf(_dist / 1.2, 10.0)
			accept_event()
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_dist = minf(_dist * 1.2, AU_KM * 500.0)
			accept_event()
	elif ev is InputEventMouseMotion and _rmb:
		var mm := ev as InputEventMouseMotion
		_yaw -= mm.relative.x * 0.005
		_pitch = clampf(_pitch - mm.relative.y * 0.005, -1.2, 1.2)
		accept_event()
	elif ev is InputEventKey:
		var k := ev as InputEventKey
		var name := OS.get_keycode_string(k.keycode)
		if name in ["W", "A", "S", "D", "Q", "E"]:
			_keys[name] = k.pressed
			accept_event()
