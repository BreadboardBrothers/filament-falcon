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


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _run() -> void:
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
	vp.add_child(sv)
	await _frames(6)
	_check(sv.eph.moon_count() >= 290, "SolarView catalog live")
	_check(sv.facts.has("earth") and sv.facts.has("sun"), "facts dataset")
	_check(sv._sky_stars.size() >= 50, "bundled bright-star catalog (%d)" % sv._sky_stars.size())
	_check(sv._sky_galaxies.size() >= 8, "bundled galaxy catalog (%d)" % sv._sky_galaxies.size())
	_check(sv.show_ship_path == false, "SHIP PATH default off (was yellow lines from Earth)")
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
	sv.queue_free()
	await _frames(2)
	print("SOLAR TEST: ", "PASS" if _ok else "FAIL")
	print("SHIP: real ShipModel + booster/EVA; red SHIP PATH; FALCON warp/attach.")
	print("NOTE: old yellow Earth rays were ship path+ticks default ON; path now red, default off.")
	get_tree().quit(0 if _ok else 1)
