extends Mission
## (a) Launch to orbit: checklist, countdown, liftoff, pitch program, staging,
## apoapsis targeting, circularisation, satellite deployment.

const TARGET_AP := 200000.0
const TARGET_PE := 150000.0
const CUT_PE := -300000.0    # orbit low point at main-engine cutoff (a short top-up burn finishes)

var countdown := 10.0
var counting := false
var holding := false
var _last_tick := 11
var satellite: Dictionary = {}
var booster: Dictionary = {}
var _deploy_timer := -1.0
var _liftoff := false


func setup() -> void:
	id = "launch"
	title = "FIRST LIGHT"
	tagline = "Launch to orbit"
	briefing = "Our satellite needs a ride to space! Power up the Falcon, count down, blast off, and fly into a circle around the Earth. Then open the cargo bay and let the satellite go."
	pilot_job = "Arm and light the engine at T-5, then fly the green marker up and over toward the east. Cut the engine when APOAPSIS is 200 km and you are going about 7.6 km/s, then burn again at the top to make the orbit round."
	ops_job = "Watch the booster fuel. When it runs out press your TRIGGER to STAGE — it flies home to the tower catch by itself. In orbit: open the CARGO DOORS, switch to ARM mode, and press TRIGGER to deploy the satellite."
	start_callout = "Launch sequence start. T minus 10."
	star_thresholds = [1200, 1700]
	objectives = [
		{"text": "COUNTDOWN: ENGINE ARM, then IGNITION and full throttle at T-5", "role": "PILOT"},
		{"text": "Fly the green ascent marker (or PROGRADE assist + NAV GUIDANCE)", "role": "PILOT"},
		{"text": "Booster empty! Press TRIGGER (RCS mode) to STAGE", "role": "OPS"},
		{"text": "Burn on the marker until APOAPSIS is 200 km and SPEED ~7.6 km/s, then throttle to zero", "role": "PILOT"},
		{"text": "Coast up to apoapsis (Commander: time warp on NAV page)", "role": "BOTH"},
		{"text": "Circularise: burn PROGRADE until PERIAPSIS is above 150 km", "role": "PILOT"},
		{"text": "CARGO DOORS open, mode ARM, TRIGGER to deploy the satellite", "role": "OPS"},
	]
	game.sun_dir = Vector3(0.45, 0.25, -0.86).normalized()
	var up: Vector3 = game.pad_dir
	var east := CelestialBody.east_at(up)
	var e := earth()
	var h := e.terrain_height(up) + 8.6 + 22.0    # legs/booster skirt clearance
	var r := e.radius + h
	sim.pos.set_xyz(up.x * r, up.y * r, up.z * r)
	sim.vel = Vector3.ZERO
	sim.basis = ship_basis(up, -east)
	sim.booster_attached = true
	sim.booster_fuel = sim.booster_fuel_max
	sim.fuel = sim.fuel_max
	sim.clamped = true
	sim.anchor_pos = sim.pos.copy()
	sim.anchor_vel = Vector3.ZERO
	booster = game.add_entity("booster", {"mode": "attached", "offset": Vector3(0, 0, 19.5), "radius": 14.0, "name": "BOOSTER"})
	satellite = game.add_entity("satellite", {"mode": "attached", "offset": Vector3(0, 0.6, 1.2), "radius": 2.0, "name": "SATELLITE"})
	game.nav_targets = [{"name": "STATION", "entity": game.station}, {"name": "MOON", "body": moon()}]
	game.nav_vector = "GUIDANCE"


func start() -> void:
	counting = true
	countdown = 10.0
	_last_tick = 11
	_announce_objective()


func guidance_dir() -> Vector3:
	var up := sim.up_dir
	var east := CelestialBody.east_at(up)
	var alt := sim.altitude
	# Gravity turn: vertical for the first 300 m, then pitch over toward the horizon by ~75 km.
	var pitch_deg := 90.0 - 82.0 * clampf(pow(maxf(alt - 300.0, 0.0) / 75000.0, 0.5), 0.0, 1.0)
	if alt > 25000.0:
		# Above the thick air: hold the apoapsis on the 200 km target while speed builds up
		# (direct ascent: pitch below the horizon late in the burn).
		var el := orbit_elements()
		var ap: float = el["ap_alt"]
		if el["escaping"]:
			ap = 1.0e9
		var want := clampf((TARGET_AP - ap) / 2500.0 + (maxf(0.0, 30.0 - sim.vspeed) / 15.0 if alt > 140000.0 else 0.0), -12.0, 15.0)
		pitch_deg = minf(pitch_deg, want) if ap > TARGET_AP - 20000.0 else pitch_deg
	guidance["pitch_target"] = pitch_deg
	var p := deg_to_rad(pitch_deg)
	return (east * cos(p) + up * sin(p)).normalized()


func update(dt: float) -> void:
	guidance_dir()
	if counting:
		_update_countdown(dt)
		return
	var el := orbit_elements()
	match step:
		1:
			if sim.booster_attached and sim.booster_fuel <= 0.0:
				Sfx.tone(300.0, 0.3, 0.2)
				advance("Booster burnout! Ops, STAGE now!")
		3:
			if el["ap_alt"] >= TARGET_AP - 3000.0 and float(el["pe_alt"]) > CUT_PE:
				if sim.throttle_cmd < 0.05 or not sim.engine_on:
					advance("Engine cutoff. Coasting to apoapsis.")
				elif int(game.mission_time * 2.0) % 6 == 0:
					guidance["flash"] = "CUT THROTTLE!"
		4:
			if sim.altitude > 120000.0 and (float(el["time_to_ap"]) < 25.0 or sim.vspeed < 5.0):
				if game.warp > 1.0:
					game.set_warp(1.0)
				advance("Approaching apoapsis. Pilot, burn prograde!")
		5:
			if float(el["pe_alt"]) > TARGET_PE:
				advance("We are in orbit! Cut throttle. Ops, deploy the satellite.")
	if _deploy_timer >= 0.0:
		_deploy_timer += dt
		if _deploy_timer > 2.5:
			_deploy_timer = -1.0
			advance("Satellite deployed! Great job, crew!")
	if step >= 2 and sim.altitude < 500.0 and sim.vspeed < -30.0:
		pass


func _update_countdown(dt: float) -> void:
	if not holding:
		countdown = maxf(0.0, countdown - dt)
	var tick := ceili(countdown)
	if tick != _last_tick and countdown > 0.0:
		_last_tick = tick
		Sfx.countdown_tick(false)
		if tick == 6:
			Voice.say("Ignition sequence start. Pilot, engine arm and ignition!", 1)
		elif tick <= 5 or tick == 10:
			Voice.say(str(tick))
	guidance["countdown"] = countdown
	if countdown <= 0.0:
		var twr := sim.thrust_now / (sim.total_mass() * 9.81)
		if twr > 1.05 and sim.throttle > 0.85:
			counting = false
			holding = false
			sim.clamped = false
			_liftoff = true
			Sfx.countdown_tick(true)
			game.camera_shake = 1.0
			game.add_score("Clean liftoff", 150)
			advance("Liftoff! We have liftoff!")
		elif not holding:
			holding = true
			Voice.say("Hold, hold, hold! Pilot: engine arm, ignition, and full throttle!", 2)
		elif twr > 1.05:
			pass
	else:
		holding = false


func on_ops_trigger() -> void:
	if not sim.booster_attached:
		return
	if counting:
		Voice.say("Not yet! The booster is still needed.", 1)
		return
	var early := sim.booster_fuel > 100.0
	sim.booster_attached = false
	booster["vel"] = sim.vel + sim.basis.z * 6.0
	booster["basis"] = sim.basis
	game.begin_booster_recovery(booster)
	game.stage_flash = 1.0
	game.camera_shake = 0.6
	Sfx.clunk()
	game.game_event.emit("staged", {})
	if sim.engine_on:
		Voice.say("Staging! Main engine running.", 1)
	if step == 2:
		game.add_score("Staged on time", 150)
		advance()
	elif early:
		Voice.say("Early staging! We left fuel in the booster.", 1)
		if step == 1:
			step = 2
			advance()


func on_arm_trigger() -> void:
	if step != 6 or satellite.get("mode", "") != "attached":
		return
	satellite["mode"] = "free"
	satellite["vel"] = sim.vel + sim.basis.y * 0.8
	satellite["ang_vel"] = sim.basis.z * 0.05
	satellite["deployed"] = true
	Sfx.clunk()
	Voice.say("Satellite released! Solar panels opening.", 1)
	_deploy_timer = 0.0


func cheat_advance() -> void:
	match step:
		0:
			counting = false
			sim.clamped = false
			sim.engine_on = true
			advance()
		1:
			sim.booster_fuel = 0.0
			advance()
		2:
			on_ops_trigger()
			if step == 2:
				advance()
		3:
			# skip the burn: straight onto the target orbit (real-size Earth: a skipped ascent
			# would otherwise leave the ship falling back from a few km)
			sim.engine_on = false
			sim.throttle = 0.0
			set_circular_orbit(earth(), 200000.0, 0.0)
			advance()
		6:
			on_arm_trigger()
			_deploy_timer = 3.0
			update(0.0)
		_:
			advance()


func final_score() -> void:
	super.final_score()
	var el := orbit_elements()
	var e: float = el["e"]
	game.add_score("Round orbit (e=%.3f)" % e, clampi(int(300.0 * (1.0 - e * 20.0)), 0, 300))
	game.add_score("Fuel left %d kg" % int(sim.fuel), int(sim.fuel / 20.0))
	game.add_score("Max G %.1f" % sim.max_g, 150 if sim.max_g < 4.0 else 50)
