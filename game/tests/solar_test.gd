extends Node
## Headless solar-system checks (`-- --solar-test`):
##   - catalog loads; moon count ≥ 290
##   - Earth heliocentric distance near 1 AU at J2000 (tol 0.02 AU)
##   - Earth at a known date (2024-01-01) still ~1 AU
##   - Moon stays within 500_000 km of Earth
##   - ship trajectory propagator returns points and stays finite
##   - SolarView builds and advances a few frames
##   - clip planes stay sane across zoom (near < far, ratio capped, bodies framed)
##   - warp standoff ≈ half-screen; facts dataset present
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
	_check(eph.moon_count() >= 290, "moon count %d ≥ 290 (bundled or JPL overlay)" % eph.moon_count())
	_check(eph.bodies.has("earth") and eph.bodies.has("jupiter") and eph.bodies.has("sun"), "planets present")
	var j2000 := 2451545.0
	var e0 := eph.planet_state("earth", j2000)
	_check(e0.get("ok", false), "earth state at J2000")
	var r0: float = (e0["pos"] as Vector3).length() / SolarEphemeris.AU_KM
	_check(absf(r0 - 1.0) < 0.02, "Earth |r| at J2000 = %.4f AU (tol 0.02)" % r0)
	var e1 := eph.planet_state("earth", 2460310.5)
	var r1: float = (e1["pos"] as Vector3).length() / SolarEphemeris.AU_KM
	_check(absf(r1 - 1.0) < 0.03, "Earth |r| at 2024-01-01 = %.4f AU (tol 0.03)" % r1)
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
	_check(sv.facts.has("earth") and sv.facts.has("sun") and sv.facts.has("titan"), "facts dataset (earth/sun/titan)")
	var tip := sv.format_hover_bbcode("earth")
	_check(tip.contains("Earth") and tip.contains("Day") and tip.contains("AU"), "hover card text for earth")

	# Clip planes across zoom range (true-scale AU → planet → moon).
	var zooms: Array = [
		SolarView.AU_KM * 40.0,
		SolarView.AU_KM * 3.0,
		SolarView.AU_KM * 0.5,
		1.0e7,
		1.0e6,
		5.0e4,
		8.0e3,
		500.0,
	]
	var clips_ok := true
	for d: float in zooms:
		var c: Dictionary = sv.clip_planes_for_dist(d)
		var near_u: float = c["near"]
		var far_u: float = c["far"]
		var ratio := far_u / maxf(near_u, 1e-9)
		var row_ok := near_u > 0.0 and far_u > near_u and ratio <= SolarView.FAR_RATIO_MAX * 1.01
		if not row_ok:
			clips_ok = false
			print("  FAIL clip at dist=%s near=%s far=%s ratio=%s" % [str(d), str(near_u), str(far_u), str(ratio)])
		else:
			print("  ok   clip dist=%s near=%s far=%s ratio=%s" % [str(d), str(near_u), str(far_u), str(ratio)])
	_check(clips_ok, "clip planes sane across zoom range")

	# Live camera clip after warps
	sv.warp_to("jupiter")
	await _frames(3)
	_check(sv._cam.near > 0.0 and sv._cam.far > sv._cam.near, "live cam clips after jupiter warp")
	_check(sv._cam.far / sv._cam.near <= SolarView.FAR_RATIO_MAX * 1.01, "live cam far/near capped")

	# Half-screen standoff: angular diameter ≈ FOV * HALF_SCREEN_FRAC
	sv.warp_to("earth")
	await _frames(2)
	var R_e := sv._visual_radius("earth")
	var stand := sv.standoff_km("earth")
	var ang_diam := 2.0 * atan(R_e / stand)
	var target := deg_to_rad(sv._cam.fov) * SolarView.HALF_SCREEN_FRAC
	_check(absf(ang_diam - target) / target < 0.05, "earth warp half-screen ang=%.3f° target=%.3f°" % [rad_to_deg(ang_diam), rad_to_deg(target)])
	# Lit-side: camera forward aligns with sun→body (focus is body, sun at -focus in body frame when focus=earth pos)
	var earth_pos: Vector3 = eph.planet_state("earth", sv.jd)["pos"]
	var sun_to_body := earth_pos.normalized()
	var fwd := sv._forward()
	_check(fwd.dot(sun_to_body) > 0.85, "earth warp from lit / sun-facing side (dot=%.3f)" % fwd.dot(sun_to_body))

	sv.warp_to("moon")
	await _frames(2)
	var R_m := sv._visual_radius("moon")
	var stand_m := sv.standoff_km("moon")
	var ang_m := 2.0 * atan(R_m / stand_m)
	_check(absf(ang_m - target) / target < 0.05, "moon warp half-screen")

	sv.warp_to("sun")
	await _frames(2)
	_check(sv.standoff_km("sun") > eph.radius_km("sun"), "sun standoff outside surface")

	sv.time_rate = 86400.0
	await _frames(4)
	_check(sv.jd > j2000 - 1.0, "time advances")
	sv.warp_to("mars")
	await _frames(2)
	_check(sv.follow_id == "", "warp clears follow")
	sv.attach("earth")
	await _frames(2)
	_check(sv.follow_id == "earth", "attach earth")
	_check(absf(sv._dist - sv.standoff_km("earth")) / sv.standoff_km("earth") < 0.05, "attach keeps half-screen standoff")
	sv.exaggerated = true
	sv._build_bodies()
	sv.show_moon_orbits = true
	sv._rebuild_orbits()
	await _frames(2)
	# Exaggerated standoff still finite and clips ok
	var cx: Dictionary = sv.clip_planes_for_dist(sv._dist)
	_check(cx["far"] > cx["near"], "exaggerated clips ok")
	sv.queue_free()
	await _frames(2)
	print("SOLAR TEST: ", "PASS" if _ok else "FAIL")
	get_tree().quit(0 if _ok else 1)
