extends Node
## Headless solar-system checks (`-- --solar-test`):
##   - catalog loads; moon count ≥ 290
##   - Earth heliocentric distance near 1 AU at J2000 (tol 0.02 AU)
##   - Earth at a known date (2024-01-01) still ~1 AU
##   - Moon stays within 500_000 km of Earth
##   - ship trajectory propagator returns points and stays finite
##   - SolarView builds and advances a few frames
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
	_check(absf(r0 - 1.0) < 0.02, "Earth |r| at J2000 = %.4f AU (tol 0.02)" % r0)
	# 2024-01-01 00:00 UTC ≈ JD 2460310.5
	var e1 := eph.planet_state("earth", 2460310.5)
	var r1: float = (e1["pos"] as Vector3).length() / SolarEphemeris.AU_KM
	_check(absf(r1 - 1.0) < 0.03, "Earth |r| at 2024-01-01 = %.4f AU (tol 0.03)" % r1)
	var m := eph.moon_state("moon", j2000)
	var em: float = ((m["pos"] as Vector3) - (e0["pos"] as Vector3)).length()
	_check(em > 300000.0 and em < 500000.0, "Moon distance from Earth at J2000 = %.0f km" % em)
	var j := eph.planet_state("jupiter", j2000)
	var rj: float = (j["pos"] as Vector3).length() / SolarEphemeris.AU_KM
	_check(rj > 4.5 and rj < 5.6, "Jupiter |r| at J2000 = %.3f AU" % rj)
	# trajectory
	var path: Array = eph.propagate_ship(e0["pos"] + Vector3(7000, 0, 0), e0["vel"] + Vector3(0, 0, 7.5), j2000, 86400.0, 64)
	_check(path.size() > 10, "trajectory points %d" % path.size())
	var finite := true
	for pt: Dictionary in path:
		var p: Vector3 = pt["pos"]
		if not (is_finite(p.x) and is_finite(p.y) and is_finite(p.z)):
			finite = false
	_check(finite, "trajectory finite")
	# UI smoke
	var vp := SubViewport.new()
	vp.size = Vector2i(1280, 720)
	add_child(vp)
	var sv := SolarView.new()
	sv.size = Vector2(900, 500)
	vp.add_child(sv)
	await _frames(6)
	_check(sv.eph.moon_count() >= 290, "SolarView catalog live")
	sv.time_rate = 86400.0
	await _frames(4)
	_check(sv.jd > j2000 - 1.0, "time advances")
	sv.warp_to("mars")
	await _frames(2)
	_check(sv.follow_id == "", "warp clears follow")
	sv.attach("earth")
	await _frames(2)
	_check(sv.follow_id == "earth", "attach earth")
	sv.exaggerated = true
	sv._build_bodies()
	sv.show_moon_orbits = true
	sv._rebuild_orbits()
	await _frames(2)
	sv.queue_free()
	await _frames(2)
	print("SOLAR TEST: ", "PASS" if _ok else "FAIL")
	get_tree().quit(0 if _ok else 1)
