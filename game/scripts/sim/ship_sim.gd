class_name ShipSim
extends RefCounted
## Newtonian 6-DOF rigid-body model of the Falcon.
## - n-body point-mass gravity (Earth + Moon), dominant body chosen by sphere of influence
## - main engine / booster with pressure-dependent Isp and mass flow
## - RCS translation + rotation, reaction wheels, engine gimbal and aero control torques
## - exponential atmosphere: drag, lift, sideslip force, static stability, damping
## - Sutton-Graves stagnation heating with radiative cooling
## - spring/damper ground contacts at real gear/hull points (tipping, friction, impacts)
## Flight-assist modes change how stick input becomes torque; they never fake the physics.

const G0 := 9.80665
const SIGMA := 5.670374e-8

enum FA { OFF, STAB, NAV, HOLD }
const FA_NAMES := ["OFF", "STAB", "PROGRADE", "HOLD"]

var bodies: Array = []
var dominant: CelestialBody = null

# --- rigid body state
var pos := BigVec.new()
var vel := Vector3.ZERO
var basis := Basis.IDENTITY          # ship -> world. forward = -Z, up = +Y, right = +X
var ang_vel := Vector3.ZERO          # world frame, rad/s

# --- mass budget (kg)
var dry_mass := 10000.0
var fuel := 6000.0
var fuel_max := 9000.0
var mono := 450.0
var mono_max := 450.0
var cargo_mass := 0.0
var booster_attached := false
var booster_dry := 7000.0
var booster_fuel := 0.0
var booster_fuel_max := 46000.0

# --- propulsion
var main_thrust := 280000.0
var main_isp_vac := 1040.0      # real-size Earth: ~12 km/s total delta-v (a "hot" future engine)
var main_isp_sl := 900.0
var booster_thrust := 1150000.0
var booster_isp_vac := 610.0
var booster_isp_sl := 540.0
var rcs_force := 4500.0
var rcs_isp := 230.0
var rw_torque := 60000.0
var rcs_torque := 45000.0
var boost_factor := 1.3

var engine_on := false
var engine_enabled := true
var throttle_cmd := 0.0
var throttle := 0.0
var boost := false
var rcs_enabled := true
var rw_enabled := true
var gear_down := false
var gear_pos := 0.0
var airbrake := false
var flaps := 0.5                      # 0 up, 0.5 half, 1 down (3-position switch)
var flap_fwd := Vector2.ZERO          # L,R radians (Starship forward flaps)
var flap_aft := Vector2.ZERO          # L,R radians (Starship aft flaps)
var shield_on := false
var heat_mult := 1.0
var clamped := false
var anchor_pos := BigVec.new()
var anchor_vel := Vector3.ZERO

# --- control inputs (set by Game every frame)
var in_rot := Vector3.ZERO           # x = pitch up, y = yaw right, z = roll right (-1..1)
var in_trans := Vector3.ZERO         # x = right, y = up, z = forward (-1..1)
var fa_mode := FA.STAB
var nav_dir := Vector3.ZERO          # world direction used by the PROGRADE (nav) mode
var max_rate := Vector3(deg_to_rad(22.0), deg_to_rad(22.0), deg_to_rad(40.0))
var hold_basis := Basis.IDENTITY
var holding := false

# --- outputs / telemetry
var mass := 0.0
var thrust_now := 0.0
var flameout := false
var accel_proper := Vector3.ZERO
var g_load := 1.0
var max_g := 0.0
var dyn_pressure := 0.0
var mach := 0.0
var airspeed := 0.0
var heat_flux := 0.0
var hull_temp := 285.0
var altitude := 0.0
var agl := 0.0
var vspeed := 0.0
var hspeed := 0.0
var surface_vel := Vector3.ZERO
var up_dir := Vector3.UP
var aoa := 0.0
var density_now := 0.0
var touching := false
var contact_points := 0
var landed := false
var last_impact := 0.0
var hull_hit := 0.0                  # accumulated hull impact speed this frame (game consumes)
var gear_hit := 0.0
var rcs_trans_activity := Vector3.ZERO
var rcs_rot_activity := Vector3.ZERO
var fuel_used := 0.0
var mono_used := 0.0

var _contact_prev := {}

# Contact points in ship body frame (metres). Ship is ~15 m long, nose at -Z.
const WHEELS := [Vector3(0, -2.25, -4.6), Vector3(2.3, -2.25, 2.6), Vector3(-2.3, -2.25, 2.6)]
const LEGS := [Vector3(2.6, 0, 8.6), Vector3(-2.6, 0, 8.6), Vector3(0, 2.6, 8.6), Vector3(0, -2.6, 8.6)]
const HULL := [Vector3(0, 0, -7.6), Vector3(0, 0, 7.4), Vector3(0, 1.7, 0), Vector3(0, -1.6, 0),
	Vector3(0, -1.5, -5.0), Vector3(0, -1.5, 5.0), Vector3(6.2, -0.3, 4.0), Vector3(-6.2, -0.3, 4.0),
	Vector3(0, 1.5, 6.0)]
const BOOSTER_HULL := [Vector3(2.4, 0, 30.0), Vector3(-2.4, 0, 30.0), Vector3(0, 2.4, 30.0), Vector3(0, -2.4, 30.0)]


func total_mass() -> float:
	var m := dry_mass + fuel + mono + cargo_mass
	if booster_attached:
		m += booster_dry + booster_fuel
	return m


func inertia() -> Vector3:
	var m := total_mass()
	if booster_attached:
		return m * Vector3(70.0, 70.0, 4.0)
	return m * Vector3(15.0, 17.0, 4.0)


func forward() -> Vector3:
	return -basis.z


func pick_dominant() -> void:
	var best: CelestialBody = null
	for b in bodies:
		var body: CelestialBody = b
		if body.parent != null and pos.dist_to(body.pos) < body.soi:
			best = body
	if best == null:
		for b in bodies:
			var body: CelestialBody = b
			if body.parent == null:
				best = body
	dominant = best


## Local-frame telemetry without integrating (used before the mission starts / while paused).
func refresh_frame() -> void:
	if dominant == null:
		pick_dominant()
	var rel := pos.rel_d(dominant.pos)
	var rlen: float = sqrt(rel[0] * rel[0] + rel[1] * rel[1] + rel[2] * rel[2])
	up_dir = Vector3(rel[0] / rlen, rel[1] / rlen, rel[2] / rlen)
	altitude = rlen - dominant.radius
	agl = altitude - dominant.terrain_height(up_dir)
	surface_vel = vel - dominant.vel
	vspeed = surface_vel.dot(up_dir)
	hspeed = (surface_vel - up_dir * vspeed).length()


func step(dt: float) -> void:
	if dominant == null:
		pick_dominant()
	mass = total_mass()
	var I := inertia()
	var inv_b := basis.transposed()

	# ---------------- gravity (n-body point masses)
	var grav := Vector3.ZERO
	for b in bodies:
		var body: CelestialBody = b
		var rd := body.pos.rel_d(pos)
		var d2: float = rd[0] * rd[0] + rd[1] * rd[1] + rd[2] * rd[2]
		var k: float = body.gm / (d2 * sqrt(d2))
		grav += Vector3(rd[0] * k, rd[1] * k, rd[2] * k)

	# ---------------- local frame vs dominant body
	var rel := pos.rel_d(dominant.pos)
	var rlen: float = sqrt(rel[0] * rel[0] + rel[1] * rel[1] + rel[2] * rel[2])
	up_dir = Vector3(rel[0] / rlen, rel[1] / rlen, rel[2] / rlen)
	altitude = rlen - dominant.radius
	agl = altitude - dominant.terrain_height(up_dir)
	surface_vel = vel - dominant.vel
	vspeed = surface_vel.dot(up_dir)
	hspeed = (surface_vel - up_dir * vspeed).length()

	var force := Vector3.ZERO        # non-gravitational, world frame
	var torque_b := Vector3.ZERO     # body frame

	# ---------------- atmosphere
	density_now = dominant.density(altitude)
	var air_b := inv_b * surface_vel        # ship velocity through air, body frame
	airspeed = air_b.length()
	dyn_pressure = 0.5 * density_now * airspeed * airspeed
	mach = airspeed / 330.0
	aoa = 0.0
	var aero_ctrl := 0.0
	if density_now > 0.0 and airspeed > 0.5:
		var q := dyn_pressure
		var fwd_speed := -air_b.z
		aoa = atan2(-air_b.y, maxf(fwd_speed, 0.01))
		var beta := atan2(air_b.x, maxf(fwd_speed, 0.01))
		var vdir_b := air_b / airspeed
		var drag_b := Vector3.ZERO
		var lift_b := Vector3.ZERO
		if booster_attached:
			var cd := 0.35 + 1.4 * pow(sin(minf(absf(aoa) + absf(beta), PI * 0.5)), 2.0)
			drag_b = -vdir_b * cd * q * 14.0
			# Fins: static stability + damping
			torque_b += Vector3(-aoa, -beta, 0.0) * q * 14.0 * 30.0 * 0.25
		else:
			var S := 60.0
			var c := 8.0
			var stall := 1.0 if absf(aoa) < deg_to_rad(22.0) else 0.65
			# Hypersonic flow carries less lift per unit drag (Newtonian regime): L/D falls toward ~0.8.
			var hyper := lerpf(1.0, 0.5, clampf((mach - 2.0) / 3.0, 0.0, 1.0))
			var cl := (1.25 * sin(2.0 * aoa) + 0.3 * flaps * cos(aoa)) * stall * hyper
			var cd := 0.045 + 1.25 * pow(sin(aoa), 2.0) + 0.6 * pow(sin(beta), 2.0) + 0.05 * flaps
			if gear_down:
				cd += 0.035 * gear_pos
			if airbrake:
				cd += 0.22
			drag_b = -vdir_b * cd * q * S
			var lift_dir := Vector3(0.0, -air_b.z, air_b.y)
			if lift_dir.length_squared() > 1e-6:
				lift_b = lift_dir.normalized() * cl * q * S
			lift_b += Vector3(-sin(beta) * 0.9 * q * S * 0.4, 0.0, 0.0)
			# static stability and pitch/yaw/roll damping
			torque_b += Vector3(-aoa * 0.06, -beta * 0.08, 0.0) * q * S * c
			var damp := q * S * c * (c / (2.0 * maxf(airspeed, 20.0)))
			var w_b0 := inv_b * ang_vel
			torque_b += -Vector3(w_b0.x * 4.0, w_b0.y * 3.0, w_b0.z * 1.2) * damp
			aero_ctrl = 0.09 * q * S * c
		force += basis * (drag_b + lift_b)

	# ---------------- heating
	heat_flux = 1.83e-4 * sqrt(density_now) * pow(airspeed, 3.0) * heat_mult
	var absorb := (0.55 if shield_on else 1.0) * (1.0 + clampf((deg_to_rad(25.0) - aoa) / deg_to_rad(25.0), 0.0, 1.0) * 0.8)
	hull_temp += (heat_flux * absorb - SIGMA * 0.85 * (pow(hull_temp, 4.0) - pow(250.0, 4.0))) / 18000.0 * dt
	hull_temp = maxf(hull_temp, 200.0)

	# ---------------- engine
	var p_ratio := density_now / 1.225 if dominant.has_atmo else 0.0
	var target_thr := throttle_cmd if (engine_on and engine_enabled) else 0.0
	throttle = move_toward(throttle, target_thr, dt * 2.5)
	thrust_now = 0.0
	flameout = false
	if throttle > 0.001:
		var bf := boost_factor if boost else 1.0
		if booster_attached:
			if booster_fuel > 0.0:
				var isp := lerpf(booster_isp_vac, booster_isp_sl, clampf(p_ratio, 0.0, 1.0))
				thrust_now = booster_thrust * throttle * lerpf(1.0, booster_isp_sl / booster_isp_vac, clampf(p_ratio, 0.0, 1.0)) * bf
				var mdot := thrust_now / (isp * G0)
				booster_fuel = maxf(0.0, booster_fuel - mdot * dt)
				fuel_used += mdot * dt
			else:
				flameout = true
		else:
			if fuel > 0.0:
				var isp2 := lerpf(main_isp_vac, main_isp_sl, clampf(p_ratio, 0.0, 1.0))
				thrust_now = main_thrust * throttle * lerpf(1.0, main_isp_sl / main_isp_vac, clampf(p_ratio, 0.0, 1.0)) * bf
				var mdot2 := thrust_now / (isp2 * G0) * (1.15 if boost else 1.0)
				fuel = maxf(0.0, fuel - mdot2 * dt)
				fuel_used += mdot2 * dt
			else:
				flameout = true
	force += forward() * thrust_now
	var lever := 30.0 if booster_attached else 7.0
	var gimbal := thrust_now * 0.07 * lever

	# ---------------- RCS translation
	rcs_trans_activity = Vector3.ZERO
	if rcs_enabled and mono > 0.0 and in_trans.length_squared() > 0.0004:
		var t := in_trans.clamp(Vector3(-1, -1, -1), Vector3(1, 1, 1))
		rcs_trans_activity = t
		force += basis * Vector3(t.x, t.y, -t.z) * rcs_force
		var mflow := (absf(t.x) + absf(t.y) + absf(t.z)) * rcs_force / (rcs_isp * G0)
		mono = maxf(0.0, mono - mflow * dt)
		mono_used += mflow * dt

	# ---------------- rotation control (flight assist)
	var w_b := inv_b * ang_vel
	var rcs_avail := rcs_torque if (rcs_enabled and mono > 0.0) else 0.0
	var tmax := Vector3.ONE * ((rw_torque if rw_enabled else 0.0) + rcs_avail + aero_ctrl)
	tmax.x += gimbal
	tmax.y += gimbal
	var ctrl := _control_torque(I, w_b, tmax)
	rcs_rot_activity = ctrl / tmax.max(Vector3.ONE)
	if rcs_avail > 0.0:
		var rw := rw_torque if rw_enabled else 0.0
		var excess := (ctrl.abs() - Vector3.ONE * rw).max(Vector3.ZERO)
		var used := (excess.x + excess.y + excess.z) / maxf(rcs_torque, 1.0)
		var mflow_r := used * rcs_force * 0.5 / (rcs_isp * G0)
		mono = maxf(0.0, mono - mflow_r * dt)
		mono_used += mflow_r * dt
	torque_b += ctrl

	# ---------------- ground contacts
	var contact := _contacts(rel, I, dt)
	force += contact[0]
	torque_b += inv_b * contact[1]

	# ---------------- integrate (semi-implicit Euler)
	accel_proper = force / mass
	var g_now := accel_proper.length() / G0
	g_load = lerpf(g_load, g_now, clampf(dt * 8.0, 0.0, 1.0))
	if not clamped:
		max_g = maxf(max_g, g_load)
	var acc := grav + accel_proper
	if clamped:
		# The anchor was set from the station's pose at the END of the last step; carry it
		# along this step (7.7 km/s at real size = ~64 m per tick otherwise).
		anchor_pos.add(anchor_vel * dt)
		vel = anchor_vel
		pos.set_from(anchor_pos)
		ang_vel = Vector3.ZERO
	else:
		vel += acc * dt
		pos.add(vel * dt)
		var w_dot := (torque_b - w_b.cross(I * w_b)) / I
		w_b += w_dot * dt
		ang_vel = basis * w_b
		var wl := ang_vel.length()
		if wl > 1e-7:
			basis = Basis(ang_vel / wl, wl * dt) * basis
		basis = basis.orthonormalized()
	gear_pos = move_toward(gear_pos, 1.0 if gear_down else 0.0, dt * 0.5)


func _rate_ctrl(target: Vector3, w_b: Vector3, I: Vector3, tmax: Vector3) -> Vector3:
	var t := I * (target - w_b) * 4.0
	return t.clamp(-tmax, tmax)


func _control_torque(I: Vector3, w_b: Vector3, tmax: Vector3) -> Vector3:
	var stick := Vector3(in_rot.x, -in_rot.y, -in_rot.z)
	var active := stick.length() > 0.05
	match fa_mode:
		FA.OFF:
			holding = false
			return stick * tmax
		FA.STAB:
			holding = false
			return _rate_ctrl(stick * max_rate, w_b, I, tmax)
		FA.HOLD:
			if active:
				holding = false
				return _rate_ctrl(stick * max_rate, w_b, I, tmax)
			if not holding:
				hold_basis = basis
				holding = true
			var err := attitude_error(hold_basis)
			return _rate_ctrl((err * 1.5).clamp(-max_rate, max_rate), w_b, I, tmax)
		FA.NAV:
			holding = false
			if nav_dir.length_squared() < 0.5 or Vector2(stick.x, stick.y).length() > 0.3:
				return _rate_ctrl(stick * max_rate, w_b, I, tmax)
			var fwd := forward()
			var nd := nav_dir.normalized()
			var axis := fwd.cross(nd)
			var s := axis.length()
			var c := fwd.dot(nd)
			var ang := atan2(s, c)
			var err_w := Vector3.ZERO
			if s > 1e-6:
				err_w = axis / s * ang
			elif c < 0.0:
				err_w = basis.x * PI
			var err_b := basis.transposed() * err_w
			err_b.z = 0.0
			var tgt := (err_b * 1.3).clamp(-max_rate, max_rate)
			tgt.z = stick.z * max_rate.z
			return _rate_ctrl(tgt, w_b, I, tmax)
	return Vector3.ZERO


## Body-frame rotation vector that takes the current attitude to `target`.
func attitude_error(target: Basis) -> Vector3:
	var r := basis.transposed() * target
	var q := r.get_rotation_quaternion()
	if q.w < 0.0:
		q = -q
	var ang := q.get_angle()
	if ang < 1e-6:
		return Vector3.ZERO
	return q.get_axis() * ang


func _contacts(rel: PackedFloat64Array, I: Vector3, dt: float) -> Array:
	var f_total := Vector3.ZERO
	var t_total := Vector3.ZERO
	touching = false
	contact_points = 0
	hull_hit = 0.0
	gear_hit = 0.0
	if clamped or agl > 80.0:
		_contact_prev.clear()
		landed = clamped
		return [f_total, t_total]
	var pts := []
	if gear_pos > 0.95:
		for p in WHEELS:
			pts.append([p, 1])
		for p in LEGS:
			pts.append([p, 2])
	for p in HULL:
		pts.append([p, 0])
	if booster_attached:
		for p in BOOSTER_HULL:
			pts.append([p, 0])
	var m := total_mass()
	var k := m * 120.0
	var c := m * 14.0
	var idx := 0
	for entry in pts:
		idx += 1
		var pb: Vector3 = entry[0]
		var kind: int = entry[1]
		var w := basis * pb
		var rx: float = rel[0] + w.x
		var ry: float = rel[1] + w.y
		var rz: float = rel[2] + w.z
		var dl := sqrt(rx * rx + ry * ry + rz * rz)
		var n := Vector3(rx / dl, ry / dl, rz / dl)
		var h := dl - dominant.radius - dominant.terrain_height(n)
		if h >= 0.0:
			_contact_prev.erase(idx)
			continue
		touching = true
		contact_points += 1
		var vp := surface_vel + ang_vel.cross(w)
		var vn := vp.dot(n)
		if not _contact_prev.has(idx):
			var imp := -vn
			last_impact = maxf(last_impact, imp)
			if kind == 0:
				hull_hit = maxf(hull_hit, imp)
			else:
				gear_hit = maxf(gear_hit, imp)
		_contact_prev[idx] = true
		var fn := maxf(0.0, -k * h - c * vn)
		var fvec := n * fn
		var vt := vp - n * vn
		if kind == 1:
			var fwd_g := forward().slide(n).normalized()
			var lat := n.cross(fwd_g)
			var mu_roll := 0.55 if airbrake else 0.025
			var v_f := vt.dot(fwd_g)
			var v_l := vt.dot(lat)
			fvec += -fwd_g * signf(v_f) * minf(mu_roll * fn, absf(v_f) * m * 3.0)
			fvec += -lat * signf(v_l) * minf(0.8 * fn, absf(v_l) * m * 3.0)
		else:
			var mu := 0.7 if kind == 2 else 0.45
			var vtl := vt.length()
			if vtl > 1e-5:
				fvec += -vt / vtl * minf(mu * fn, vtl * m * 3.0)
		f_total += fvec
		t_total += w.cross(fvec)
	landed = touching and surface_vel.length() < 0.6
	return [f_total, t_total]


func apply_impulse(impulse: Vector3, offset_world: Vector3) -> void:
	var m := total_mass()
	vel += impulse / m
	var I := inertia()
	var tb := basis.transposed() * offset_world.cross(impulse)
	ang_vel += basis * (tb / I)


## Copies everything needed to run a prediction.
func clone_state() -> ShipSim:
	var s := ShipSim.new()
	s.bodies = bodies
	s.dominant = dominant
	s.pos = pos.copy()
	s.vel = vel
	s.basis = basis
	s.ang_vel = ang_vel
	s.dry_mass = dry_mass
	s.fuel = fuel
	s.mono = mono
	s.cargo_mass = cargo_mass
	s.booster_attached = booster_attached
	s.booster_fuel = booster_fuel
	s.gear_down = gear_down
	s.gear_pos = gear_pos
	s.shield_on = shield_on
	s.fa_mode = fa_mode
	return s
