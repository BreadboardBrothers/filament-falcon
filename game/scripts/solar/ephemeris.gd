class_name SolarEphemeris
extends RefCounted
## Offline solar-system ephemeris from bundled Keplerian elements (game/data/solar/catalog.json).
## Planets use JPL approximate elements with century rates (ssd.jpl.nasa.gov/planets/approx_pos.html).
## Moons use a, e, i, period (and approx placeholders for tiny irregulars until
## tools/build_moon_catalog.py refreshes from JPL SSD). Positions are ecliptic J2000, km.
## Accuracy: planets ~1e-3 AU over decades; moons with real elements ~hundreds of km; placeholders
## are schematic only. Good enough for the SOLAR visualizer and ship-trajectory sketch.

const AU_KM := 149597870.7
const DEG := PI / 180.0
const DAY := 86400.0
const J2000_UNIX := 946727935.816  # 2000-01-01 12:00:00 TT ≈ Unix (close enough for UI)

var catalog: Dictionary = {}
var bodies: Dictionary = {}   # id -> dict
var moons: Array = []
var children: Dictionary = {} # parent_id -> [child ids]


func load_catalog(path: String = "res://data/solar/catalog.json") -> bool:
	if not FileAccess.file_exists(path):
		push_warning("solar: missing catalog %s" % path)
		return false
	var txt := FileAccess.get_file_as_string(path)
	var js: Variant = JSON.parse_string(txt)
	if not (js is Dictionary):
		return false
	catalog = js
	bodies.clear()
	moons.clear()
	children.clear()
	for b: Variant in catalog.get("bodies", []):
		if b is Dictionary:
			bodies[str(b["id"])] = b
			children[str(b["id"])] = []
	for m: Variant in catalog.get("moons", []):
		if m is Dictionary:
			moons.append(m)
			bodies[str(m["id"])] = m
			var p := str(m.get("parent", ""))
			if not children.has(p):
				children[p] = []
			children[p].append(str(m["id"]))
	return not bodies.is_empty()


static func unix_to_jd(unix: float) -> float:
	return unix / 86400.0 + 2440587.5


static func jd_to_centuries_j2000(jd: float) -> float:
	return (jd - 2451545.0) / 36525.0


static func wrap360(x: float) -> float:
	var y := fmod(x, 360.0)
	return y + 360.0 if y < 0.0 else y


static func kepler_E(M_rad: float, e: float) -> float:
	var E := M_rad if e < 0.8 else PI
	for i in 12:
		var d := E - e * sin(E) - M_rad
		E -= d / (1.0 - e * cos(E))
		if absf(d) < 1e-12:
			break
	return E


## Planet / dwarf heliocentric ecliptic km (and velocity km/s) at Julian date.
func planet_state(id: String, jd: float) -> Dictionary:
	if id == "sun":
		return {"pos": Vector3.ZERO, "vel": Vector3.ZERO, "ok": true}
	if not bodies.has(id):
		return {"ok": false}
	var b: Dictionary = bodies[id]
	if b.get("kind", "") == "moon":
		return moon_state(id, jd)
	var T := jd_to_centuries_j2000(jd)
	var a := (float(b["a_au"]) + float(b.get("da_au_cy", 0.0)) * T) * AU_KM
	var e := float(b["e"]) + float(b.get("de_cy", 0.0)) * T
	var I := (float(b["i_deg"]) + float(b.get("di_deg_cy", 0.0)) * T) * DEG
	var L := wrap360(float(b["L_deg"]) + float(b.get("dL_deg_cy", 0.0)) * T) * DEG
	var wbar := wrap360(float(b["wbar_deg"]) + float(b.get("dwbar_deg_cy", 0.0)) * T) * DEG
	var Om := wrap360(float(b["Om_deg"]) + float(b.get("dOm_deg_cy", 0.0)) * T) * DEG
	var w := wbar - Om
	var M := wrap360((L - wbar) / DEG) * DEG
	return _orbit_rv(a, e, I, Om, w, M, float(bodies["sun"]["gm_km3_s2"]))


func moon_state(id: String, jd: float) -> Dictionary:
	if not bodies.has(id):
		return {"ok": false}
	var m: Dictionary = bodies[id]
	var parent_id := str(m.get("parent", ""))
	var parent := planet_state(parent_id, jd) if parent_id != "" else {"pos": Vector3.ZERO, "vel": Vector3.ZERO, "ok": true}
	if not parent.get("ok", false):
		return {"ok": false}
	var a := float(m["a_km"])
	var e := float(m.get("e", 0.0))
	var I := float(m.get("i_deg", 0.0)) * DEG
	var Om := float(m.get("Om0_deg", 0.0)) * DEG
	var w := float(m.get("w_deg", 0.0)) * DEG
	var period := float(m.get("period_d", 1.0)) * DAY
	var n := TAU / period
	var M0 := float(m.get("mean_anomaly0_deg", 0.0)) * DEG
	var M := fmod(M0 + n * (jd - 2451545.0) * DAY, TAU)
	if M < 0.0:
		M += TAU
	var gm_p := float(bodies.get(parent_id, {}).get("gm_km3_s2", 1.0))
	var rel := _orbit_rv(a, e, I, Om, w, M, gm_p)
	var ppos: Vector3 = parent.get("pos", Vector3.ZERO)
	var pvel: Vector3 = parent.get("vel", Vector3.ZERO)
	return {"pos": ppos + rel["pos"], "vel": pvel + rel["vel"], "ok": true, "rel": rel["pos"]}


func _orbit_rv(a: float, e: float, I: float, Om: float, w: float, M: float, gm: float) -> Dictionary:
	e = clampf(e, 0.0, 0.99)
	var E := kepler_E(M, e)
	var cosE := cos(E)
	var sinE := sin(E)
	var r_orb := a * (1.0 - e * cosE)
	var x := a * (cosE - e)
	var y := a * sqrt(1.0 - e * e) * sinE
	var cosOm := cos(Om)
	var sinOm := sin(Om)
	var cosw := cos(w)
	var sinw := sin(w)
	var cosI := cos(I)
	var sinI := sin(I)
	var px := (cosOm * cosw - sinOm * sinw * cosI) * x + (-cosOm * sinw - sinOm * cosw * cosI) * y
	var py := (sinOm * cosw + cosOm * sinw * cosI) * x + (-sinOm * sinw + cosOm * cosw * cosI) * y
	var pz := (sinw * sinI) * x + (cosw * sinI) * y
	# velocity in orbital plane
	var n := sqrt(gm / (a * a * a))
	var xdot := -a * n * sinE / (1.0 - e * cosE)
	var ydot := a * n * sqrt(1.0 - e * e) * cosE / (1.0 - e * cosE)
	var vx := (cosOm * cosw - sinOm * sinw * cosI) * xdot + (-cosOm * sinw - sinOm * cosw * cosI) * ydot
	var vy := (sinOm * cosw + cosOm * sinw * cosI) * xdot + (-sinOm * sinw + cosOm * cosw * cosI) * ydot
	var vz := (sinw * sinI) * xdot + (cosw * sinI) * ydot
	return {"pos": Vector3(px, pz, -py), "vel": Vector3(vx, vz, -vy), "r": r_orb, "ok": true}
	# Y-up, Z toward viewer-ish: map ecliptic (x,y) to (x,-y) with z->y so the solar system lies in XZ.


func state(id: String, jd: float) -> Dictionary:
	if not bodies.has(id):
		return {"ok": false}
	return moon_state(id, jd) if str(bodies[id].get("kind", "")) == "moon" else planet_state(id, jd)


func radius_km(id: String) -> float:
	return float(bodies.get(id, {}).get("radius_km", 1.0))


func moon_count() -> int:
	return moons.size()


## Spin angle (rad) at Julian date from rot_hours (negative = retrograde).
func spin_angle(id: String, jd: float) -> float:
	var b: Dictionary = bodies.get(id, {})
	var hrs := float(b.get("rot_hours", 24.0))
	if absf(hrs) < 1e-6:
		return 0.0
	var t_s := (jd - 2451545.0) * DAY
	return fmod(t_s / (hrs * 3600.0) * TAU, TAU)


## N-body ship trajectory: RK4 with Sun + planets as fixed-at-sample gravitators (patched: bodies on rails).
## state0: {pos: Vector3 km ecliptic, vel: Vector3 km/s}. Returns [{t_s, pos}, ...]
func propagate_ship(pos0: Vector3, vel0: Vector3, jd0: float, span_s: float, steps: int = 256) -> Array:
	var attractors: Array = []
	for id: String in ["sun", "mercury", "venus", "earth", "mars", "jupiter", "saturn", "uranus", "neptune"]:
		if bodies.has(id):
			attractors.append(id)
	var dt := span_s / float(maxi(steps, 1))
	var p := pos0
	var v := vel0
	var out: Array = [{"t": 0.0, "pos": p}]
	for i in steps:
		var jd := jd0 + (i * dt) / DAY
		var a1 := _accel(p, jd, attractors)
		var v2 := v + a1 * (dt * 0.5)
		var p2 := p + v * (dt * 0.5)
		var a2 := _accel(p2, jd + dt * 0.5 / DAY, attractors)
		var v3 := v + a2 * (dt * 0.5)
		var p3 := p + v2 * (dt * 0.5)
		var a3 := _accel(p3, jd + dt * 0.5 / DAY, attractors)
		var v4 := v + a3 * dt
		var p4 := p + v3 * dt
		var a4 := _accel(p4, jd + dt / DAY, attractors)
		p = p + (v + v2 * 2.0 + v3 * 2.0 + v4) * (dt / 6.0)
		v = v + (a1 + a2 * 2.0 + a3 * 2.0 + a4) * (dt / 6.0)
		if i % maxi(steps / 128, 1) == 0 or i == steps - 1:
			out.append({"t": (i + 1) * dt, "pos": p})
	return out


func _accel(p: Vector3, jd: float, attractors: Array) -> Vector3:
	var a := Vector3.ZERO
	for id: Variant in attractors:
		var st := planet_state(str(id), jd)
		if not st.get("ok", false) and str(id) != "sun":
			continue
		var bp: Vector3 = st.get("pos", Vector3.ZERO)
		var gm := float(bodies[str(id)]["gm_km3_s2"])
		var d := bp - p
		var r2 := d.length_squared()
		if r2 < 1.0:
			continue
		a += d * (gm / (r2 * sqrt(r2)))
	return a
