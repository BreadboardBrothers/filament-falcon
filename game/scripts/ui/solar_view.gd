class_name SolarView
extends Control
## Commander SOLAR page 3D view: true-scale (optional exaggerated) solar system from
## SolarEphemeris, orbit lines, warp/follow, time scrub, WASD+mouse camera, ship trajectory.
## Floating origin + scene-unit scaling + distant impostors keep depth precision across AU↔km.
## Hover ray-pick shows a fact card; warp frames the lit hemisphere at ~half screen height.

signal time_changed(jd: float)
signal status(msg: String)

const AU_KM := 149597870.7
const DAY := 86400.0
const C_KM_S := 299792.458
const SCENE_REF := 1000.0          # camera sits this far from focus in scene units
const FAR_RATIO_MAX := 5.0e6       # near/far depth ratio cap
const HALF_SCREEN_FRAC := 0.5      # planet diameter ≈ half of vertical FOV

var eph := SolarEphemeris.new()
var facts: Dictionary = {}         # id -> fact dict (from facts.json)
var facts_meta: Dictionary = {}
var jd := 2451545.0
var time_rate := 0.0
var exaggerated := false
var show_orbits := true
var show_planet_orbits := true
var show_moon_orbits := false
var show_moons := true
var show_ship_path := true
var follow_id := ""
var follow_rotating := false
var follow_keep_lit := true        # attach keeps sun-facing half-screen framing
var pred_span_s := DAY * 7.0
var cam_speed := 5e5
var auto_speed := true

var _vp: SubViewport
var _root: Node3D
var _cam: Camera3D
var _sun_light: DirectionalLight3D
var _body_nodes := {}
var _orbit_mesh: MeshInstance3D
var _ship_mesh: MeshInstance3D
var _ship_path_mesh: MeshInstance3D
var _focus := Vector3.ZERO
var _yaw := 0.3
var _pitch := -0.4
var _dist := AU_KM * 3.0           # camera distance from focus (km)
var _look := Vector3.ZERO
var _rmb := false
var _keys := {}
var _tex_cache := {}
var _mat_body: Shader
var _mat_ring: Shader
var _last_rebuild_moons := true
var last_warp_id := "earth"
var _moon_vis := {}                # id -> bool hysteresis
var _hover_id := ""
var _hover_panel: PanelContainer
var _hover_label: RichTextLabel
var _mouse_in := false
var _last_mouse := Vector2.ZERO
var _moving_hide := false
var _hover_idle_t := 0.0


func _ready() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_ALL
	_mat_body = load("res://shaders/solar/body.gdshader")
	_mat_ring = load("res://shaders/solar/ring.gdshader")
	_load_facts()
	_vp = SubViewport.new()
	_vp.own_world_3d = true
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_vp.size = Vector2i(16, 16)
	var host := SubViewportContainer.new()
	host.set_anchors_preset(Control.PRESET_FULL_RECT)
	host.stretch = false
	host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(host)
	host.add_child(_vp)
	_root = Node3D.new()
	_root.name = "SolarRoot"
	_vp.add_child(_root)
	_cam = Camera3D.new()
	_cam.current = true
	_cam.fov = 70.0
	_cam.near = 0.1
	_cam.far = 1.0e7
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
	_build_hover_ui()
	if not eph.load_catalog():
		status.emit("solar catalog missing")
		return
	_build_bodies()
	set_to_now()
	_rebuild_orbits()


func _build_hover_ui() -> void:
	_hover_panel = PanelContainer.new()
	_hover_panel.visible = false
	_hover_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hover_panel.z_index = 20
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.04, 0.06, 0.1, 0.92)
	sb.border_color = Color(0.85, 0.65, 0.2, 0.9)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 10
	sb.content_margin_bottom = 10
	_hover_panel.add_theme_stylebox_override("panel", sb)
	_hover_label = RichTextLabel.new()
	_hover_label.bbcode_enabled = true
	_hover_label.fit_content = true
	_hover_label.scroll_active = false
	_hover_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hover_label.custom_minimum_size = Vector2(340, 0)
	_hover_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hover_label.add_theme_color_override("default_color", Color(0.92, 0.93, 0.95))
	_hover_label.add_theme_font_size_override("normal_font_size", 13)
	_hover_panel.add_child(_hover_label)
	add_child(_hover_panel)


func _load_facts() -> void:
	facts.clear()
	facts_meta.clear()
	var path := "res://data/solar/facts.json"
	if not FileAccess.file_exists(path):
		return
	var js: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (js is Dictionary):
		return
	facts_meta = js
	var bodies: Variant = js.get("bodies", {})
	if bodies is Dictionary:
		for k: Variant in bodies.keys():
			facts[str(k)] = bodies[k]


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and _vp:
		_vp.size = Vector2i(maxi(int(size.x), 16), maxi(int(size.y), 16))
	elif what == NOTIFICATION_MOUSE_EXIT:
		_mouse_in = false
		_hide_hover()
	elif what == NOTIFICATION_MOUSE_ENTER:
		_mouse_in = true


func set_to_now() -> void:
	jd = SolarEphemeris.unix_to_jd(Time.get_unix_time_from_system())
	time_changed.emit(jd)
	queue_redraw()


func set_jd(j: float) -> void:
	jd = j
	time_changed.emit(jd)


## Standoff distance (km) so the body's visual diameter fills ~HALF_SCREEN_FRAC of vertical FOV.
func standoff_km(id: String) -> float:
	var R := _visual_radius(id)
	var fov := deg_to_rad(_cam.fov if _cam else 70.0)
	# diameter angular size = fov * HALF_SCREEN_FRAC ⇒ angular radius = fov * frac / 2
	var half_ang := fov * HALF_SCREEN_FRAC * 0.5
	var d := R / maxf(tan(half_ang), 1e-8)
	return maxf(d, R * 1.2 + 5.0)


## Near/far clip planes (scene units) for a camera distance in km. Public for headless tests.
func clip_planes_for_dist(dist_km: float, nearest_surface_km: float = -1.0) -> Dictionary:
	var d := maxf(dist_km, 1.0)
	var s := SCENE_REF / d
	var near_km := d * 1e-4
	if nearest_surface_km >= 0.0:
		near_km = maxf(nearest_surface_km * 0.15, d * 1e-5)
	near_km = clampf(near_km, 0.05 / s, d * 0.35)
	var far_km := maxf(d * 80.0, AU_KM * 2.0)
	# Keep local neighborhood in the precision band; distant bodies use impostors.
	var local_horizon_km := maxf(d * 60.0, AU_KM * 0.05)
	far_km = minf(far_km, local_horizon_km * 1.4)
	var near_u := maxf(near_km * s, 0.02)
	var far_u := maxf(far_km * s, near_u * 100.0)
	if far_u / near_u > FAR_RATIO_MAX:
		far_u = near_u * FAR_RATIO_MAX
	return {
		"near": near_u,
		"far": far_u,
		"scale": s,
		"local_horizon_km": local_horizon_km,
		"near_km": near_km,
		"far_km": far_km,
	}


func warp_to(id: String) -> void:
	if not eph.bodies.has(id):
		return
	follow_id = ""
	var st := eph.state(id, jd) if id != "sun" else {"pos": Vector3.ZERO, "ok": true}
	if not st.get("ok", false) and id != "sun":
		return
	_apply_lit_framing(id, st.get("pos", Vector3.ZERO))
	_rebuild_orbits()
	last_warp_id = id
	status.emit("warped to " + str(eph.bodies[id].get("name", id)))


func attach(id: String, rotating := false) -> void:
	if not eph.bodies.has(id):
		return
	follow_id = id
	follow_rotating = rotating
	var st := eph.state(id, jd) if id != "sun" else {"pos": Vector3.ZERO, "ok": true}
	if st.get("ok", false) or id == "sun":
		_apply_lit_framing(id, st.get("pos", Vector3.ZERO))
		_rebuild_orbits()
	status.emit(("attached (rotating)" if rotating else "attached") + " to " + id)


func detach() -> void:
	follow_id = ""
	status.emit("camera free")


## Place focus on body, set half-screen standoff, approach from Sun-facing (lit) side.
func _apply_lit_framing(id: String, body_pos: Vector3) -> void:
	_focus = body_pos if id != "sun" else Vector3.ZERO
	_dist = standoff_km(id)
	var from_sun := body_pos if body_pos.length() > 1.0 else Vector3(1.0, 0.15, 0.35)
	if id == "sun":
		# Approach the Sun from a slight ecliptic offset so the disc isn't edge-on to light.
		from_sun = Vector3(1.0, 0.2, 0.4)
	var dir := from_sun.normalized()
	# Camera sits between Sun and body: forward = dir (see _update_camera).
	_pitch = asin(clampf(dir.y, -0.99, 0.99))
	_yaw = atan2(-dir.x, -dir.z)


func _build_bodies() -> void:
	for id: String in _body_nodes.keys():
		(_body_nodes[id] as Node).queue_free()
	_body_nodes.clear()
	_moon_vis.clear()
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
		n.rotation_degrees.z = float(b.get("tilt_deg", 0.0))
		_body_nodes[str(id)] = n
		if kind == "moon":
			_moon_vis[str(id)] = true


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
	var s := SCENE_REF / maxf(_dist, 1.0)
	for i in steps + 1:
		var frac := float(i) / float(steps)
		var jdx := jd
		var st: Dictionary
		if kind == "moon":
			var period := float(b.get("period_d", 1.0))
			jdx = jd + frac * period
			st = eph.moon_state(id, jdx)
		else:
			var dL := float(b.get("dL_deg_cy", 360.0))
			var days_per_orbit := 360.0 / maxf(absf(dL) / 36525.0, 1e-6)
			jdx = jd + frac * days_per_orbit
			st = eph.planet_state(id, jdx)
		if st.get("ok", false):
			imm.surface_add_vertex((st["pos"] - _focus) * s)
	imm.surface_end()


func _process(dt: float) -> void:
	if not is_visible_in_tree():
		return
	if absf(time_rate) > 0.0:
		jd += time_rate * dt / DAY
		time_changed.emit(jd)
	_update_follow()
	_update_bodies_and_clips()
	_update_camera(dt)
	_update_ship()
	if _hover_idle_t > 0.0:
		_hover_idle_t = maxf(_hover_idle_t - dt, 0.0)
		if _hover_idle_t == 0.0:
			_moving_hide = false
	if _mouse_in and not _rmb and not _moving_hide:
		_update_hover(_last_mouse)


func _update_follow() -> void:
	if follow_id == "" or not eph.bodies.has(follow_id):
		return
	var st := eph.state(follow_id, jd) if follow_id != "sun" else {"pos": Vector3.ZERO, "ok": true}
	if follow_id == "sun":
		_focus = Vector3.ZERO
	elif st.get("ok", false):
		_focus = st["pos"]
	if follow_keep_lit:
		_dist = standoff_km(follow_id)
		_apply_lit_framing(follow_id, st.get("pos", Vector3.ZERO) if follow_id != "sun" else Vector3.ZERO)


func _update_bodies_and_clips() -> void:
	if show_moons != _last_rebuild_moons:
		_last_rebuild_moons = show_moons
		_build_bodies()
		_rebuild_orbits()
	var nearest_surf := _dist
	var clips := clip_planes_for_dist(_dist)
	var s: float = clips["scale"]
	var horizon: float = clips["local_horizon_km"]
	for id: String in _body_nodes.keys():
		var n: Node3D = _body_nodes[id]
		var st := eph.state(id, jd) if id != "sun" else {"pos": Vector3.ZERO, "ok": true}
		var rel: Vector3 = st.get("pos", Vector3.ZERO) - _focus
		var d_true := rel.length()
		var R := _visual_radius(id)
		# Track nearest surface for clip near plane.
		var surf := maxf(d_true - R, 0.0)
		if id != "sun" or d_true > 1.0:
			nearest_surf = minf(nearest_surf, surf if d_true > 1.0 else _dist)
		# Distant impostor: place along same direction closer in, preserve angular size.
		var place := d_true
		var scale_R := R
		if d_true > horizon and d_true > 1.0:
			place = horizon * 0.92
			scale_R = R * (place / d_true)
		var dir := rel / d_true if d_true > 1e-3 else Vector3.ZERO
		n.position = (dir * place) * s
		n.scale = Vector3.ONE * (scale_R * s)
		var mesh := n.get_child(0) as Node3D
		if mesh:
			mesh.rotation.y = eph.spin_angle(id, jd)
		# Stable LOD for moons: angular-size hysteresis (no min-pixel flicker).
		var kind := str(eph.bodies[id].get("kind", ""))
		if kind == "moon":
			var cam_d := maxf((n.position - (-_forward() * SCENE_REF)).length(), 1e-3)
			var ang := (scale_R * s) / cam_d
			var vis: bool = bool(_moon_vis.get(id, true))
			if vis and ang < 2.5e-4:
				vis = false
			elif (not vis) and ang > 4.0e-4:
				vis = true
			# Always keep major moons when their parent is the focus neighbourhood.
			if float(eph.bodies[id].get("radius_km", 0.0)) >= 200.0 and d_true < horizon * 1.5:
				vis = show_moons
			_moon_vis[id] = vis
			n.visible = show_moons and vis
		else:
			n.visible = true
	clips = clip_planes_for_dist(_dist, nearest_surf)
	_cam.near = clips["near"]
	_cam.far = clips["far"]
	var sun_dir := (-_focus) if _focus.length() > 1.0 else Vector3(1, 0.3, 0.2)
	_sun_light.position = sun_dir.normalized() * 100.0
	_sun_light.look_at(Vector3.ZERO)
	# Orbit mesh lives in scene units relative to focus.
	_orbit_mesh.scale = Vector3.ONE
	# Rebuild orbit vertex scale occasionally via existing mesh (scaled at rebuild).
	# Keep ship path scaled in _update_ship.


func _forward() -> Vector3:
	return Vector3(-sin(_yaw) * cos(_pitch), sin(_pitch), -cos(_yaw) * cos(_pitch))


func _update_camera(dt: float) -> void:
	var forward := _forward()
	var right := Vector3(cos(_yaw), 0.0, -sin(_yaw))
	var up := Vector3.UP
	var spd := cam_speed
	if auto_speed:
		var nearest := _dist
		for id: String in ["sun", "mercury", "venus", "earth", "mars", "jupiter", "saturn", "uranus", "neptune"]:
			if not _body_nodes.has(id):
				continue
			var rel_len := _focus.length() if id == "sun" else _dist
			if id == "sun":
				rel_len = maxf(_focus.length(), 1.0)
			else:
				var st2 := eph.state(id, jd)
				if st2.get("ok", false):
					rel_len = maxf((st2["pos"] - _focus).length(), 1.0)
			nearest = minf(nearest, rel_len)
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
	_cam.position = -forward * SCENE_REF
	_cam.look_at(Vector3.ZERO, Vector3.UP)


func _update_ship() -> void:
	var sim: ShipSim = Game.sim if Game else null
	var s := SCENE_REF / maxf(_dist, 1.0)
	if sim == null or sim.pos == null:
		_ship_mesh.visible = false
		_ship_path_mesh.mesh = null
		return
	var earth := eph.planet_state("earth", jd)
	if not earth.get("ok", false):
		return
	var epos: Vector3 = earth["pos"]
	var geocentric_km := Vector3(sim.pos.x(), sim.pos.y(), sim.pos.z()) * 0.001
	var ship_ecl := epos + geocentric_km
	_ship_mesh.visible = true
	_ship_mesh.position = (ship_ecl - _focus) * s
	_ship_mesh.scale = Vector3.ONE * maxf(_visual_radius("earth") * 0.05, 50.0) * s
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
		imm.surface_add_vertex((pt["pos"] - _focus) * s)
	imm.surface_end()
	imm.surface_begin(Mesh.PRIMITIVE_LINES)
	imm.surface_set_color(Color(1.0, 0.8, 0.3, 0.8))
	var n := path.size()
	for i in 8:
		var idx := int(float(i) / 8.0 * float(n - 1))
		var p: Vector3 = (path[idx]["pos"] - _focus) * s
		imm.surface_add_vertex(p)
		imm.surface_add_vertex(p + Vector3(0, maxf(SCENE_REF * 0.002, 0.2), 0))
	imm.surface_end()
	_ship_path_mesh.mesh = imm


## Ray / sphere pick with generous radius for tiny bodies. Returns body id or "".
func pick_body_at(screen_pos: Vector2) -> String:
	if _cam == null or _vp == null:
		return ""
	var vp_size := Vector2(_vp.size)
	if vp_size.x < 1.0 or vp_size.y < 1.0:
		return ""
	var local := screen_pos
	if local.x < 0.0 or local.y < 0.0 or local.x > size.x or local.y > size.y:
		return ""
	var from := _cam.project_ray_origin(local)
	var dir := _cam.project_ray_normal(local)
	var best_id := ""
	var best_t := 1e30
	# ~14 px pick floor in angular terms.
	var px_ang := deg_to_rad(_cam.fov) / maxf(vp_size.y, 1.0)
	var pick_ang := px_ang * 14.0
	for id: String in _body_nodes.keys():
		var n: Node3D = _body_nodes[id]
		if not n.visible:
			continue
		var center: Vector3 = n.global_position
		var R_scene: float = n.scale.x
		var pick_R := maxf(R_scene, SCENE_REF * tan(pick_ang))
		# Ray-sphere
		var oc := from - center
		var b := oc.dot(dir)
		var c := oc.dot(oc) - pick_R * pick_R
		var disc := b * b - c
		if disc < 0.0:
			continue
		var t := -b - sqrt(disc)
		if t < 0.0:
			t = -b + sqrt(disc)
		if t < 0.0:
			continue
		# Prefer larger angular size on near ties.
		var ang := R_scene / maxf(t, 1e-3)
		var score := t - ang * 50.0
		if score < best_t:
			best_t = score
			best_id = id
	return best_id


func _hide_hover() -> void:
	_hover_id = ""
	if _hover_panel:
		_hover_panel.visible = false


func _update_hover(screen_pos: Vector2) -> void:
	var id := pick_body_at(screen_pos)
	if id == "":
		_hide_hover()
		return
	if id != _hover_id:
		_hover_id = id
		_hover_label.text = format_hover_bbcode(id)
	_hover_panel.visible = true
	_hover_panel.reset_size()
	var pad := Vector2(18, 18)
	var pos := screen_pos + pad
	var psz := _hover_panel.get_combined_minimum_size()
	if pos.x + psz.x > size.x:
		pos.x = screen_pos.x - psz.x - pad.x
	if pos.y + psz.y > size.y:
		pos.y = screen_pos.y - psz.y - pad.y
	_hover_panel.position = pos.clamp(Vector2.ZERO, Vector2(maxf(size.x - psz.x, 0), maxf(size.y - psz.y, 0)))


func format_hover_bbcode(id: String) -> String:
	var b: Dictionary = eph.bodies.get(id, {})
	var f: Dictionary = facts.get(id, {})
	var bname := str(b.get("name", id)).capitalize() if str(b.get("name", "")) != "" else id.capitalize()
	var kind := str(f.get("type", b.get("kind", "body")))
	var st := eph.state(id, jd) if id != "sun" else {"pos": Vector3.ZERO, "vel": Vector3.ZERO, "ok": true}
	var pos: Vector3 = st.get("pos", Vector3.ZERO)
	var vel: Vector3 = st.get("vel", Vector3.ZERO)
	var r_sun := pos.length()
	var au := r_sun / AU_KM
	var light_min := (r_sun / C_KM_S) / 60.0
	var R := float(f.get("radius_km", eph.radius_km(id)))
	var diam := float(f.get("diameter_km", R * 2.0))
	var earth_R := float(facts_meta.get("earth_radius_km", 6371.0))
	var size_earth := R / earth_R
	var lines: PackedStringArray = []
	lines.append("[b][color=#ffcc66]%s[/color][/b]  [color=#88aacc]%s[/color]" % [bname, kind])
	var day_s: Variant = f.get("day_sidereal_h", b.get("rot_hours", null))
	var day_sol: Variant = f.get("day_solar_h", null)
	if day_s != null:
		lines.append("Day (sidereal): %s" % _fmt_hours(float(day_s)))
	if day_sol != null:
		lines.append("Day (solar): %s" % _fmt_hours(float(day_sol)))
	var year_d: Variant = f.get("year_d", null)
	if year_d == null and b.has("dL_deg_cy"):
		var dL := absf(float(b.get("dL_deg_cy", 0.0)))
		if dL > 1e-6:
			year_d = 360.0 / (dL / 36525.0)
	elif year_d == null and b.has("period_d"):
		year_d = float(b.get("period_d", 0.0))
	if year_d != null and float(year_d) != 0.0:
		lines.append("Year / orbit: %s" % _fmt_days(float(year_d)))
	lines.append("Radius: %s km  ·  Diameter: %s km" % [_fmt_num(R), _fmt_num(diam)])
	lines.append("Size vs Earth: x%.3f (radius)" % size_earth)
	if f.get("mass_earth", null) != null:
		lines.append("Mass: x%.4f Earth" % float(f["mass_earth"]))
	elif f.get("mass_kg", null) != null:
		lines.append("Mass: %s kg" % _fmt_num(float(f["mass_kg"])))
	if f.get("gravity_ms2", null) != null:
		lines.append("Gravity: %.2f m/s²" % float(f["gravity_ms2"]))
	if f.get("density_g_cm3", null) != null:
		lines.append("Density: %.2f g/cm³" % float(f["density_g_cm3"]))
	if id != "sun":
		lines.append("Distance from Sun: %.4f AU · %s km" % [au, _fmt_num(r_sun)])
		lines.append("Light-time from Sun: %.2f min" % light_min)
		lines.append("Orbital speed now: %.2f km/s" % vel.length())
	if f.get("tilt_deg", null) != null:
		lines.append("Axial tilt: %.2f°" % float(f["tilt_deg"]))
	elif b.has("tilt_deg"):
		lines.append("Axial tilt: %.2f°" % float(b["tilt_deg"]))
	if f.get("temp_k", null) != null:
		var tk := float(f["temp_k"])
		lines.append("Mean temperature: %.0f K (%.0f °C)" % [tk, tk - 273.15])
	var moons_n: Variant = f.get("moons", null)
	if moons_n == null and eph.children.has(id):
		moons_n = (eph.children[id] as Array).size()
	if moons_n != null:
		lines.append("Moons: %s" % str(moons_n))
	if f.get("atmosphere", null) != null:
		lines.append("Atmosphere: %s" % str(f["atmosphere"]))
	if f.get("escape_km_s", null) != null:
		lines.append("Escape velocity: %.2f km/s" % float(f["escape_km_s"]))
	if f.get("discovery", null) != null:
		lines.append("Discovery: %s" % str(f["discovery"]))
	var trivia: Variant = f.get("trivia", [])
	if trivia is Array and not (trivia as Array).is_empty():
		lines.append("")
		lines.append("[color=#9ecfff][i]Trivia[/i][/color]")
		for t: Variant in trivia:
			lines.append("• " + str(t))
	elif str(b.get("source", "")) != "":
		lines.append("Source: %s" % str(b.get("source", "")))
	return "\n".join(lines)


func _fmt_hours(h: float) -> String:
	var sign := "-" if h < 0.0 else ""
	h = absf(h)
	if h >= 48.0:
		return "%s%.2f d (%.1f h)" % [sign, h / 24.0, h]
	return "%s%.2f h" % [sign, h]


func _fmt_days(d: float) -> String:
	var sign := "-" if d < 0.0 else ""
	d = absf(d)
	if d >= 400.0:
		return "%s%.2f y (%.1f d)" % [sign, d / 365.25, d]
	return "%s%.3f d" % [sign, d]


func _fmt_num(x: float) -> String:
	var ax := absf(x)
	if ax >= 1.0e6 or (ax > 0.0 and ax < 1.0e-3):
		var exp := 0
		var m := ax
		if m > 0.0:
			while m >= 10.0:
				m /= 10.0
				exp += 1
			while m < 1.0:
				m *= 10.0
				exp -= 1
		var sign := "-" if x < 0.0 else ""
		return "%s%.3f e%d" % [sign, m, exp]
	if ax >= 100.0:
		return "%.0f" % x
	if ax >= 1.0:
		return "%.2f" % x
	return "%.4f" % x


func _gui_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton:
		var mb := ev as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT:
			_rmb = mb.pressed
			if _rmb:
				_hide_hover()
			accept_event()
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_dist = maxf(_dist / 1.2, 10.0)
			_rebuild_orbits()
			accept_event()
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_dist = minf(_dist * 1.2, AU_KM * 500.0)
			_rebuild_orbits()
			accept_event()
	elif ev is InputEventMouseMotion:
		var mm := ev as InputEventMouseMotion
		_last_mouse = mm.position
		_mouse_in = true
		if _rmb:
			_yaw -= mm.relative.x * 0.005
			_pitch = clampf(_pitch - mm.relative.y * 0.005, -1.2, 1.2)
			_hide_hover()
			accept_event()
		else:
			# Hide while the pointer is moving; show again after brief idle.
			if mm.relative.length() > 0.5:
				_moving_hide = true
				_hover_idle_t = 0.12
				_hide_hover()
	elif ev is InputEventKey:
		var k := ev as InputEventKey
		var keyname := OS.get_keycode_string(k.keycode)
		if keyname in ["W", "A", "S", "D", "Q", "E"]:
			_keys[keyname] = k.pressed
			accept_event()
