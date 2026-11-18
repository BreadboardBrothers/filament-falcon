extends Mission
## Flight 15 (Nov 13–14, 2026): tower launch from Starbase OLP-2, 26 Starlink V3 through
## the PEZ door, first ship Mechazilla catch. After liftoff the flight is fully automatic
## so the crew can watch. Booster 22 boosts back toward land, raises the real low-fuel-mass
## alarm, GNC-aborts the catch and flies to a designated Gulf spot where FTS triggers.
## See docs/game/FLIGHT15.md for sources and the real-vs-modeled table.

const STARBASE := Vector2(25.99677, -97.15799)
const INC_DEG := 30.5
const AZ_DEG := 107.53
const ORBIT_ALT := 277000.0
const SAT_COUNT := 26
const CATCH_HEIGHT := 53.5  # chopsticks (~58 m) minus forward-flap fittings

# SpaceX published MET (seconds). Used as the event order; long coasts are time-compressed.
const T_MAXQ := 58.0
const T_MECO := 139.0
const T_STAGE := 141.0
const T_SECO := 489.0
const T_INS_START := 1570.0
const T_INS_END := 1590.0
const T_DEP_START := 2101.0
const T_DEP_END := 4660.0
const T_DEORBIT := 77757.0
const T_ENTRY := 79846.0

var booster: Dictionary = {}
var sats: Array = []
var events: Array = []
var countdown := 10.0
var counting := false
var holding := false
var _last_tick := 11
var liftoff := false
var phase := "prelaunch"
var profile_t := 0.0
var deployed := 0
var _deploy_cd := 0.0
var plasma_seen := false
var plasma_off := false
var flaps_moved := false
var caught := false
var _flip_t := 0.0
var _auto_stage_t := 0.0
var _hold_basis := Basis.IDENTITY
var _entry_u := 0.0


func setup() -> void:
	id = "flight15"
	title = "FLIGHT 15"
	tagline = "First Starship tower catch"
	briefing = "Flight 15 lifts off from SpaceX Starbase in Texas, just like the real flight on 13 November 2026. After you light the engines, sit back and watch: the booster comes home, Starlink satellites pop out of the PEZ door, then the ship flies through the plasma, flips, and is caught by Mechazilla. This cockpit is crewed — that's our one change from the real flight."
	pilot_job = "For launch only: ENGINE ARM, IGNITION and full throttle at T minus 5. After liftoff the ship flies itself — look around and enjoy the view."
	ops_job = "Watch the show. After liftoff you don't need to stage, open the door or fly. Switch camera views any time."
	commander_tip = "START begins the countdown. After liftoff everything is automatic. Use VIEW to switch cockpit and chase. WARP is used by the flight itself during the long coast."
	start_callout = "Flight 15. Starbase Pad 2. T minus 10."
	star_thresholds = [800, 1400]
	objectives = [
		{"text": "LAUNCH: ENGINE ARM, IGNITION and full throttle at T-5", "role": "PILOT"},
		{"text": "Watch staging and the booster's return", "role": "ALL"},
		{"text": "Watch Starlink deploy through the PEZ door", "role": "ALL"},
		{"text": "Watch entry, the flip, and the Mechazilla catch", "role": "ALL"},
	]
	game.relocate_pad(Geo.game_dir(STARBASE.x, STARBASE.y), {"site": "starbase", "name": "STARBASE OLP-2"})
	# Late afternoon at Starbase (real liftoff 16:47 CST).
	game.sun_dir = Vector3(-0.55, 0.35, -0.76).normalized()
	var up: Vector3 = game.pad_dir
	var east: Vector3 = CelestialBody.east_at(up)
	var e := earth()
	var h := e.terrain_height(up) + 8.6 + 22.0
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
	sim.fa_mode = ShipSim.FA.NAV
	sim.flap_fwd = Vector2.ZERO
	sim.flap_aft = Vector2.ZERO
	booster = game.add_entity("booster", {"mode": "attached", "offset": Vector3(0, 0, 19.5), "radius": 14.0, "name": "BOOSTER 22"})
	sats.clear()
	for i in SAT_COUNT:
		var off := Vector3(0.15, 0.05, 0.9 - i * 0.11)
		var sat: Dictionary = game.add_entity("starlink", {"mode": "attached", "offset": off, "radius": 1.6, "name": "STARLINK %d" % (i + 1), "visible": i < 3})
		sats.append(sat)
	game.nav_targets = [{"name": "STARBASE", "entity": game.entities_of("pad")[0]}]
	game.nav_vector = "GUIDANCE"
	game.view_mode = 0
	_log("setup")


func start() -> void:
	counting = true
	countdown = 10.0
	_last_tick = 11
	_announce_objective()


func guidance_dir() -> Vector3:
	if not liftoff:
		return game.pad_dir
	if phase in ["ascent", "stage", "second_stage"]:
		return _ascent_dir()
	if phase in ["insert"]:
		return sim.surface_vel.normalized() if sim.surface_vel.length() > 1.0 else sim.forward()
	if phase in ["deorbit"]:
		return -sim.surface_vel.normalized() if sim.surface_vel.length() > 1.0 else -sim.forward()
	if phase in ["entry", "swoosh"]:
		return _entry_nose()
	if phase in ["flip", "landing", "catching", "caught"]:
		return sim.up_dir
	return sim.forward()


func update(dt: float) -> void:
	if counting:
		_update_countdown(dt)
		return
	if not liftoff:
		return
	game.watch_only = true
	# Auto-stage if still attached after MECO-equivalent, so the show cannot soft-lock.
	if sim.booster_attached:
		_auto_stage_t += dt
		var ready: bool = sim.booster_fuel <= 0.0 or sim.altitude > 70000.0 or _auto_stage_t > (5.0 if game.test_mode else 160.0)
		if ready and (sim.booster_fuel <= 200.0 or sim.altitude > 60000.0 or game.test_mode):
			_stage()
	_update_card()


func physics(h: float) -> void:
	if not liftoff or game.state != Game.State.ACTIVE:
		return
	profile_t += h
	_poll_booster()
	_drive(h)


func _drive(h: float) -> void:
	match phase:
		"ascent", "stage":
			_fly_ascent(h)
			if phase == "ascent" and profile_t >= (8.0 if game.test_mode else T_MAXQ) and not _has("maxq"):
				_log("maxq")
				Voice.say("Max Q.", 1)
		"second_stage":
			_fly_ascent(h)
			if sim.altitude > 140000.0 or profile_t > (20.0 if game.test_mode else T_SECO + 5.0):
				sim.engine_on = false
				sim.throttle = 0.0
				sim.throttle_cmd = 0.0
				_log("seco")
				_set_phase("insert_coast")
				Voice.say("Engine cutoff. Coasting to the insertion burn.", 1)
		"insert_coast":
			# Wait for the booster show (FTS) before warping the long coast, so the kids see it.
			var booster_done: bool = str(booster.get("recovery", "")) == "destroyed" or bool(booster.get("destroyed", false))
			if not booster_done and not game.test_mode and _phase_hold() < 180.0:
				game.set_warp(1.0)
				return
			if not game.test_mode and not booster_done:
				game.set_warp(4.0)
			if game.test_mode and not booster_done and _phase_hold() < 40.0:
				game.set_warp(1.0)
				return
			if game.test_mode or booster_done or profile_t > T_INS_START - 5.0 or _phase_hold() > (8.0 if game.test_mode else 200.0):
				if not game.test_mode:
					game.set_warp(100.0)
			if game.test_mode or booster_done or _phase_hold() > (4.0 if game.test_mode else 40.0):
				game.set_warp(1.0)
				_place_pre_insertion()
				_set_phase("insert")
				sim.engine_on = true
				sim.throttle_cmd = 1.0
				Voice.say("Orbital insertion burn.", 1)
				_log("insert_start")
		"insert":
			sim.engine_on = true
			sim.throttle_cmd = 1.0
			sim.fa_mode = ShipSim.FA.NAV
			if _phase_hold() > (2.0 if game.test_mode else 20.0) or float(orbit_elements().get("pe_alt", -1e9)) > 200000.0:
				sim.engine_on = false
				sim.throttle_cmd = 0.0
				_place_orbit()
				_log("insert_end")
				_set_phase("deploy")
				game.pez_door = 0.0
				Voice.say("In orbit. Opening the PEZ door.", 1)
				game.cine_follow = "ship"
				game.cine_style = "pez"
				game.view_mode = 1
		"deploy":
			game.set_warp(1.0)
			game.pez_door = move_toward(game.pez_door, 1.0, h / 2.5)
			_deploy_tick(h)
			if deployed >= SAT_COUNT:
				_log("deploy_complete")
				if step == 2:
					advance("All 26 Starlink satellites are away.")
				else:
					Voice.say("All 26 Starlink satellites are away.", 1)
				_set_phase("coast")
				if not game.test_mode:
					game.set_warp(10000.0)
				game.cine_style = "wide"
		"coast":
			# Compressed 20-hour coast; return-check callouts on the way.
			var t: float = _phase_hold()
			if game.test_mode or t > 1.2:
				game.set_warp(1.0)
				_place_pre_entry()
				_set_phase("deorbit")
				sim.engine_on = true
				sim.throttle_cmd = 0.6
				Voice.say("Deorbit burn. One Raptor.", 1)
				_log("deorbit")
		"deorbit":
			sim.engine_on = true
			sim.throttle_cmd = 0.6
			if _phase_hold() > (1.5 if game.test_mode else 10.0):
				sim.engine_on = false
				sim.throttle_cmd = 0.0
				_log("deorbit_end")
				_set_phase("entry")
				_entry_u = 0.0
				Voice.say("Entry interface. Plasma ahead.", 1)
				_log("entry")
				game.cine_follow = "ship"
				game.cine_style = "plasma"
				game.view_mode = 1
		"entry", "swoosh":
			_fly_entry(h)
		"flip", "landing", "catching":
			_fly_catch(h)
		"caught":
			sim.engine_on = false
			sim.throttle_cmd = 0.0
			sim.clamped = true
			guidance["chopstick_close"] = 1.0


func _fly_ascent(h: float) -> void:
	sim.engine_on = true
	sim.throttle_cmd = 1.0
	sim.fa_mode = ShipSim.FA.NAV
	sim.clamped = false
	_orient(_ascent_basis(), h, 2.2)
	if game.test_mode and sim.altitude < 80000.0 and phase == "ascent":
		# Headless test: climb fast enough to reach staging without a full 2-minute burn.
		var up: Vector3 = sim.up_dir
		sim.vel += up * 180.0 * h + _downrange() * 90.0 * h
		var p := sim.pos.copy()
		p.add(up * 400.0 * h)
		sim.pos = p


func _stage() -> void:
	if not sim.booster_attached:
		return
	sim.booster_attached = false
	booster["vel"] = sim.vel + sim.basis.z * 6.0
	booster["basis"] = sim.basis
	game.begin_booster_recovery(booster, {"profile": "flight15"})
	game.stage_flash = 1.0
	game.camera_shake = 0.6
	Sfx.clunk()
	game.game_event.emit("staged", {})
	_log("staging")
	Voice.say("Hot staging. Booster is boosting back.", 1)
	_set_phase("second_stage")
	game.cine_follow = "booster"
	game.cine_style = "aft"
	game.view_mode = 1
	if step == 1:
		advance()
	sim.engine_on = true
	sim.throttle_cmd = 1.0
	if game.test_mode:
		var pads: Array = game.entities_of("pad")
		if not pads.is_empty():
			var pad: Dictionary = pads[0]
			var pb: Basis = pad.get("basis", Basis.IDENTITY)
			var bp: BigVec = pad["pos"].copy()
			bp.add(pb.x * 18000.0 + pb.y * 35000.0)
			booster["pos"] = bp
			booster["vel"] = pad.get("vel", Vector3.ZERO) + pb.x * 180.0 + pb.y * 40.0
			booster["basis"] = pb


func _deploy_tick(h: float) -> void:
	if game.pez_door < 0.85 or deployed >= SAT_COUNT:
		return
	_deploy_cd -= h
	if _deploy_cd > 0.0:
		return
	var sat: Dictionary = sats[deployed]
	sat["mode"] = "free"
	sat["visible"] = true
	sat["vel"] = sim.vel + sim.basis.x * 1.6
	sat["ang_vel"] = sim.basis.z * 0.02
	sat["deployed"] = true
	deployed += 1
	_deploy_cd = 0.05 if game.test_mode else 2.0
	Sfx.clunk()
	if deployed == 1:
		_log("deploy_start")
		Voice.say("PEZ door open. Deploying Starlink.", 1)
	if deployed == SAT_COUNT:
		_deploy_cd = 0.0


func _fly_entry(h: float) -> void:
	game.set_warp(1.0 if game.test_mode or _entry_u > 0.55 else (1.0 if sim.airspeed < 900.0 else 1.0))
	_entry_u = minf(1.0, _entry_u + h / (6.0 if game.test_mode else 90.0))
	_follow_entry_path(_entry_u, h)
	_entry_flaps(h)
	_orient(_entry_basis(), h, 1.6)
	sim.engine_on = false
	sim.throttle_cmd = 0.0
	if sim.heat_flux > 20000.0 or sim.hull_temp > 800.0 or sim.altitude < 80000.0:
		if not plasma_seen:
			plasma_seen = true
			_log("plasma_on")
			Voice.say("Plasma glow.", 1)
	if plasma_seen and sim.heat_flux < 8000.0 and sim.altitude < 25000.0 and not plasma_off:
		plasma_off = true
		_log("plasma_off")
	if _entry_u > 0.72 and phase != "swoosh":
		_set_phase("swoosh")
		Voice.say("Swoosh out over the Gulf.", 1)
		game.cine_style = "wide"
	if _entry_u >= 1.0 or (game.test_mode and _entry_u > 0.85 and sim.altitude < 4000.0):
		_set_phase("flip")
		_flip_t = 0.0
		sim.engine_on = true
		sim.throttle_cmd = 1.0
		guidance["engines"] = 3
		Voice.say("Landing burn. Flip.", 1)
		_log("landing_burn")
		_log("flip")
		game.cine_style = "flip"
		game.cine_follow = "ship"
		game.view_mode = 1


func _fly_catch(h: float) -> void:
	_flip_t += h
	# Stow flaps during the flip, 3 → 2 → 1 engines, then chopsticks.
	var stow: float = clampf(_flip_t / 2.0, 0.0, 1.0)
	sim.flap_fwd = sim.flap_fwd.lerp(Vector2.ZERO, stow)
	sim.flap_aft = sim.flap_aft.lerp(Vector2.ZERO, stow)
	sim.engine_on = true
	var pads: Array = game.entities_of("pad")
	if pads.is_empty():
		return
	var pad: Dictionary = pads[0]
	var catch_pos: BigVec = pad["pos"].copy()
	var pb: Basis = pad.get("basis", Basis.IDENTITY)
	catch_pos.add(pb * Vector3(8.0, CATCH_HEIGHT, 0.0))
	var up: Vector3 = pb.y
	if _flip_t < 2.2:
		guidance["engines"] = 3
		sim.throttle_cmd = 1.0
	elif _flip_t < 4.0:
		if guidance.get("engines", 3) == 3:
			guidance["engines"] = 2
			_log("engines_3to2")
		sim.throttle_cmd = 0.7
	else:
		if guidance.get("engines", 2) == 2:
			guidance["engines"] = 1
			_log("engines_2to1")
		sim.throttle_cmd = 0.35
	_orient(ship_basis(up, pb.x), h, 3.0)
	var to: Vector3 = catch_pos.rel(sim.pos)
	var rel_v: Vector3 = sim.vel - pad.get("vel", Vector3.ZERO)
	# Close gently on the chopsticks.
	sim.vel = sim.vel.lerp(pad.get("vel", Vector3.ZERO) + to * 0.35, clampf(h * 1.4, 0.0, 1.0))
	# Damp residual velocity so we never slam the hull into the tower.
	sim.vel = sim.vel.lerp(pad.get("vel", Vector3.ZERO), clampf(h * 0.5, 0.0, 0.4))
	if to.length() < 120.0:
		guidance["chopstick_close"] = 1.0
		if phase != "catching":
			_set_phase("catching")
			game.cine_follow = "pad"
			game.cine_style = "tower"
	if to.length() < 14.0 or _flip_t > (8.0 if game.test_mode else 18.0):
		sim.pos = catch_pos.copy()
		sim.vel = pad.get("vel", Vector3.ZERO)
		sim.basis = ship_basis(up, pb.x)
		sim.engine_on = false
		sim.throttle_cmd = 0.0
		sim.clamped = true
		sim.anchor_pos = sim.pos.copy()
		sim.anchor_vel = sim.vel
		guidance["chopstick_close"] = 1.0
		if not caught:
			caught = true
			_log("catch")
			Voice.say("Catch confirmed! Welcome back to Starbase.", 1)
			game.add_score("Ship caught at Mechazilla", 400)
			_set_phase("caught")
			if step < objectives.size():
				step = objectives.size() - 1
				advance("Flight 15 is complete. Starship is home.")


func _update_countdown(dt: float) -> void:
	if not holding:
		countdown = maxf(0.0, countdown - dt)
	var tick: int = ceili(countdown)
	if tick != _last_tick and countdown > 0.0:
		_last_tick = tick
		Sfx.countdown_tick(false)
		if tick == 6:
			Voice.say("Ignition sequence start. Pilot, engine arm and ignition!", 1)
		elif tick <= 5 or tick == 10:
			Voice.say(str(tick))
	guidance["countdown"] = countdown
	if countdown <= 0.0:
		var twr: float = sim.thrust_now / maxf(sim.total_mass() * 9.81, 1.0)
		if twr > 1.05 and sim.throttle > 0.85:
			counting = false
			holding = false
			sim.clamped = false
			liftoff = true
			profile_t = 0.0
			_set_phase("ascent")
			Sfx.countdown_tick(true)
			game.camera_shake = 1.0
			game.add_score("Clean liftoff", 150)
			_log("liftoff")
			game.view_mode = 1
			game.cine_follow = "ship"
			game.cine_style = "wide"
			advance("Liftoff from Starbase!")
		elif not holding:
			holding = true
			Voice.say("Hold, hold, hold! Pilot: engine arm, ignition, and full throttle!", 2)
		elif game.test_mode:
			sim.engine_on = true
			sim.throttle = 1.0
			sim.throttle_cmd = 1.0
	else:
		holding = false


func on_ops_trigger() -> void:
	# Watch-only after liftoff: staging and deploy are automatic. Before liftoff, ignore.
	pass


func cheat_advance() -> void:
	match step:
		0:
			counting = false
			holding = false
			sim.clamped = false
			sim.engine_on = true
			sim.throttle = 1.0
			sim.throttle_cmd = 1.0
			liftoff = true
			profile_t = 0.0
			_set_phase("ascent")
			_log("liftoff")
			game.watch_only = true
			advance("Liftoff from Starbase!")
		1:
			if sim.booster_attached:
				sim.booster_fuel = 0.0
				_stage()
			# Finish the booster story instantly for the smoke test, then jump to deploy.
			_force_booster_fts()
			_place_orbit()
			if step == 1:
				advance()
		2:
			game.pez_door = 1.0
			while deployed < SAT_COUNT:
				_deploy_cd = 0.0
				_deploy_tick(1.0)
			_log("deploy_complete")
			advance()
		3:
			plasma_seen = true
			plasma_off = true
			flaps_moved = true
			_log("plasma_on")
			_log("plasma_off")
			_log("flip")
			caught = true
			guidance["chopstick_close"] = 1.0
			_log("catch")
			_set_phase("caught")
			advance("Flight 15 is complete. Starship is home.")
		_:
			advance()


func commander_actions() -> Array:
	return []


func _force_booster_fts() -> void:
	if booster.is_empty():
		return
	if str(booster.get("recovery", "")) == "destroyed":
		return
	var dir: Vector3 = Geo.game_dir(Geo.F15_FTS.x, Geo.F15_FTS.y).normalized()
	var r: float = earth().radius + earth().terrain_height(dir) + 8.0
	var p := earth().pos.copy()
	p.add(dir * r)
	booster["pos"] = p
	booster["vel"] = earth().vel
	booster["error"] = "low fuel mass alarm"
	booster["abort"] = true
	booster["destroyed"] = true
	booster["destruct_pos"] = p.copy()
	booster["recovery"] = "destroyed"
	booster["mode"] = "landed"
	booster["visible"] = false
	booster["thrust_frac"] = 0.0
	if not _has("booster_error"):
		_log("booster_error")
	if not _has("booster_divert"):
		_log("booster_divert")
	if not _has("booster_fts"):
		_log("booster_fts")
	game.raise_caution("booster_fuel", "Low fuel mass alarm: boostback ended early.")
	game.raise_caution("booster_gnc", "GNC abort: booster not in the place it was supposed to be to proceed with a catch. Diverting to the offshore landing location.")
	game.raise_caution("booster_fts", "Landing burn shutdown. Flight termination system triggered.")



func _poll_booster() -> void:
	if booster.is_empty():
		return
	if str(booster.get("error", "")) != "" and not _has("booster_error"):
		_log("booster_error")
		game.cine_follow = "booster"
		game.cine_style = "side"
		game.view_mode = 1
	if bool(booster.get("abort", false)) and not _has("booster_divert"):
		_log("booster_divert")
		game.cine_follow = "booster"
		game.cine_style = "wide"
		game.view_mode = 1
	if (str(booster.get("recovery", "")) in ["fts", "destroyed"] or bool(booster.get("destroyed", false))) and not _has("booster_fts"):
		_log("booster_fts")
		game.cine_follow = "booster"
		game.cine_style = "wide"
		game.view_mode = 1
	# After the destruct, cut back to the ship for the rest of the show.
	if _has("booster_fts") and phase in ["insert_coast", "insert", "deploy", "coast"] and game.cine_follow == "booster":
		if _phase_hold() > 2.0 or game.test_mode:
			game.cine_follow = "ship"
			game.cine_style = "chase" if phase != "deploy" else "pez"


func _ascent_dir() -> Vector3:
	var up: Vector3 = sim.up_dir if sim.up_dir.length() > 0.5 else game.pad_dir
	var pitch := 90.0 - 82.0 * clampf(pow(maxf(sim.altitude - 300.0, 0.0) / 75000.0, 0.5), 0.0, 1.0)
	var p := deg_to_rad(pitch)
	return (_downrange() * cos(p) + up * sin(p)).normalized()


func _downrange() -> Vector3:
	var up: Vector3 = game.pad_dir
	var east: Vector3 = CelestialBody.east_at(up)
	var north: Vector3 = up.cross(east).normalized()
	var az := deg_to_rad(AZ_DEG)
	return (east * sin(az) + north * cos(az)).normalized()


func _ascent_basis() -> Basis:
	var d: Vector3 = _ascent_dir()
	var up: Vector3 = sim.up_dir if sim.up_dir.length() > 0.5 else game.pad_dir
	return ship_basis(d, up)


func _entry_nose() -> Vector3:
	var sv: Vector3 = sim.surface_vel
	if sv.length() < 1.0:
		return sim.forward()
	var vd := sv.normalized()
	# Slightly nose-up from the velocity so the belly takes the heat.
	var up: Vector3 = sim.up_dir.slide(vd)
	if up.length() < 0.05:
		up = sim.up_dir
	return (vd * 0.75 + up.normalized() * 0.25).normalized()


func _entry_basis() -> Basis:
	var sv: Vector3 = sim.surface_vel
	var vd: Vector3 = sv.normalized() if sv.length() > 1.0 else -sim.up_dir
	var up: Vector3 = sim.up_dir
	# Belly (−Y) into the wind, nose along the horizon / slightly up.
	var belly: Vector3 = vd
	var nose: Vector3 = _entry_nose()
	var y: Vector3 = -belly
	var z: Vector3 = -nose
	var x: Vector3 = y.cross(z)
	if x.length() < 0.05:
		return sim.basis
	x = x.normalized()
	z = x.cross(y).normalized()
	return Basis(x, y.normalized(), z).orthonormalized()


func _entry_flaps(h: float) -> void:
	# Independent flap motion during the belly-flop, like the real ship.
	var t: float = profile_t
	var fwd: Vector2 = Vector2(0.35 + 0.2 * sin(t * 0.7), 0.35 + 0.2 * sin(t * 0.7 + 0.8))
	var aft: Vector2 = Vector2(0.55 + 0.25 * sin(t * 0.5 + 0.2), 0.55 + 0.25 * sin(t * 0.5 + 1.3))
	sim.flap_fwd = sim.flap_fwd.lerp(fwd, clampf(h * 2.0, 0.0, 1.0))
	sim.flap_aft = sim.flap_aft.lerp(aft, clampf(h * 2.0, 0.0, 1.0))
	if sim.flap_fwd.length() + sim.flap_aft.length() > 0.4:
		flaps_moved = true


func _follow_entry_path(u: float, h: float) -> void:
	# Modeled return: Pacific / Baja / north of South Padre / Gulf swoosh / south to OLP-2.
	# Time-compressed vs the real ~22 minutes from entry to catch. Final approach over water.
	var pts := [
		Vector3(24.4, -112.5, 90000.0),
		Vector3(25.2, -107.0, 65000.0),
		Vector3(26.0, -102.5, 40000.0),
		Vector3(26.35, -97.35, 18000.0),  # north of South Padre
		Vector3(26.20, -96.75, 8000.0),   # swoosh over the Gulf
		Vector3(26.08, -96.95, 2500.0),
		Vector3(STARBASE.x + 0.04, STARBASE.y + 0.06, 800.0),
	]
	var f: float = u * float(pts.size() - 1)
	var i: int = clampi(int(f), 0, pts.size() - 2)
	var w: float = f - float(i)
	var a: Vector3 = pts[i]
	var b: Vector3 = pts[i + 1]
	var g: Vector3 = a.lerp(b, w)
	var dir: Vector3 = Geo.game_dir(g.x, g.y).normalized()
	var r: float = earth().radius + g.z
	var want := earth().pos.copy()
	want.add(dir * r)
	var delta := want.rel(sim.pos)
	sim.pos.add(delta * clampf(h * (8.0 if game.test_mode else 0.8), 0.0, 1.0))
	# Velocity along the track, mostly horizontal.
	var nxt: Vector3 = Geo.game_dir(b.x, b.y).normalized() * (earth().radius + b.z)
	var cur: Vector3 = dir * r
	var track: Vector3 = (nxt - cur)
	if track.length() > 1.0:
		var spd: float = lerpf(6500.0, 120.0, u)
		sim.vel = earth().vel + track.normalized() * spd


func _place_pre_insertion() -> void:
	_place_orbit_at(ORBIT_ALT - 40000.0, true)


func _place_orbit() -> void:
	_place_orbit_at(ORBIT_ALT, false)
	sim.engine_on = false
	sim.throttle_cmd = 0.0


func _place_pre_entry() -> void:
	# Just before the deorbit burn, still in the 30.5° orbit, approaching the Pacific track.
	_place_orbit_at(ORBIT_ALT, false)
	Voice.say("Final Hawaii return check is go. Preparing to deorbit.", 1)


func _place_orbit_at(alt: float, sub: bool) -> void:
	var inc: float = deg_to_rad(INC_DEG)
	# LAN so the ground track leaves Starbase on ~107.5° azimuth and can return over the Gulf.
	var pad_ll: Vector2 = STARBASE
	var lan: float = deg_to_rad(pad_ll.y + 20.0)
	var arg: float = deg_to_rad(25.0)
	var r: float = earth().radius + alt
	var c_inc := cos(inc)
	var s_inc := sin(inc)
	var c_l := cos(lan)
	var s_l := sin(lan)
	# ECI-like game frame using Geo axes: x = (0 lon), etc. Use Geo.game_dir around the orbit.
	var theta: float = arg
	var lat: float = rad_to_deg(asin(clampf(s_inc * sin(theta), -1.0, 1.0)))
	var lon: float = rad_to_deg(atan2(s_l * cos(theta) + c_l * c_inc * sin(theta), c_l * cos(theta) - s_l * c_inc * sin(theta)))
	if sub:
		lat = pad_ll.x + 2.0
		lon = pad_ll.y + 8.0
	var dir: Vector3 = Geo.game_dir(lat, lon).normalized()
	sim.pos.set_xyz(earth().pos.x() + dir.x * r, earth().pos.y() + dir.y * r, earth().pos.z() + dir.z * r)
	var east: Vector3 = CelestialBody.east_at(dir)
	var north: Vector3 = dir.cross(east).normalized()
	# In-plane horizontal: along the 30.5° track (roughly east-north-east from this sample).
	var along: Vector3 = (east * cos(deg_to_rad(30.0)) + north * sin(deg_to_rad(30.0))).normalized()
	var n: float = sqrt(earth().gm / (r * r * r))
	sim.vel = earth().vel + along * (n * r)
	sim.basis = ship_basis(along, dir)
	sim.clamped = false


func _orient(target: Basis, h: float, rate: float) -> void:
	var q0: Quaternion = sim.basis.get_rotation_quaternion()
	var q1: Quaternion = target.get_rotation_quaternion()
	sim.basis = Basis(q0.slerp(q1, clampf(h * rate, 0.0, 1.0))).orthonormalized()
	sim.ang_vel = Vector3.ZERO


func _set_phase(p: String) -> void:
	phase = p
	guidance["phase"] = p
	_auto_t0 = profile_t


var _auto_t0 := 0.0


func _phase_hold() -> float:
	return profile_t - _auto_t0


func _log(name: String) -> void:
	events.append({"name": name, "t": profile_t, "mission_time": game.mission_time})


func _has(name: String) -> bool:
	for e in events:
		if str(e.get("name", "")) == name:
			return true
	return false


func _update_card() -> void:
	var lines := {
		"ascent": ["FLIGHT 15", "Climbing out of Starbase."],
		"second_stage": ["HOT STAGING", "Ship is flying. Booster is boosting back."],
		"insert_coast": ["COAST", "Next: orbital insertion burn."],
		"insert": ["INSERTION", "One more burn to circularise."],
		"deploy": ["PEZ DOOR", "Deploying Starlink %d of %d." % [deployed, SAT_COUNT]],
		"coast": ["ORBIT", "Long coast. The ship is coming home."],
		"deorbit": ["DEORBIT", "One Raptor, ten seconds."],
		"entry": ["ENTRY", "Belly flop. Watch the flaps and the plasma."],
		"swoosh": ["SWOOSH", "Out over the Gulf, then home to the tower."],
		"flip": ["FLIP", "Landing burn. Three Raptors, then two, then one."],
		"landing": ["LANDING", "Lining up on Mechazilla."],
		"catching": ["CATCH", "Chopsticks closing."],
		"caught": ["CATCH CONFIRMED", "Starship is home."],
	}
	var pair: Array = lines.get(phase, ["FLIGHT 15", "Watch the show."])
	set_card(str(pair[0]), str(pair[1]), [])


func final_score() -> void:
	super.final_score()
	game.add_score("26 Starlink V3 deployed", 200 if deployed >= SAT_COUNT else deployed * 5)
	if caught:
		game.add_score("First tower catch", 300)
