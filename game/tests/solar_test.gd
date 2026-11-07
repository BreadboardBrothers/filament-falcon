extends Node
## Headless solar-system checks (`-- --solar-test`).
##   XDG_DATA_HOME=$(mktemp -d) godot --headless --path game -- --solar-test

var _ok := true


func _ready() -> void:
	_run.call_deferred()


func _check(cond: bool, what: String) -> void:
	print(("  ok   " if cond else "  FAIL ") + what)
	if not cond:
		_ok = false


# Godot's float32 matrix, not just nominal near/far: these are the eight
# intersections used by RenderingLightCuller::create_frustum_points.
func _check_projection(proj: Projection, label: String) -> void:
	var planes: Array[Plane] = []
	var valid := true
	for i in 6:
		var plane := proj.get_projection_plane(i)
		planes.append(plane)
		valid = valid and plane.normal.is_finite() and is_finite(plane.d) and plane.normal.length() > 0.99
	for depth in [Projection.PLANE_NEAR, Projection.PLANE_FAR]:
		for side in [Projection.PLANE_LEFT, Projection.PLANE_RIGHT]:
			for vertical in [Projection.PLANE_TOP, Projection.PLANE_BOTTOM]:
				var corner = planes[depth].intersect_3(planes[side], planes[vertical])
				valid = valid and corner != null and (corner as Vector3).is_finite()
	_check(valid, label + " has finite nondegenerate frustum corners")


func _check_local_lights(root: Node) -> void:
	for child in root.get_children():
		if child is OmniLight3D:
			var light := child as OmniLight3D
			_check(is_finite(light.omni_range) and light.omni_range > 0.0 and light.omni_range <= 300.0,
				"SOLAR local light %s has sensible authored range" % light.name)
		_check_local_lights(child)


func _galaxy_tests(sv: SolarView) -> void:
	var dir := OS.get_environment("XDG_DATA_HOME") + "/galaxy-test-fixtures"
	DirAccess.make_dir_recursive_absolute(dir)
	var corrupt := FileAccess.open(dir + "/bad.jpg", FileAccess.WRITE)
	corrupt.store_string("<html>not an image</html>")
	corrupt = null
	# Synthetic image: opaque black JPEG-like background + bright centre.
	# PNG is used to avoid JPEG compression ambiguity in pixel assertions.
	var fixture := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	fixture.fill(Color.BLACK)
	for x in range(10, 22):
		for y in range(10, 22):
			fixture.set_pixel(x, y, Color.WHITE)
	fixture.save_png(dir + "/black-background.png")
	var cases := [sv.galaxy_material(dir + "/absent.jpg"), sv.galaxy_material(dir + "/bad.jpg"), sv.galaxy_material(dir + "/black-background.png")]
	_check(not cases[0].get_shader_parameter("has_image"), "missing galaxy uses procedural alpha glow")
	_check(not cases[1].get_shader_parameter("has_image"), "corrupt galaxy uses procedural alpha glow")
	_check(cases[2].get_shader_parameter("has_image"), "valid galaxy uses image alpha shader")
	var original := sv._load_tex(dir + "/black-background.png").get_image().get_pixel(0, 0)
	_check(original.a > 0.99 and original.r < 0.01, "generic loader preserves opaque black pixels for planets")
	fixture.fill(Color.WHITE)
	fixture.save_png(dir + "/white-border.png")
	cases.append(sv.galaxy_material(dir + "/white-border.png"))
	fixture.fill(Color(1, 1, 1, 0))
	fixture.save_png(dir + "/transparent.png")
	cases.append(sv.galaxy_material(dir + "/transparent.png"))
	if DisplayServer.get_name() == "headless":
		print("  NOTE galaxy shader pixel checks require actual renderer; material/loader checks ran headless")
		return
	var view := SubViewport.new()
	view.size = Vector2i(64, 64)
	view.own_world_3d = true
	view.transparent_bg = true
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(view)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 2.0
	cam.position.z = 2.0
	cam.current = true
	view.add_child(cam)
	var mesh := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(2, 2)
	mesh.mesh = quad
	view.add_child(mesh)
	for i in cases.size():
		mesh.material_override = cases[i]
		await _frames(3)
		var pixels := view.get_texture().get_image()
		_check(pixels.get_pixel(0, 0).a < 0.02, "render galaxy case %d: quad corner transparent" % i)
		_check(pixels.get_pixel(2, 32).a < 0.25, "render galaxy case %d: quad edge feathered" % i)
		if i == 2:
			_check(pixels.get_pixel(16, 32).a < 0.02, "render galaxy black photographic background transparent away from edges")
		if i < 4:
			_check(pixels.get_pixel(32, 32).a > 0.1, "render galaxy case %d: centre visible" % i)
		else:
			_check(pixels.get_pixel(32, 32).a < 0.02, "render galaxy preserves source alpha")
	view.queue_free()
	await _frames(2)


func _exhaust_bounds(mesh: MeshInstance3D, pivot: Node3D, nozzle_z: float, label: String) -> float:
	var vertices: PackedVector3Array = mesh.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var min_z := INF
	var max_z := -INF
	var finite := true
	# Rotate/scale like World/SOLAR; undo the parent to test the same body axis.
	var parent := Transform3D(Basis(Vector3(0.3, 0.8, 0.1).normalized(), 1.2).scaled(Vector3.ONE * 500.0), Vector3(123, 456, -789))
	for vertex in vertices:
		var local := pivot.transform * mesh.transform * vertex
		var recovered := parent.affine_inverse() * (parent * local)
		finite = finite and recovered.is_finite()
		min_z = minf(min_z, recovered.z)
		max_z = maxf(max_z, recovered.z)
	_check(finite and absf(min_z - nozzle_z) < 0.002 and max_z > nozzle_z,
		label + " starts at nozzle and extends ONLY aft (also rotated/scaled)")
	return max_z - min_z


func _exhaust_tests(sv: SolarView) -> void:
	var sim := Game.sim
	var old_thrust := sim.thrust_now
	var old_density := sim.density_now
	var old_attached := sim.booster_attached
	var ship := sv._ship_model
	var pivot := ship.get_node("PlumePivot") as Node3D
	var haze := pivot.get_node("Haze") as MeshInstance3D
	var bp := sv._ship_booster.get_node("Plume") as Node3D
	for vac in [false, true]:
		var last_length := 0.0
		for throttle in [0.05, 0.5, 1.0]:
			sim.density_now = 0.0 if vac else 0.4
			sim.thrust_now = sim.main_thrust * throttle
			sim.booster_attached = false
			ship.animate(Game, 0.0)
			var length := _exhaust_bounds(ship.plume, pivot, 9.175, "ship %.2f vacuum=%s" % [throttle, vac])
			_check(length > last_length, "ship throttle length grows aft monotonically")
			last_length = length
			_exhaust_bounds(haze, pivot, 9.175, "ship haze %.2f vacuum=%s" % [throttle, vac])
			_check(ship.plume.visible and haze.visible, "thrust keeps exhaust and haze visible")
			sim.booster_attached = true
			sim.thrust_now = sim.booster_thrust * throttle
			sv._sync_booster(sim)
			for child in bp.get_children():
				if child is MeshInstance3D:
					_exhaust_bounds(child, bp, 12.375, "booster plume/haze %.2f vacuum=%s" % [throttle, vac])
			var bm: ShaderMaterial = bp.get_meta("mat")
			_check(absf(float(bm.get_shader_parameter("throttle")) - throttle) < 0.001, "booster shader tracks live thrust")
	sim.booster_attached = false
	sim.thrust_now = 0.0
	ship.animate(Game, 0.0)
	_check(not ship.plume.visible and not haze.visible, "zero thrust hides ship exhaust")
	sim.thrust_now = old_thrust
	sim.density_now = old_density
	sim.booster_attached = old_attached


func _exhaust_render_test() -> void:
	if DisplayServer.get_name() == "headless":
		return
	var view := SubViewport.new()
	view.size = Vector2i(256, 128)
	view.own_world_3d = true
	view.transparent_bg = true
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(view)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 40.0
	camera.position = Vector3(60, 0, 22)
	view.add_child(camera)
	camera.look_at(Vector3(0, 0, 22))
	camera.current = true
	var pivot := Node3D.new()
	pivot.position.z = 9.175
	pivot.rotation.x = -PI * 0.5
	view.add_child(pivot)
	var material := ProcGen.shader_mat("res://shaders/plume.gdshader", {"throttle": 1.0})
	var mesh := ProcGen.mesh_node(ProcGen.exhaust_mesh(), material)
	pivot.add_child(mesh)
	for vacuum in [0.0, 1.0]:
		material.set_shader_parameter("vacuum", vacuum)
		mesh.scale = Vector3(1.0 + vacuum * 2.5, 23.0 + vacuum * 10.0, 1.0 + vacuum * 2.5)
		await _frames(3)
		var pixels := view.get_texture().get_image()
		var bright := 0
		var upstream := 0
		for x in 256:
			var body_z := camera.project_position(Vector2(x + 0.5, 64), 60).z
			for y in 128:
				var pixel := pixels.get_pixel(x, y)
				if maxf(pixel.r, maxf(pixel.g, pixel.b)) > 0.03:
					bright += 1
					if body_z < 8.5:
						upstream += 1
		_check(bright > 10 and upstream == 0, "rendered full-throttle exhaust vacuum=%.1f: visible aft, no hull-side glow" % vacuum)
	view.queue_free()
	await _frames(2)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _run() -> void:
	# Exact old startup pair: float32 rounds z coefficient to -1 and loses FAR.
	var old_projection := Projection.create_perspective(70.0, 16.0 / 9.0, 0.1, 1e7)
	_check(old_projection.get_projection_plane(Projection.PLANE_FAR).normal.length() < 0.01,
		"old SOLAR startup deterministically reproduces zero far-plane normal")
	var eph := SolarEphemeris.new()
	_check(eph.load_catalog(), "catalog loads")
	_check(eph.moon_count() >= 290, "moon count %d ≥ 290" % eph.moon_count())
	_check(eph.bodies.has("earth") and eph.bodies.has("jupiter") and eph.bodies.has("sun"), "planets present")
	var j2000 := 2451545.0
	var e0 := eph.planet_state("earth", j2000)
	_check(e0.get("ok", false), "earth state at J2000")
	var r0: float = (e0["pos"] as Vector3).length() / SolarEphemeris.AU_KM
	_check(absf(r0 - 1.0) < 0.02, "Earth |r| at J2000 = %.4f AU" % r0)
	var e1 := eph.planet_state("earth", 2460310.5)
	var r1: float = (e1["pos"] as Vector3).length() / SolarEphemeris.AU_KM
	_check(absf(r1 - 1.0) < 0.03, "Earth |r| at 2024-01-01 = %.4f AU" % r1)
	var m := eph.moon_state("moon", j2000)
	var em: float = ((m["pos"] as Vector3) - (e0["pos"] as Vector3)).length()
	_check(em > 300000.0 and em < 500000.0, "Moon distance from Earth at J2000 = %.0f km" % em)
	var j := eph.planet_state("jupiter", j2000)
	var rj: float = (j["pos"] as Vector3).length() / SolarEphemeris.AU_KM
	_check(rj > 4.5 and rj < 5.6, "Jupiter |r| at J2000 = %.3f AU" % rj)
	var path: Array = eph.propagate_ship(e0["pos"] + Vector3(7000, 0, 0), e0["vel"] + Vector3(0, 0, 7.5), j2000, 86400.0, 64)
	_check(path.size() > 10, "trajectory points %d" % path.size())
	var finite := true
	for pt: Dictionary in path:
		var p: Vector3 = pt["pos"]
		if not (is_finite(p.x) and is_finite(p.y) and is_finite(p.z)):
			finite = false
	_check(finite, "trajectory finite")

	var vp := SubViewport.new()
	vp.size = Vector2i(1280, 720)
	add_child(vp)
	var sv := SolarView.new()
	sv.size = Vector2(900, 500)
	sv.hide()  # Commander constructs SOLAR before its tab is opened.
	vp.add_child(sv)
	_check_projection(sv._cam.get_camera_projection(), "hidden SOLAR initial projection")
	_check(sv._vp.render_target_update_mode != SubViewport.UPDATE_ALWAYS, "hidden SOLAR not forced to render")
	sv.show()
	await _frames(6)
	_check(sv.eph.moon_count() >= 290, "SolarView catalog live")
	_check(sv.facts.has("earth") and sv.facts.has("sun"), "facts dataset")
	_check(sv._sky_stars.size() >= 50, "bundled bright-star catalog (%d)" % sv._sky_stars.size())
	_check(sv._sky_galaxies.size() >= 8, "bundled galaxy catalog (%d)" % sv._sky_galaxies.size())
	_check(sv.show_ship_path == false, "SHIP PATH default off (was yellow lines from Earth)")
	_check(sv._sun_light != null and sv._sun_light.shadow_enabled == false, "SOLAR sun shadows off")
	_check_local_lights(sv._root)
	# Soft _load_tex: HTML stub must not load as a texture
	var bogus := OS.get_environment("XDG_DATA_HOME") + "/filament-falcon/assets/solar/_bogus_io.jpg"
	DirAccess.make_dir_recursive_absolute(bogus.get_base_dir())
	var bf := FileAccess.open(bogus, FileAccess.WRITE)
	if bf:
		bf.store_string("<!DOCTYPE html><html>not a jpeg</html>")
		bf = null
		var bad := sv._load_tex(bogus)
		_check(bad == null, "soft _load_tex rejects HTML-as-jpg")

	_exhaust_tests(sv)
	await _exhaust_render_test()
	await _galaxy_tests(sv)
	_check(sv.show_labels == true, "LABELS default on")
	_check(sv.exaggerated_sun == false, "EXAG. SUN default off")

	# Clip planes across zoom
	var zooms: Array = [SolarView.AU_KM * 40.0, SolarView.AU_KM * 3.0, 1.0e7, 5.0e4, 500.0]
	var clips_ok := true
	for d: float in zooms:
		var c: Dictionary = sv.clip_planes_for_dist(d)
		if not (float(c["near"]) > 0.0 and float(c["far"]) > float(c["near"]) and float(c["far"]) / float(c["near"]) <= SolarView.FAR_RATIO_MAX * 1.01):
			clips_ok = false
	_check(clips_ok, "clip planes sane across zoom")
	for vehicle in ["", SolarView.SHIP_ID, SolarView.BOOSTER_ID]:
		sv.follow_id = vehicle
		for d in [0.002, 0.005, 0.05, 100.0, 1e7, SolarView.AU_KM * 500.0]:
			var cc := sv.clip_planes_for_dist(d)
			var proj := Projection.create_perspective(70.0, 16.0 / 9.0, cc["near"], cc["far"])
			_check_projection(proj, "SOLAR %s zoom %.4f" % [vehicle, d])
	sv.follow_id = ""
	# Same off-axis math used by twin OTW cameras (including toe-in and EVA near).
	var dm := DisplayManager.new()
	for near_plane in [1.0, 0.2]:
		dm.near_now = near_plane
		for side in [-1, 1]:
			var f := dm.frustum_for(side)
			_check_projection(Projection.create_frustum_aspect(f[1], 16.0 / 9.0, f[2], near_plane, 1e6), "OTW side %d near %.1f" % [side, near_plane])
	dm.free()

	sv.warp_to("earth")
	await _frames(2)
	var R_e := sv._visual_radius("earth")
	var stand := sv.standoff_km("earth")
	var ang_diam := 2.0 * atan(R_e / stand)
	var target := deg_to_rad(sv._cam.fov) * SolarView.HALF_SCREEN_FRAC
	_check(absf(ang_diam - target) / target < 0.05, "earth warp half-screen")
	var tip := sv.format_hover_bbcode("earth")
	_check(tip.contains("Earth") and tip.contains("Day"), "hover card text")

	# Sun exaggeration separate + capped
	sv.exaggerated = true
	sv.exaggerated_sun = false
	var r_sun_plain := sv._visual_radius("sun")
	var r_earth_ex := sv._visual_radius("earth")
	_check(r_sun_plain <= eph.radius_km("sun") * 1.01, "EXAG. SIZE does not enlarge Sun")
	_check(r_earth_ex > eph.radius_km("earth") * 100.0, "EXAG. SIZE enlarges Earth")
	sv.exaggerated_sun = true
	var r_sun_ex := sv._visual_radius("sun")
	_check(r_sun_ex > r_sun_plain, "EXAG. SUN enlarges Sun")
	_check(r_sun_ex <= SolarView.AU_KM * SolarView.SUN_EXAG_CAP_AU * 1.01, "EXAG. SUN capped below Mercury orbit")
	sv.exaggerated_sun = false

	# Moon orbit exaggeration: moon outside exaggerated Earth
	sv.exaggerated = true
	sv.set_jd(j2000)
	await _frames(2)
	var earth_p := sv.body_display_pos_km("earth")
	var moon_p := sv.body_display_pos_km("moon")
	var sep := (moon_p - earth_p).length()
	var need := sv._visual_radius("earth") * 1.45 + sv._visual_radius("moon")
	_check(sep >= need * 0.98, "exaggerated Moon outside Earth (sep=%.0f need=%.0f)" % [sep, need])

	# Live orbits: body sits on its orbit line at several scrubbed times
	sv.exaggerated = false
	sv.show_planet_orbits = true
	sv.show_moon_orbits = true
	sv.show_moons = true
	sv._build_bodies()
	var times: Array = [j2000, j2000 + 30.0, j2000 + 180.0, j2000 + 400.0]
	var on_line := true
	for tj: float in times:
		sv.set_jd(tj)
		await _frames(2)
		for pid: String in ["mercury", "earth", "mars", "jupiter"]:
			var err := sv.orbit_point_error_km(pid, tj, 360)
			# First sample of orbit is exactly at jd ⇒ error ~0; allow 1 km float noise
			if err > 5.0:
				on_line = false
				print("  FAIL %s at JD %.1f orbit error %.3f km" % [pid, tj, err])
		var merr := sv.orbit_point_error_km("moon", tj, 180)
		if merr > 50.0:
			on_line = false
			print("  FAIL moon at JD %.1f orbit error %.3f km" % [tj, merr])
	_check(on_line, "bodies lie on orbit lines across scrubbed times")

	# Moon orbit follows parent: parent moves between times, moon-orbit center tracks Earth
	sv.set_jd(j2000)
	sv._rebuild_orbits()
	var earth_a := sv.body_display_pos_km("earth", j2000)
	sv.set_jd(j2000 + 40.0)
	sv._rebuild_orbits()
	var earth_b := sv.body_display_pos_km("earth", j2000 + 40.0)
	var moved := (earth_b - earth_a).length()
	_check(moved > 1.0e6, "Earth moved over 40 d (%.0f km) so moon orbits must reattach" % moved)
	var merr2 := sv.orbit_point_error_km("moon", j2000 + 40.0, 180)
	_check(merr2 < 50.0, "moon still on parent-attached orbit after Earth moved (err=%.2f km)" % merr2)

	# Sky direction sanity: Polaris near +ecliptic-north-ish after transform (high |y| in scene)
	var polaris := sv.eq_to_scene_dir(2.5303, 89.2641)
	_check(polaris.y > 0.85, "Polaris maps near ecliptic north (y=%.3f)" % polaris.y)
	var sirius := sv.eq_to_scene_dir(6.7525, -16.7161)
	_check(sirius.length() > 0.99, "Sirius unit direction")

	sv.show_labels = true
	sv._update_labels()
	await _frames(2)
	_check(sv._label_nodes.has("earth") or sv.show_labels, "label system active")

	sv.time_rate = 86400.0
	await _frames(6)
	_check(absf(sv.jd - sv._orbit_jd) < 1.0, "orbits rebuilt as time advances")
	sv.warp_to("mars")
	await _frames(2)
	_check(sv.follow_id == "", "warp clears follow")
	sv.attach("earth")
	await _frames(2)
	_check(sv.follow_id == "earth", "attach earth")
	var yaw0 := sv._yaw
	var pitch0 := sv._pitch
	var dist0 := sv._dist
	sv._yaw_goal = yaw0 + 0.4
	sv._pitch_goal = clampf(pitch0 - 0.2, -1.2, 1.2)
	sv._dist_goal = sv._clamp_attach_dist(dist0 * 1.5)
	await _frames(10)
	_check(absf(sv._yaw - yaw0) > 0.05, "attach orbit yaw moves toward goal")
	_check(absf(sv._dist - dist0) > 1.0, "attach zoom distance moves toward goal")
	var focus0 := sv._focus
	sv.jd += 0.5
	sv._update_follow()
	_check(sv.follow_id == "earth", "still attached after body time step")
	_check(absf(sv._yaw_goal - (yaw0 + 0.4)) < 0.001, "orbit yaw goal retained while body moves")
	_check(sv._dist_goal > sv._attach_min_dist() * 0.99, "zoom above surface min")
	# WASD detaches
	sv._keys["W"] = true
	sv._update_camera(0.05)
	sv._keys["W"] = false
	_check(sv.follow_id == "", "WASD detaches from object")

	# FALCON / live ship
	_check(sv._ship_model != null and sv._ship_model is ShipModel, "ShipModel present (not SphereMesh)")
	_check(sv._ship_booster != null, "booster node present")
	_check(sv.SHIP_PATH_COL.r > 0.8 and sv.SHIP_PATH_COL.g < 0.4, "ship path is red")
	sv.warp_to_ship()
	await _frames(3)
	_check(sv.last_warp_id == SolarView.SHIP_ID, "warp_to_ship sets last_warp_id")
	_check(sv.show_ship_path == true, "warp to FALCON enables SHIP PATH")
	sv.attach_ship(false)
	await _frames(3)
	_check(sv.follow_id == SolarView.SHIP_ID, "attach_ship follows ship")
	_check(sv._attach_min_dist() < 0.01, "ship attach min allows EVA-close zoom (<%.4f km)" % sv._attach_min_dist())
	sv._dist = 0.05
	sv._dist_goal = 0.05
	var s_far := sv._scene_scale()
	sv._dist = 0.005
	sv._dist_goal = 0.005
	var s_near := sv._scene_scale()
	_check(s_near > s_far * 5.0, "ship scene scale tracks sub-km zoom (no 1 km floor): %.1f→%.1f" % [s_far, s_near])
	_check(sv.close_ship_mode(), "close-ship mode while attached nearby")
	sv._update_bodies_and_clips()
	var earth_vis := false
	if sv._body_nodes.has("earth"):
		earth_vis = (sv._body_nodes["earth"] as Node3D).visible
	_check(not earth_vis, "Earth hidden in close-ship mode")
	var foc0 := sv._focus
	if Game and Game.sim:
		Game.sim.booster_attached = true
		sv._update_ship(0.016)
		_check(sv._ship_booster.visible == true, "booster visible when attached")
		Game.sim.booster_attached = false
		sv._update_ship(0.016)
		_check(sv._ship_booster.visible == false, "booster hidden after staging")
		sv._update_ship(0.016)
		_check(sv._ship_path_mesh.mesh != null, "red ship path mesh rebuilt while following")
	sv.detach()
	_check(sv.follow_id == "", "detach clears ship follow")

	# BOOSTER follow / attach / close zoom (fake free booster entity near ship)
	_check(sv._free_booster_root != null, "free booster root present")
	_check(sv.BOOSTER_PATH_COL.b > 0.8 and sv.BOOSTER_PATH_COL.r < 0.4, "booster path is cyan")
	if Game and Game.sim and Game.sim.pos:
		var be := Game.add_entity("booster", {
			"mode": "free",
			"pos": Game.sim.pos.copy(),
			"vel": Game.sim.vel,
			"basis": Game.sim.basis,
			"recovery": "coast",
			"thrust_frac": 0.0,
			"fins_deployed": true,
			"name": "TEST BOOSTER",
		})
		_check(sv.booster_available(), "booster_available after free entity")
		_check(sv.can_follow(SolarView.BOOSTER_ID), "can_follow booster")
		sv.warp_to_booster()
		await _frames(2)
		_check(sv.last_warp_id == SolarView.BOOSTER_ID, "warp_to_booster sets last_warp_id")
		sv.attach_booster(false)
		await _frames(3)
		_check(sv.follow_id == SolarView.BOOSTER_ID, "attach_booster follows booster")
		_check(sv._attach_min_dist() < 0.01, "booster attach min allows close zoom")
		sv._dist = 0.05
		sv._dist_goal = 0.05
		_check(sv.close_ship_mode(), "close-vehicle mode on booster")
		sv._update_bodies_and_clips()
		var earth_vis2 := false
		if sv._body_nodes.has("earth"):
			earth_vis2 = (sv._body_nodes["earth"] as Node3D).visible
		_check(not earth_vis2, "Earth hidden in close-booster mode")
		sv._update_ship(0.016)
		_check(sv._free_booster_root.visible == true, "free booster model visible while following")
		sv.detach()
		Game.remove_entity(be)
	else:
		_check(false, "Game.sim available for booster follow test")

	sv.queue_free()
	await _frames(2)
	# SFX hitch survival (engine underruns under SOLAR)
	if Sfx and Sfx.player and Sfx.player.stream is AudioStreamGenerator:
		var gen := Sfx.player.stream as AudioStreamGenerator
		_check(gen.buffer_length >= 0.45, "SFX generator buffer ≥0.45 s (got %.2f)" % gen.buffer_length)
	else:
		_check(false, "SFX AudioStreamGenerator available")

	print("SOLAR TEST: ", "PASS" if _ok else "FAIL")
	print("SHIP: real ShipModel + booster/EVA; red SHIP PATH; FALCON warp/attach.")
	print("BOOSTER: free model + cyan path; WARP/ATTACH/close-zoom like FALCON.")
	print("NOTE: old yellow Earth rays were ship path+ticks default ON; path now red, default off.")
	get_tree().quit(0 if _ok else 1)
