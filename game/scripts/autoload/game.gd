extends Node
## Central game state: universe, ship sim, ship systems (power, life support, failures),
## launch checklist, flight-assist / nav vector, robotic arm, scanner, jump drive,
## mission flow, scoring, master caution, and feeding the LEDs and audio.

signal mission_loaded
signal mission_finished(success: bool)
signal objective_changed
signal game_event(kind: String, data: Dictionary)

enum State { BRIEFING, ACTIVE, PAUSED, COMPLETE, FAILED }
const STATE_NAMES := ["BRIEFING", "ACTIVE", "PAUSED", "COMPLETE", "FAILED"]

const MISSION_ORDER := ["launch", "docking", "lunar", "asteroids", "reentry", "sandbox",
	"iss", "night_pass", "emergency", "splashdown", "rescue", "flag", "captains_log", "signal", "ground_crew", "bedtime"]
const MISSION_TITLES := {"launch": "FIRST LIGHT", "docking": "SPACE HUG", "lunar": "EAGLE EYE",
	"asteroids": "ROCK HOPPERS", "reentry": "HOMECOMING", "sandbox": "FREE FLIGHT",
	"iss": "REAL ISS", "night_pass": "CITY LIGHTS", "emergency": "HOUSTON, A PROBLEM", "splashdown": "SPLASHDOWN",
	"rescue": "CATCH THE SPACEWALKER", "flag": "PLANT THE FLAG", "captains_log": "CAPTAIN'S LOG",
	"signal": "ALIEN SIGNAL", "ground_crew": "GROUND CREW", "bedtime": "BEDTIME CRUISE"}
const DIFFICULTIES := ["easy", "normal", "hard"]
const MISSION_SCRIPTS := {
	"launch": "res://scripts/missions/m_launch.gd",
	"docking": "res://scripts/missions/m_docking.gd",
	"lunar": "res://scripts/missions/m_lunar.gd",
	"asteroids": "res://scripts/missions/m_asteroids.gd",
	"reentry": "res://scripts/missions/m_reentry.gd",
	"sandbox": "res://scripts/missions/m_sandbox.gd",
	"iss": "res://scripts/missions/m_iss.gd",
	"night_pass": "res://scripts/missions/m_night_pass.gd",
	"emergency": "res://scripts/missions/m_emergency.gd",
	"splashdown": "res://scripts/missions/m_splashdown.gd",
	"rescue": "res://scripts/missions/m_rescue.gd",
	"flag": "res://scripts/missions/m_flag.gd",
	"captains_log": "res://scripts/missions/m_captains_log.gd",
	"signal": "res://scripts/missions/m_signal.gd",
	"ground_crew": "res://scripts/missions/m_ground_crew.gd",
	"bedtime": "res://scripts/missions/m_bedtime.gd",
}

# ---- universe (real size: 6371 km Earth, real Moon at 384,400 km; see docs/game/REAL_EARTH.md)
const G0 := 9.80665
const EARTH_R := 6371000.0
const EARTH_GM := 3.986004418e14
const MOON_R := 1737400.0
const MOON_GM := 4.9048695e12
const MOON_ORBIT := 384400000.0
const STATION_ALT := 410000.0
const FIELD_ALT := 2000000.0
const RUNWAY_GEO := Vector2(28.615, -80.695)   # KSC Shuttle Landing Facility (lat, lon)
const SITE_ELEV := 3.0                         # pad / runway ground, m above sea level
const PHYS_DT := 1.0 / 120.0

var earth := CelestialBody.new()
var moon := CelestialBody.new()
var bodies: Array = []
var sim := ShipSim.new()
var t := 0.0
var mission_time := 0.0
var state := State.BRIEFING
var mission: Mission = null
var mission_id := "launch"
var warp := 1.0
var sun_dir := Vector3(0.6, 0.35, -0.7).normalized()   # direction TOWARD the sun

# fixed sites
var pad_dir := Vector3(1, 0, 0)
var runway_dir := Vector3(1, 0, 0)    # set in _build_universe (real KSC SLF via Geo)
var lunar_site_dir := Vector3(-1, 0, 0)

# entities (station, booster, satellite, pod, crystals, ...)
var entities: Array = []
var _eid := 0
var station: Dictionary = {}
var field: Dictionary = {}

# ---- systems
const CHECKLIST := ["ovh_battery", "ovh_fuel_pumps", "ovh_avionics", "ovh_apu", "ovh_guidance", "ovh_ign_arm"]
const CHECKLIST_NAMES := ["BATTERY", "FUEL PUMPS", "AVIONICS", "APU START", "GUIDANCE", "IGNITION ARM"]
var seq_ok := [false, false, false, false, false, false]
var checklist_progress := 0
var checklist_error := -1
var harness_confirmed := false

## Crew position (cradle recline + kids' pod), from read-only contacts. Display + callouts only.
var pod := PodMonitor.new()

var master_power := true
var reactor_out := 0.0
var power_avail := 0.0
var power_draw := 0.0
var power_ok := true
var powered := {}              # system -> bool
var o2 := 100.0
var cabin_kpa := 101.0
var hull := 100.0
var failures := {"fire": false, "leak": false, "power": false, "sensor": false}
var failure_time := {}
var failures_fixed := 0
var leak_sealed := false
var _reactor_was_off_for := 0.0
var warnings := {}             # id -> text
var caution_active := false
var caution_silenced := false
var damage_taken := 0.0

# ---- crew controls state
var ops_mode := 0              # 0 RCS, 1 ARM, 2 SCANNER
const OPS_MODES := ["RCS", "ARM", "SCANNER"]
var nav_targets: Array = []    # [{name, entity or body}]
var nav_index := -1
const NAV_VECTORS := ["PROGRADE", "RETROGRADE", "TARGET", "TGT RETRO", "RADIAL OUT", "GUIDANCE"]
var nav_vector := "PROGRADE"
var nav_dir := Vector3.ZERO
var scanner_age := 999.0
var cargo_door := 0.0
var arm_extend := 0.0
var arm_yaw := 0.0
var arm_pitch := 0.6
var arm_len := 6.0
var beam_on := false
var beam_target: Dictionary = {}
var jump_charge := 0.0
var jump_phase := 0.0          # >0 while in hyperspace
var laser_on := false
var laser_target: Dictionary = {}
var view_mode := 0             # 0 cockpit, 1 chase
var camera_shake := 0.0
var cabin_dim := 0.0           # 0 normal .. 1 night-light cabin (bedtime): dims the console + exposure
var force_eva := ""            # MISSIONS page EVA entry: weave this spacewalk into its host mission
var last_result := {}          # {id, title, score, stars, ok}: the Captain's Log saves it with the voice log
var stage_flash := 0.0
var slew := DebugSlew.new()   # debug slew / free camera while PAUSED (Commander > MISSION CONTROL, Ctrl+F)
var commander_log: Array[String] = []   # Commander actions (refuel, slew, ...): [mm:ss] text

# ---- scoring & messages
var score_items: Array = []
var score_total := 0
var stars := 0
var result_text := ""
var objective_text := ""
var pilot_hint := ""
var ops_hint := ""
var test_mode := false


func _ready() -> void:
	# window close / Alt+F4 on ANY window goes through quit_game() (helpers stopped first)
	get_tree().set_auto_accept_quit(false)
	test_mode = Settings.is_test_run()
	if Settings.is_eva_client():
		external_clock = true   # the VR client mirrors the cockpit's world snapshots instead
	_build_universe()
	var start: String = str(Settings.cli.get("mission", Settings.get_v("game", "start_mission")))
	if not MISSION_SCRIPTS.has(start):
		start = "launch"
	load_mission(start)


func _build_universe() -> void:
	earth.id = "earth"
	earth.display_name = "EARTH"
	earth.radius = EARTH_R
	earth.gm = EARTH_GM
	earth.has_atmo = true
	earth.rho0 = 1.225
	earth.scale_h = 7000.0
	earth.atmo_top = 100000.0
	earth.terrain_amp = 70.0
	earth.terrain = EarthTerrain.new(earth)
	earth.color = Color(0.3, 0.5, 1.0)
	moon.id = "moon"
	moon.display_name = "MOON"
	moon.radius = MOON_R
	moon.gm = MOON_GM
	moon.parent = earth
	moon.orbit_r = MOON_ORBIT
	moon.orbit_phase = deg_to_rad(-25.0)
	moon.soi = MOON_ORBIT * pow(moon.gm / earth.gm, 0.4)
	moon.terrain_amp = 45.0
	moon.relief_amp = 900.0      # broad real-scale highlands / basins under the crater detail
	moon.cratered = true
	moon.color = Color(0.7, 0.7, 0.68)
	runway_dir = Geo.game_dir(RUNWAY_GEO.x, RUNWAY_GEO.y).normalized()
	earth.add_site(pad_dir, 1500.0, SITE_ELEV)
	earth.add_site(runway_dir, 4500.0, SITE_ELEV)
	moon.add_site(lunar_site_dir, 600.0)
	bodies = [earth, moon]
	sim.bodies = bodies


# ======================================================================== quitting
var _quitting := false


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		quit_game()


## Alt+F4 as a key event: borderless / fullscreen windows often never get the WM close request.
static func is_quit_key(ev: InputEvent) -> bool:
	var k := ev as InputEventKey
	return k != null and k.pressed and not k.echo and k.alt_pressed and (k.keycode == KEY_F4 or k.physical_keycode == KEY_F4)


func _input(ev: InputEvent) -> void:
	if is_quit_key(ev):
		get_viewport().set_input_as_handled()
		quit_game()


## Every extra OS window (side views, console, commander, popups) quits the game on close / Alt+F4.
func hook_window(w: Window) -> void:
	w.close_requested.connect(quit_game)
	w.window_input.connect(func(ev: InputEvent) -> void:
		if is_quit_key(ev):
			quit_game())


## Clean exit: ground-crew web server, VR client + the WiVRn server we started, intercom helper,
## LEDs off, then quit. Safe to call twice.
func quit_game(code: int = 0) -> void:
	if _quitting:
		return
	_quitting = true
	if Settings.is_eva_client():
		# the VR client ends its OpenXR session first (see EvaClient.quit_clean)
		var ec := get_tree().get_first_node_in_group("eva_client")
		if ec:
			ec.call("quit_clean", code)
			return
	print("Quitting: stopping helpers")
	var gl := GroundLink.get_link(false)
	if gl:
		gl.shutdown()
	if Eva.role == "server":
		Eva.stop_client()
	Ics.stop()
	if LedLink:
		LedLink.clear_all()
	# no LOD / texture worker may still be running while the tree and the engine tear down
	for wv: Node in get_tree().get_nodes_in_group("world"):
		if wv.has_method("shutdown_workers"):
			wv.call("shutdown_workers")
	get_tree().quit(code)


# ======================================================================== missions
func load_mission(id: String) -> void:
	if not MISSION_SCRIPTS.has(id):
		return
	mission_id = id
	force_eva = ""
	t = 0.0
	mission_time = 0.0
	warp = 1.0
	state = State.BRIEFING
	entities.clear()
	_reset_ship()
	_reset_systems()
	for b in bodies:
		var body: CelestialBody = b
		body.update(t)
	_spawn_universe_entities()
	var scr: GDScript = load(MISSION_SCRIPTS[id])
	mission = scr.new()
	mission.game = self
	mission.setup()
	_apply_difficulty()
	sim.pick_dominant()
	_update_entities(0.0)
	nav_index = clampi(nav_index, -1, nav_targets.size() - 1)
	_update_objective_text()
	mission_loaded.emit()
	objective_changed.emit()
	if LedLink:
		LedLink.clear_all()
	if not test_mode and bool(Settings.get_v("game", "skip_checklist")):
		auto_checklist()


## Commander setting (Settings game/difficulty). Tests always fly "normal".
func difficulty() -> String:
	if test_mode:
		return "normal"
	var d := str(Settings.get_v("game", "difficulty"))
	return d if d in DIFFICULTIES else "normal"


## easy: +30% fuel and RCS, half damage. hard: -15% fuel, 1.5x damage.
func _apply_difficulty() -> void:
	match difficulty():
		"easy":
			sim.fuel = minf(sim.fuel * 1.3, sim.fuel_max)
			sim.mono_max = maxf(sim.mono_max, sim.mono) * 1.3
			sim.mono *= 1.3
		"hard":
			sim.fuel *= 0.85


func restart_mission() -> void:
	load_mission(mission_id)
	Voice.say("Mission reset. " + mission.title)


## Commander override: mark the current objective done (the crew is stuck, or for demos).
func skip_step() -> void:
	if state == State.ACTIVE and mission:
		mission.cheat_advance()


func _reset_ship() -> void:
	sim = ShipSim.new()
	sim.bodies = bodies
	sim.vel = Vector3.ZERO
	sim.basis = Basis.IDENTITY
	sim.fuel = 6000.0
	sim.mono = sim.mono_max
	sim.fa_mode = ShipSim.FA.STAB


func _reset_systems() -> void:
	o2 = 100.0
	cabin_kpa = 101.0
	hull = 100.0
	for k in failures:
		failures[k] = false
	failure_time.clear()
	failures_fixed = 0
	leak_sealed = false
	warnings.clear()
	caution_active = false
	caution_silenced = false
	damage_taken = 0.0
	scanner_age = 999.0
	cargo_door = 0.0
	arm_extend = 0.0
	beam_on = false
	jump_charge = 0.0
	jump_phase = 0.0
	nav_targets.clear()
	nav_index = -1
	nav_vector = "PROGRADE"
	cabin_dim = 0.0
	score_items.clear()
	score_total = 0
	stars = 0
	result_text = ""
	view_mode = 0
	harness_confirmed = false
	pilot_hint = ""
	ops_hint = ""


func _spawn_universe_entities() -> void:
	_eid = 0
	station = add_entity("station", {"mode": "rails", "orbit_r": EARTH_R + STATION_ALT, "phase0": deg_to_rad(20.0), "radius": 30.0, "name": "STATION"})
	# Station flies "LVLH" like the ISS (fixed attitude relative to the local vertical): its docking
	# port (+Z) faces straight up, its truss (+Y) lies along the velocity.
	station["basis"] = Basis.looking_at(Vector3(0, 0, 1), Vector3.UP)
	station["lvlh"] = true
	field = add_entity("field", {"mode": "rails", "orbit_r": EARTH_R + FIELD_ALT, "phase0": deg_to_rad(140.0), "radius": 3000.0, "name": "ASTEROID FIELD"})
	_gen_field_rocks()
	add_entity("pad", {"mode": "surface", "body": earth, "dir": pad_dir, "radius": 40.0, "name": "LAUNCH PAD"})
	add_entity("runway", {"mode": "surface", "body": earth, "dir": runway_dir, "radius": 2000.0, "name": "RUNWAY"})
	add_entity("lunar_pad", {"mode": "surface", "body": moon, "dir": lunar_site_dir, "radius": 30.0, "name": "LANDING SITE", "revealed": false})


func _gen_field_rocks() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var pos := PackedVector3Array()
	var rad := PackedFloat32Array()
	for i in 1500:
		pos.append(Vector3(rng.randfn(0.0, 1000.0), rng.randfn(0.0, 240.0), rng.randfn(0.0, 1000.0)))
		rad.append(3.0 + pow(rng.randf(), 4.0) * 65.0)
	field["rock_pos"] = pos
	field["rock_r"] = rad


## Robotic arm tip, relative to the ship centre (world orientation).
func arm_dir_body() -> Vector3:
	return Vector3(-sin(arm_yaw) * cos(arm_pitch), sin(arm_pitch), -cos(arm_yaw) * cos(arm_pitch))


func arm_base_body() -> Vector3:
	return Vector3(0, 1.75, 1.0)


func arm_tip_rel() -> Vector3:
	return sim.basis * (arm_base_body() + arm_dir_body() * arm_len * arm_extend)


func arm_dir_world() -> Vector3:
	return sim.basis * arm_dir_body()


func add_entity(kind: String, data: Dictionary = {}) -> Dictionary:
	var e := {"id": "%s_%d" % [kind, _eid], "kind": kind, "pos": BigVec.new(), "vel": Vector3.ZERO,
		"basis": Basis.IDENTITY, "ang_vel": Vector3.ZERO, "mode": "free", "radius": 5.0,
		"visible": true, "revealed": true, "name": kind.to_upper(), "offset": Vector3.ZERO, "drift": Vector3.ZERO}
	e.merge(data, true)
	_eid += 1
	entities.append(e)
	_place_entity(e)
	return e


func remove_entity(e: Dictionary) -> void:
	entities.erase(e)
	game_event.emit("entity_removed", e)


func entities_of(kind: String) -> Array:
	var out := []
	for e in entities:
		if e["kind"] == kind:
			out.append(e)
	return out


func _place_entity(e: Dictionary) -> void:
	match e["mode"]:
		"rails":
			var r: float = e["orbit_r"]
			var n := sqrt(earth.gm / pow(r, 3.0))
			var th: float = e["phase0"] + n * t
			var pl: Basis = e.get("plane", Basis.IDENTITY)    # orbit plane (equatorial unless a mission tilts it)
			var pp := pl * Vector3(r * cos(th), 0.0, -r * sin(th))
			e["pos"].set_xyz(pp.x, pp.y, pp.z)
			e["vel"] = pl * Vector3(-sin(th), 0.0, -cos(th)) * (n * r)
			if e.get("lvlh", false):
				var zz := Vector3(-sin(th), 0.0, -cos(th))
				var yy := Vector3(cos(th), 0.0, -sin(th))
				# port (+Z) faces the zenith: the Falcon docks from above (R-bar), Earth behind the station
				e["basis"] = pl * Basis(zz.cross(yy), zz, yy)
		"surface":
			var body: CelestialBody = e["body"]
			var d: Vector3 = e["dir"]
			var h: float = body.terrain_height(d) + float(e.get("height", 0.0))
			var rr := body.radius + h
			e["pos"].set_xyz(body.pos.x() + d.x * rr, body.pos.y() + d.y * rr, body.pos.z() + d.z * rr)
			e["vel"] = body.vel
			if not e.has("basis_set"):
				var east := CelestialBody.east_at(d)
				e["basis"] = Basis(east, d, east.cross(d)).orthonormalized()
				e["basis_set"] = true
		"field":
			var parent: Dictionary = e["parent"]
			var p: BigVec = parent["pos"].copy()
			p.add(e["offset"])
			e["pos"] = p
			e["vel"] = parent["vel"] + e["drift"]
		"towed":
			var p3: BigVec = sim.pos.copy()
			p3.add(e["tow_rel"])
			e["pos"] = p3
			e["vel"] = sim.vel
		"attached":
			var p2: BigVec = sim.pos.copy()
			p2.add(sim.basis * e["offset"])
			e["pos"] = p2
			e["vel"] = sim.vel
			e["basis"] = sim.basis * e.get("local_basis", Basis.IDENTITY)


## Start autonomous F9 / Starship-style return after staging (boostback → coast → burns → Mechazilla catch).
func begin_booster_recovery(e: Dictionary) -> void:
	e["mode"] = "free"
	e["recovery"] = "boostback"
	e["thrust_frac"] = 0.0
	e["ang_vel"] = Vector3.ZERO
	e["legs_deployed"] = false
	e["fins_deployed"] = true
	e["catch_t"] = 0.0
	e["recovery_t"] = 0.0
	Voice.say("Booster boostback.", 1)


func _booster_catch_offset(pad: Dictionary) -> Vector3:
	# Pad local: tower at +X ≈ 10–14 m, chopsticks ~58 m up.
	var b: Basis = pad.get("basis", Basis.IDENTITY)
	return b * Vector3(8.0, 58.0, 0.0)


func _booster_orient(e: Dictionary, want_z: Vector3, h: float) -> void:
	if want_z.length_squared() < 1e-8:
		return
	var z := want_z.normalized()
	# Pick a reference that is not parallel to z (pad_dir is radial; often == ±up).
	var ref := Vector3.UP
	if absf(z.dot(ref)) > 0.95:
		ref = Vector3.RIGHT
	if absf(z.dot(ref)) > 0.95:
		ref = Vector3.FORWARD
	var x := ref.cross(z)
	if x.length_squared() < 1e-8:
		return
	x = x.normalized()
	var y := z.cross(x).normalized()
	var target := Basis(x, y, z).orthonormalized()
	var cur: Basis = (e.get("basis", Basis.IDENTITY) as Basis).orthonormalized()
	var q0: Quaternion = cur.get_rotation_quaternion()
	var q1: Quaternion = target.get_rotation_quaternion()
	e["basis"] = Basis(q0.slerp(q1, clampf(h * 1.8, 0.0, 1.0))).orthonormalized()


func _booster_burn(e: Dictionary, desire: Vector3, h: float, max_a: float) -> void:
	var a := desire.limit_length(max_a)
	e["vel"] += a * h
	e["thrust_frac"] = clampf(a.length() / maxf(max_a, 1.0), 0.0, 1.0)
	if a.length() > 0.8:
		# Engines fire along +body Z → thrust accel is −body Z.
		_booster_orient(e, -a.normalized(), h)


func _update_booster_recovery(e: Dictionary, h: float) -> void:
	var phase := str(e.get("recovery", ""))
	if phase == "" or phase == "caught":
		e["thrust_frac"] = 0.0
		return
	e["recovery_t"] = float(e.get("recovery_t", 0.0)) + h
	var pads := entities_of("pad")
	if pads.is_empty():
		e["thrust_frac"] = 0.0
		return
	var pad: Dictionary = pads[0]
	var catch_pos: BigVec = pad["pos"].copy()
	catch_pos.add(_booster_catch_offset(pad))
	var to_catch: Vector3 = catch_pos.rel(e["pos"])  # catch − booster
	var dist := to_catch.length()
	var up: Vector3 = (pad.get("basis", Basis.IDENTITY) as Basis).y
	var vel_rel: Vector3 = e["vel"] - pad.get("vel", Vector3.ZERO)
	var earth_rel: Vector3 = e["pos"].rel(earth.pos)
	var alt := earth_rel.length() - earth.radius
	match phase:
		"boostback":
			e["fins_deployed"] = true
			var horiz := to_catch - up * to_catch.dot(up)
			var hdir := horiz.normalized() if horiz.length() > 10.0 else -vel_rel.slide(up).normalized()
			var desire := hdir * 280.0 - vel_rel.slide(up) * 0.9 - up * clampf(vel_rel.dot(up), -80.0, 40.0) * 0.3
			_booster_burn(e, desire, h, 28.0)
			if e["recovery_t"] > 18.0 or (horiz.length() < 25000.0 and vel_rel.slide(up).dot(hdir) > -40.0):
				e["recovery"] = "coast"
				e["recovery_t"] = 0.0
				e["thrust_frac"] = 0.0
				Voice.say("Booster coasting.", 1)
		"coast":
			e["thrust_frac"] = 0.0
			_booster_orient(e, -up, h * 0.5)
			if alt < 90000.0 or dist < 140000.0 or e["recovery_t"] > 90.0:
				e["recovery"] = "entry"
				e["recovery_t"] = 0.0
				Voice.say("Entry burn.", 1)
		"entry":
			var desire2 := -vel_rel * 1.1 + to_catch.normalized() * 40.0
			_booster_burn(e, desire2, h, 22.0)
			if alt < 14000.0 or dist < 30000.0 or e["recovery_t"] > 55.0:
				e["recovery"] = "landing"
				e["recovery_t"] = 0.0
				e["legs_deployed"] = true
				Voice.say("Landing burn.", 1)
		"landing":
			var desire3 := to_catch * 0.22 - vel_rel * 1.35
			# Soften vertical slam into chopsticks.
			desire3 += up * clampf(8.0 - vel_rel.dot(up), -25.0, 35.0)
			_booster_burn(e, desire3, h, 38.0)
			_booster_orient(e, -up, h)
			if dist < 55.0 and vel_rel.length() < 28.0:
				e["recovery"] = "catching"
				e["recovery_t"] = 0.0
				e["thrust_frac"] = 0.15
				Voice.say("Chopsticks ready.", 1)
			elif e["recovery_t"] > 70.0:
				# Fail-safe: pad landing.
				e["mode"] = "landed"
				e["recovery"] = "caught"
				e["thrust_frac"] = 0.0
				e["vel"] = pad.get("vel", Vector3.ZERO)
				var soft: BigVec = pad["pos"].copy()
				soft.add((pad.get("basis", Basis.IDENTITY) as Basis) * Vector3(0, 12.0, 0))
				e["pos"] = soft
				_booster_orient(e, -up, 1.0)
				Voice.say("Booster landed.", 1)
				game_event.emit("booster_caught", e)
		"catching":
			var blend := clampf(e["recovery_t"] / 2.2, 0.0, 1.0)
			var cur: Vector3 = e["pos"].rel(catch_pos)
			e["pos"].add(-cur * clampf(h * 2.5, 0.0, 1.0))
			e["vel"] = e["vel"].lerp(pad.get("vel", Vector3.ZERO), clampf(h * 3.0, 0.0, 1.0))
			e["thrust_frac"] = lerpf(0.15, 0.0, blend)
			_booster_orient(e, -up, h)
			if blend >= 1.0 or cur.length() < 6.0:
				e["mode"] = "landed"
				e["recovery"] = "caught"
				e["thrust_frac"] = 0.0
				e["vel"] = pad.get("vel", Vector3.ZERO)
				e["pos"] = catch_pos.copy()
				_booster_orient(e, -up, 1.0)
				Voice.say("Catch confirmed!", 1)
				add_score("Booster caught", 100)
				game_event.emit("booster_caught", e)
		_:
			e["thrust_frac"] = 0.0


func _update_entities(h: float) -> void:
	for e in entities:
		var mode: String = e["mode"]
		if mode == "free":
			var g := Vector3.ZERO
			for b in bodies:
				var body: CelestialBody = b
				var r: Vector3 = body.pos.rel(e["pos"])
				var d2 := r.length_squared()
				g += r * (body.gm / (d2 * sqrt(d2)))
			e["vel"] += g * h
			if str(e.get("kind", "")) == "booster" and str(e.get("recovery", "")) != "":
				_update_booster_recovery(e, h)
			e["pos"].add(e["vel"] * h)
			var av: Vector3 = e["ang_vel"]
			if av.length_squared() > 1e-10:
				e["basis"] = (Basis(av.normalized(), av.length() * h) * e["basis"]).orthonormalized()
			# Land on surfaces only if not in active recovery (recovery handles catch).
			if str(e.get("recovery", "")) in ["", "caught"]:
				var rel: Vector3 = e["pos"].rel(sim.dominant.pos) if sim.dominant else Vector3.ONE * 1e9
				if sim.dominant and rel.length() < sim.dominant.radius + sim.dominant.terrain_height(rel.normalized()):
					e["mode"] = "landed"
					e["vel"] = sim.dominant.vel
		elif mode == "field":
			e["offset"] += e["drift"] * h
			_place_entity(e)
		elif mode != "landed":
			_place_entity(e)


# ======================================================================== frame loop
var external_clock := false     # tests drive tick() themselves (faster than real time)


var crew_wave := [0.0, 0.0]   # Pilot, Ops: seconds of waving left (seen from outside / VR)


func wave(seat: int) -> void:
	crew_wave[seat] = 2.6


func _process(dt: float) -> void:
	if not Settings.is_eva_client():
		if InputHub.just_pressed("wave_pilot"):
			wave(0)
		if InputHub.just_pressed("wave_ops"):
			wave(1)
	for i in 2:
		crew_wave[i] = maxf(0.0, float(crew_wave[i]) - dt)
	if not external_clock:
		tick(dt)


func tick(dt: float) -> void:
	dt = minf(dt, 0.1)
	_handle_commander()
	slew.poll(self, dt)
	_update_pod(dt)
	_update_checklist()
	_update_systems(dt)
	if state == State.ACTIVE:
		_crew_inputs(dt)
		_step_physics(dt)
		mission_time += dt
		if mission and mission.eva_obj.is_empty():
			mission.update(dt)
		_check_damage()
	else:
		sim.in_rot = Vector3.ZERO
		sim.in_trans = Vector3.ZERO
		for b in bodies:
			var body: CelestialBody = b
			body.update(t)
		_update_entities(0.0)
		sim.refresh_frame()
	scanner_age += dt
	camera_shake = maxf(0.0, camera_shake - dt * 1.5)
	stage_flash = maxf(0.0, stage_flash - dt)
	_update_audio()
	_update_leds()
	if Eva.role == "server":
		Eva.tick(dt)    # the spacewalk runs on the game clock (tests drive it faster than real time)


func _step_physics(dt: float) -> void:
	# time warp only when it is safe and quiet
	if warp > 1.0:
		var reason := ""
		if sim.density_now > 0.0 and sim.agl < 1500.0:
			reason = "low in the atmosphere"
		elif sim.density_now > 0.0 and warp > 4.0:
			set_warp(4.0)
			Voice.say("Time warp limited to times four in the air")
		elif sim.thrust_now > 0.0 or sim.in_trans.length() > 0.05:
			reason = "engine or thrusters running"
		elif sim.touching:
			reason = "on the ground"
		if reason != "":
			set_warp(1.0)
			Voice.say("Time warp off: " + reason)
	var sim_dt := dt * warp
	var max_h := PHYS_DT if warp <= 1.0 else (0.05 if warp <= 10.0 else 0.25)
	if warp > 100.0 and sim.dominant:   # real-size orbits: ~2000 steps per local orbital period
		var r := maxf(sim.altitude + sim.dominant.radius, sim.dominant.radius)
		max_h = clampf(TAU * sqrt(r * r * r / sim.dominant.gm) / 2000.0, 0.25, 5.0)
	var n := clampi(ceili(sim_dt / max_h), 1, 400)
	var h := sim_dt / n
	for i in n:
		t += h
		for b in bodies:
			var body: CelestialBody = b
			body.update(t)
		sim.pick_dominant()
		sim.step(h)
		_update_entities(h)
		if mission:
			mission.physics(h)   # contacts / chutes / rocks stay physical during a woven spacewalk too


func set_warp(w: float) -> void:
	warp = clampf(w, 1.0, 1.0 if Eva.active else 10000.0)
	game_event.emit("warp", {"warp": warp})


# ======================================================================== commander
func _handle_commander() -> void:
	if InputHub.just_pressed("mission_next"):
		select_mission(1)
	if InputHub.just_pressed("mission_prev"):
		select_mission(-1)
	if InputHub.just_pressed("start"):
		match state:
			State.BRIEFING:
				try_start()
			State.PAUSED:
				start_pause()
			State.COMPLETE, State.FAILED:
				load_mission(mission_id)
	if InputHub.just_pressed("pause") and (state == State.ACTIVE or state == State.PAUSED):
		start_pause()
	if InputHub.just_pressed("mission_select"):
		Voice.say("Mission: " + mission.title + ". " + mission.tagline)
	if InputHub.just_pressed("caution_reset"):
		reset_caution()
	if state == State.ACTIVE:
		if InputHub.just_pressed("fail_fire"):
			inject_failure("fire")
		if InputHub.just_pressed("fail_leak"):
			inject_failure("leak")
		if InputHub.just_pressed("fail_power"):
			inject_failure("power")
		if InputHub.just_pressed("fail_sensor"):
			inject_failure("sensor")
	if InputHub.just_pressed("ptt_commander") or InputHub.just_pressed("all_call"):
		if not Ics.ok():       # no intercom: a room "attention" chirp instead (the helper beeps itself)
			Sfx.tone(1200.0, 0.06, 0.2)
			Sfx.tone(1600.0, 0.06, 0.2, "sine", -1.0, 0.08)
		game_event.emit("intercom", {"all_call": InputHub.just_pressed("all_call")})
	if InputHub.just_pressed("eject"):
		Voice.say("Ejection seats are disabled. Nice try, Commander!", 1)
		Sfx.tone(200.0, 0.4, 0.3, "saw", 90.0)
	if InputHub.just_pressed("horn"):
		Sfx.tone(233.0, 0.5, 0.35, "square")
		Sfx.tone(294.0, 0.5, 0.25, "square")


func select_mission(delta: int) -> void:
	if state == State.ACTIVE:
		Voice.say("Pause the mission before changing it.")
		return
	var i := MISSION_ORDER.find(mission_id)
	i = posmod(i + delta, MISSION_ORDER.size())
	load_mission(MISSION_ORDER[i])
	Sfx.beep()


func start_pause() -> void:
	match state:
		State.BRIEFING:
			try_start()
		State.ACTIVE:
			state = State.PAUSED
			Voice.say("Mission paused")
		State.PAUSED:
			slew.stop(self)          # the ship resumes from wherever it was slewed to
			state = State.ACTIVE
			Voice.say("Mission resumed")
		State.COMPLETE, State.FAILED:
			load_mission(mission_id)


func try_start() -> bool:
	if not master_power:
		Voice.say("Turn the master power key on first.", 1)
		return false
	if mission.requires_checklist and checklist_progress < CHECKLIST.size():
		Voice.say("Finish the overhead checklist first. Next: " + CHECKLIST_NAMES[checklist_progress], 1)
		return false
	state = State.ACTIVE
	mission.start()
	Voice.say(mission.start_callout, 1)
	Sfx.chime()
	objective_changed.emit()
	return true


func inject_failure(kind: String) -> void:
	if failures.get(kind, false) or (mission and mission.calm):
		return
	failures[kind] = true
	failure_time[kind] = mission_time
	match kind:
		"fire":
			Voice.say("Engine fire! Pilot: engine arm OFF. Ops: fire suppression!", 2)
		"leak":
			leak_sealed = false
			Voice.say("Cabin leak! Ops: seal the leak on the systems page.", 2)
		"power":
			_reactor_was_off_for = 0.0
			Voice.say("Power fault! Ops: reset the reactor, switch it off then on.", 2)
		"sensor":
			Voice.say("Sensor glitch! Ops: cycle the sensors off and on.", 2)
	game_event.emit("failure", {"kind": kind})


func fix_failure(kind: String) -> void:
	if not failures.get(kind, false):
		return
	failures[kind] = false
	failures_fixed += 1
	var took := mission_time - float(failure_time.get(kind, mission_time))
	add_score("Fixed %s in %ds" % [kind.to_upper(), int(took)], maxi(50, 300 - int(took * 5.0)))
	Voice.say({"fire": "Fire is out. Good work!", "leak": "Leak sealed.", "power": "Reactor reset. Power restored.", "sensor": "Sensors back online."}[kind], 1)
	Sfx.chime()


func _update_pod(dt: float) -> void:
	pod.travel_s = float(Settings.get_v("pod", "travel_s"))
	pod.up_sense_mode = str(Settings.get_v("pod", "up_sense"))
	var ev := pod.update(dt, InputHub.on("cradle_reclined"), InputHub.on("pod_down_locked"), InputHub.on("pod_up_locked"))
	for e in ev:
		game_event.emit("pod", {"event": e, "pod": pod.pod_text(), "seats": pod.seats_text()})
		if bool(Settings.get_v("pod", "callouts")) and e != "reclined":
			var t := PodMonitor.callout_text(e)
			if e == "pod_coming_down" and not pod.has_up_sense():
				t = "Seats reclined. " + t
			Voice.say(t, 2 if e == "pod_coming_down" else 1)


func reset_caution() -> void:
	caution_silenced = true
	caution_active = false
	Sfx.beep()


# ======================================================================== checklist
func _update_checklist() -> void:
	for i in CHECKLIST.size():
		var id: String = CHECKLIST[i]
		if InputHub.just_pressed(id):
			if i == 0 or seq_ok[i - 1]:
				seq_ok[i] = true
				Voice.say(CHECKLIST_NAMES[i] + " on.")
				Sfx.click()
			else:
				seq_ok[i] = false
				checklist_error = i
				var nxt: String = CHECKLIST_NAMES[checklist_progress] if checklist_progress < CHECKLIST.size() else "done"
				Voice.say("Out of sequence! %s off. Next step is %s." % [CHECKLIST_NAMES[i], nxt], 1)
		if InputHub.just_released(id):
			seq_ok[i] = false
			if checklist_error == i:
				checklist_error = -1
		if not InputHub.on(id):
			seq_ok[i] = false
	var p := 0
	for i in CHECKLIST.size():
		if seq_ok[i] and InputHub.on(CHECKLIST[i]):
			p += 1
		else:
			break
	if p == CHECKLIST.size() and checklist_progress < CHECKLIST.size():
		Voice.say("Checklist complete. Ready for launch.", 1)
		Sfx.chime()
		game_event.emit("checklist_complete", {})
	checklist_progress = p


## Test / touchscreen helper: flips the checklist switches on in order.
func auto_checklist() -> void:
	for id in CHECKLIST:
		InputHub.set_switch(id, true)
	for i in CHECKLIST.size():
		seq_ok[i] = true
	checklist_progress = CHECKLIST.size()


# ======================================================================== systems
func _update_systems(dt: float) -> void:
	master_power = InputHub.on("master_power")
	var bat := InputHub.on("ovh_battery") and master_power
	var reactor_sw := InputHub.on("pwr_reactor") and master_power
	var apu := InputHub.on("ovh_apu")
	var reactor_target := 100.0 if (reactor_sw and (apu or state == State.ACTIVE)) else 0.0
	if failures["power"]:
		reactor_target = minf(reactor_target, 40.0)
		if not reactor_sw:
			_reactor_was_off_for += dt
		elif _reactor_was_off_for > 1.0:
			fix_failure("power")
	reactor_out = move_toward(reactor_out, reactor_target, dt * 30.0)
	power_avail = (35.0 if bat else 0.0) + reactor_out
	if not master_power:
		power_avail = 0.0
	var loads := {
		"avionics": [InputHub.on("ovh_avionics"), 12.0],
		"guidance": [InputHub.on("ovh_guidance"), 6.0],
		"pumps": [InputHub.on("ovh_fuel_pumps"), 6.0],
		"life": [InputHub.on("pwr_life"), 15.0],
		"comms": [InputHub.on("pwr_comms"), 8.0],
		"sensors": [InputHub.on("pwr_sensors"), 12.0],
		"shields": [InputHub.on("pwr_shields"), 28.0],
		"arm": [ops_mode == 1 and cargo_door > 0.5, 10.0],
		"laser": [laser_on, 14.0],
		"jump": [InputHub.on("jump_arm") and jump_charge < 100.0, 35.0],
	}
	# Shed order when overloaded (lowest priority first)
	var priority := ["avionics", "guidance", "pumps", "life", "comms", "sensors", "arm", "laser", "shields", "jump"]
	power_draw = 0.0
	powered.clear()
	var budget := power_avail
	for sys in priority:
		var l: Array = loads[sys]
		if not l[0]:
			powered[sys] = false
			continue
		power_draw += l[1]
		powered[sys] = budget >= l[1]
		if powered[sys]:
			budget -= l[1]
	power_ok = power_draw <= power_avail + 0.01
	_set_warning("power", "POWER OVERLOAD - switch something off" if not power_ok else "")
	_set_warning("power_fault", "POWER FAULT - reset reactor (off, then on)" if failures["power"] else "")
	_set_warning("master", "MASTER POWER OFF" if not master_power else "")

	# Life support & cabin
	if failures["leak"] and not leak_sealed:
		cabin_kpa = maxf(30.0, cabin_kpa - dt * 0.9)
	elif powered.get("life", false):
		cabin_kpa = move_toward(cabin_kpa, 101.0, dt * 2.0)
	if powered.get("life", false):
		o2 = move_toward(o2, 100.0 if cabin_kpa > 70.0 else o2, dt * 1.5)
	elif state == State.ACTIVE:
		o2 = maxf(0.0, o2 - dt * 0.35)
	if failures["leak"] and leak_sealed and cabin_kpa > 95.0:
		fix_failure("leak")
	_set_warning("o2", "OXYGEN LOW - LIFE SUPPORT on" if o2 < 70.0 else "")
	_set_warning("cabin", "CABIN PRESSURE %d kPa" % int(cabin_kpa) if cabin_kpa < 90.0 else "")
	_set_warning("life_off", "LIFE SUPPORT OFF" if not powered.get("life", false) and state == State.ACTIVE else "")

	# Engine fire
	if failures["fire"]:
		sim.engine_enabled = false
		if InputHub.just_pressed("fire_suppress"):
			if not InputHub.on("engine_arm"):
				fix_failure("fire")
			else:
				Voice.say("Pilot: engine arm OFF first, then fire suppression!", 1)
		if state == State.ACTIVE:
			_damage(dt * 0.4, false)
	else:
		sim.engine_enabled = powered.get("pumps", false) and InputHub.on("ovh_ign_arm")
	_set_warning("fire", "ENGINE FIRE" if failures["fire"] else "")

	# Sensors glitch: fixed by cycling the sensor switch
	if failures["sensor"] and InputHub.just_released("pwr_sensors"):
		failure_time["sensor_cycle"] = true
	if failures["sensor"] and failure_time.get("sensor_cycle", false) and InputHub.just_pressed("pwr_sensors"):
		failure_time.erase("sensor_cycle")
		fix_failure("sensor")
	_set_warning("sensor", "SENSOR GLITCH - cycle SENSORS" if failures["sensor"] else "")
	_set_warning("hull", "HULL DAMAGE %d%%" % int(hull) if hull < 60.0 else "")
	_set_warning("heat", "HULL TEMP %d K" % int(sim.hull_temp) if sim.hull_temp > 1350.0 else "")
	_set_warning("fuel", "FUEL LOW" if sim.fuel < 600.0 and not sim.booster_attached and state == State.ACTIVE else "")

	# Shield/thermal flags into the sim
	sim.shield_on = powered.get("shields", false)
	sim.rw_enabled = powered.get("avionics", false) or not master_power
	sim.rcs_enabled = master_power

	# Cargo doors / arm animation
	var doors_open := InputHub.on("cargo_doors")
	cargo_door = move_toward(cargo_door, 1.0 if doors_open else 0.0, dt / 3.0)
	if not InputHub.has_hardware_for("mode_rcs"):
		pass
	ops_mode = InputHub.group("ops")
	var arm_target := 1.0 if (ops_mode == 1 and cargo_door > 0.95) else 0.0
	arm_extend = move_toward(arm_extend, arm_target, dt / 2.0)
	# Jump drive charge
	if InputHub.on("jump_arm") and powered.get("jump", false) and reactor_out > 50.0:
		if jump_charge < 100.0 and jump_charge + dt * 14.0 >= 100.0:
			Voice.say("Jump drive charged. Ready to engage.", 1)
		jump_charge = minf(100.0, jump_charge + dt * 14.0)
	elif not InputHub.on("jump_arm"):
		jump_charge = maxf(0.0, jump_charge - dt * 40.0)


func _set_warning(id: String, text: String) -> void:
	if text == "":
		warnings.erase(id)
		return
	if not warnings.has(id):
		warnings[id] = text
		if state == State.ACTIVE:
			caution_active = true
			caution_silenced = false
			Sfx.caution_chime()
	else:
		warnings[id] = text


func _damage(amount: float, announce: bool = true) -> void:
	amount *= {"easy": 0.5, "hard": 1.5}.get(difficulty(), 1.0)
	hull = maxf(0.0, hull - amount)
	damage_taken += amount
	if announce and amount > 2.0:
		camera_shake = minf(1.0, camera_shake + amount * 0.05)
		Voice.say("Hull hit! %d percent" % int(hull), 2)


func _check_damage() -> void:
	if sim.hull_temp > 1550.0:
		_damage((sim.hull_temp - 1550.0) * 0.004 * get_process_delta_time(), false)
	if sim.gear_hit > 9.0 or sim.hull_hit > 7.0:
		var imp := maxf(sim.gear_hit, sim.hull_hit)
		Sfx.explosion()
		camera_shake = 1.0
		fail_mission("CRASH! Hit the ground at %d m/s." % int(imp))
		return
	elif sim.hull_hit > 2.5:
		_damage(sim.hull_hit * 4.0)
	elif sim.gear_hit > 5.0:
		_damage(sim.gear_hit * 2.0)
		Voice.say("Hard landing!", 1)
	if hull <= 0.0:
		Sfx.explosion()
		fail_mission("The Falcon took too much damage.")
	if o2 <= 0.0:
		fail_mission("Out of oxygen! Keep LIFE SUPPORT on.")


# ======================================================================== crew inputs
func _crew_inputs(dt: float) -> void:
	var avionics: bool = powered.get("avionics", false)
	var guidance: bool = powered.get("guidance", false)
	# ---- Pilot
	sim.in_rot = Vector3(InputHub.axis("pitch"), InputHub.axis("yaw"), InputHub.axis("roll"))
	var fa := InputHub.group("fa")
	if fa != ShipSim.FA.OFF and not guidance:
		fa = ShipSim.FA.OFF
	if fa != sim.fa_mode:
		sim.fa_mode = fa
		Voice.say("Assist " + ShipSim.FA_NAMES[fa])
	sim.throttle_cmd = InputHub.axis("throttle")
	sim.boost = InputHub.on("boost") and sim.engine_on
	if InputHub.just_pressed("ignition"):
		if not InputHub.on("engine_arm"):
			Voice.say("Engine not armed. Flip ENGINE ARM first.", 1)
		elif not sim.engine_enabled:
			Voice.say("Engine blocked. Check fuel pumps, ignition arm, and fire.", 1)
		elif not sim.engine_on and Eva.blocks_engine():
			Eva.request_burn_go()   # spacewalker outside: the Commander calls GO / NO-GO first
		elif sim.engine_on:
			sim.engine_on = false
			Voice.say("Engine shutdown")
		else:
			sim.engine_on = true
			Voice.say("Ignition!")
			camera_shake = 0.4
			game_event.emit("ignition", {})
	if not InputHub.on("engine_arm") and sim.engine_on:
		sim.engine_on = false
		Voice.say("Engine safe")
	if InputHub.on("gear") != sim.gear_down:
		sim.gear_down = InputHub.on("gear")
		Voice.say("Gear down" if sim.gear_down else "Gear up")
		Sfx.tone(140.0, 0.6, 0.2, "saw", 100.0)
	sim.airbrake = InputHub.on("airbrake")
	var flaps := 0.0 if InputHub.on("flaps_up") else (1.0 if InputHub.on("flaps_down") else 0.5)
	if flaps != sim.flaps:
		sim.flaps = flaps
		Voice.say(["Flaps up", "Flaps half", "Flaps down"][int(flaps * 2.0)])
	if InputHub.just_pressed("assist_push"):
		Voice.say("Assist " + ShipSim.FA_NAMES[sim.fa_mode])
	if InputHub.just_pressed("ops_mode_push"):
		Voice.say("Ops mode " + OPS_MODES[ops_mode])
	if InputHub.just_pressed("view_cycle"):
		view_mode = (view_mode + 1) % 2
	laser_on = InputHub.on("pilot_trigger") and mission != null and mission.laser_enabled and avionics
	if InputHub.just_pressed("pilot_trigger") and laser_on:
		Sfx.laser()

	# ---- Ops
	var ops_axes := Vector3(InputHub.axis("tx"), InputHub.axis("ty"), InputHub.axis("tz"))
	sim.in_trans = Vector3.ZERO
	match ops_mode:
		0:
			sim.in_trans = ops_axes
		1:
			arm_yaw = clampf(arm_yaw - ops_axes.x * dt * 0.8, -1.4, 1.4)
			arm_pitch = clampf(arm_pitch + ops_axes.y * dt * 0.8, -0.2, 1.5)
			arm_len = clampf(arm_len + ops_axes.z * dt * 3.0, 3.0, 12.0)
		2:
			arm_yaw = clampf(arm_yaw - ops_axes.x * dt * 0.8, -1.4, 1.4)
	if InputHub.just_pressed("ops_trigger"):
		match ops_mode:
			0:
				if mission:
					mission.on_ops_trigger()
			2:
				scanner_ping()
	beam_on = ops_mode == 1 and arm_extend > 0.95 and InputHub.on("ops_trigger") and powered.get("arm", false)
	if InputHub.just_pressed("ops_trigger") and ops_mode == 1:
		if arm_extend < 0.95:
			Voice.say("Open the cargo doors to use the arm." if cargo_door < 0.95 else "Arm deploying...")
		elif mission:
			mission.on_arm_trigger()
	if InputHub.just_pressed("scanner_ping"):
		scanner_ping()
	if InputHub.just_pressed("nav_target"):
		cycle_nav_target()
	if InputHub.just_pressed("fire_suppress") and not failures["fire"]:
		Sfx.tone(500.0, 0.6, 0.2, "noise")
	if InputHub.just_pressed("jump_engage"):
		engage_jump()
	if InputHub.just_pressed("dock_clamp") and mission:
		mission.on_dock_clamp()
	_update_nav_dir()
	sim.nav_dir = nav_dir
	sim.max_rate = Vector3(deg_to_rad(22.0), deg_to_rad(22.0), deg_to_rad(40.0)) if fa != ShipSim.FA.OFF else Vector3.ONE * 3.0


func scanner_ping() -> void:
	if not powered.get("sensors", false):
		Voice.say("Sensors are off. Ops: turn SENSORS on.", 1)
		return
	if scanner_age < 3.0:
		return
	scanner_age = 0.0
	Sfx.tone(600.0, 1.2, 0.25, "sine", 1800.0)
	game_event.emit("scanner_ping", {})
	if mission:
		mission.on_scanner_ping()


func cycle_nav_target() -> void:
	if nav_targets.is_empty():
		Voice.say("No targets in range")
		return
	if not powered.get("sensors", false):
		Voice.say("Turn SENSORS on to lock a target.", 1)
		return
	for i in nav_targets.size():
		nav_index = (nav_index + 1) % nav_targets.size()
		if target_revealed(nav_targets[nav_index]):
			break
	Voice.say("Target: " + str(nav_targets[nav_index]["name"]))
	Sfx.beep()


func set_nav_target_by_name(nm: String) -> void:
	for i in nav_targets.size():
		if nav_targets[i]["name"] == nm:
			nav_index = i
			return


func target_revealed(tgt: Dictionary) -> bool:
	if tgt.has("entity"):
		return bool(tgt["entity"].get("revealed", true))
	return true


func current_target() -> Dictionary:
	if nav_index < 0 or nav_index >= nav_targets.size():
		return {}
	return nav_targets[nav_index]


## Position (BigVec) and velocity of the current nav target.
func target_state() -> Array:
	var tgt := current_target()
	if tgt.is_empty():
		return []
	if tgt.has("entity"):
		var e: Dictionary = tgt["entity"]
		var p: BigVec = e["pos"]
		if tgt.has("port"):
			p = p.copy()
			p.add(e["basis"] * tgt["port"])
		return [p, e["vel"]]
	var b: CelestialBody = tgt["body"]
	return [b.pos, b.vel]


func _update_nav_dir() -> void:
	var sv := sim.surface_vel
	match nav_vector:
		"PROGRADE":
			nav_dir = sv.normalized() if sv.length() > 0.5 else Vector3.ZERO
		"RETROGRADE":
			nav_dir = -sv.normalized() if sv.length() > 0.5 else Vector3.ZERO
		"RADIAL OUT":
			nav_dir = sim.up_dir
		"TARGET", "TGT RETRO":
			var ts := target_state()
			if ts.is_empty():
				nav_dir = Vector3.ZERO
			elif nav_vector == "TARGET":
				nav_dir = (ts[0] as BigVec).rel(sim.pos).normalized()
			else:
				var rv: Vector3 = sim.vel - ts[1]
				nav_dir = -rv.normalized() if rv.length() > 0.05 else Vector3.ZERO
		"GUIDANCE":
			nav_dir = mission.guidance_dir() if mission else Vector3.ZERO


func engage_jump() -> void:
	if not InputHub.on("jump_arm"):
		Voice.say("Jump drive not armed. Ops: flip JUMP ARM.", 1)
		return
	if jump_charge < 100.0:
		Voice.say("Jump drive still charging: %d percent" % int(jump_charge), 1)
		return
	if mission and not mission.can_jump():
		return
	jump_charge = 0.0
	jump_phase = 0.001
	Sfx.jump_spool()
	Voice.say("Engaging jump drive! Hold on!", 1)
	game_event.emit("jump_start", {})
	var tw := create_tween()
	tw.tween_property(self, "jump_phase", 1.0, 3.0)
	tw.tween_callback(_on_jump_arrive)


func _on_jump_arrive() -> void:
	if mission:
		mission.on_jump_complete()
	game_event.emit("jump_end", {})
	var tw2 := create_tween()
	tw2.tween_property(self, "jump_phase", 0.0, 1.2)


# ======================================================================== completion
## Commander actions (refuel, debug slew, ...): printed, kept for the PANEL page, emitted.
func log_commander(text: String) -> void:
	var line := "[%02d:%02d] %s" % [int(mission_time) / 60, int(mission_time) % 60, text]
	commander_log.append(line)
	if commander_log.size() > 30:
		commander_log.pop_front()
	print("[COMMANDER] ", line)
	game_event.emit("commander", {"text": text})


## REFUEL (Commander PANEL): frac 1.0 = FULL, 0.25 = +25 % of capacity. Tops up main propellant
## (and an attached booster), RCS monopropellant, cabin O2 (+ the spacewalker's suit) and power.
func refuel(frac: float) -> void:
	var full := frac >= 0.999
	var top := func(v: float, mx: float) -> float: return mx if full else minf(mx, v + mx * frac)
	var before := [sim.fuel, sim.mono, o2]
	sim.fuel = top.call(sim.fuel, sim.fuel_max)
	sim.mono = top.call(sim.mono, sim.mono_max)
	if sim.booster_attached:
		sim.booster_fuel = top.call(sim.booster_fuel, sim.booster_fuel_max)
	o2 = top.call(o2, 100.0)
	if Eva.sim != null:
		Eva.sim.o2 = top.call(Eva.sim.o2, 100.0)
	reactor_out = maxf(reactor_out, 100.0 if full else minf(100.0, reactor_out + 25.0))   # power: reactor at full output now
	if full:
		jump_charge = 100.0 if InputHub.on("jump_arm") else jump_charge
	_set_warning("fuel", "")
	log_commander("REFUEL %s: fuel %.0f→%.0f kg, RCS %.0f→%.0f kg, O2 %.0f→%.0f %%, power %.0f %%" % [
		"FULL" if full else "+25%", before[0], sim.fuel, before[1], sim.mono, before[2], o2, reactor_out])
	Voice.say("Refuelled" if full else "Fuel top up", 1)


func add_score(label: String, pts: int) -> void:
	score_items.append([label, pts])


func complete_mission(text: String = "") -> void:
	if state == State.COMPLETE or state == State.FAILED:
		return
	state = State.COMPLETE
	result_text = text if text != "" else "MISSION COMPLETE!"
	mission.final_score()
	if damage_taken < 1.0:
		add_score("No damage bonus", 200)
	else:
		add_score("Hull damage", -int(damage_taken * 4.0))
	score_total = 0
	for s in score_items:
		score_total += int(s[1])
	stars = 3 if score_total >= mission.star_thresholds[1] else (2 if score_total >= mission.star_thresholds[0] else 1)
	if mission_id != "captains_log":
		last_result = {"id": mission_id, "title": mission.title, "score": score_total, "stars": stars, "ok": true}
	if mission.calm:
		Voice.say(result_text, 1)
	else:
		Voice.say(result_text + " %d stars!" % stars, 1)
		Sfx.fanfare()
	mission_finished.emit(true)
	game_event.emit("complete", {})


func fail_mission(text: String) -> void:
	if state != State.ACTIVE:
		return
	state = State.FAILED
	result_text = text
	sim.engine_on = false
	Voice.say(text + " Press START to try again.", 2)
	Sfx.sad_trombone()
	mission_finished.emit(false)
	game_event.emit("failed", {})


func _update_objective_text() -> void:
	if mission == null:
		return
	var o := mission.current_objective()
	objective_text = str(o.get("text", ""))


# ======================================================================== audio + LEDs
func _update_audio() -> void:
	var live := state == State.ACTIVE
	Sfx.engine_level = (sim.thrust_now / (sim.booster_thrust if sim.booster_attached else sim.main_thrust)) * (1.4 if sim.booster_attached else 1.0) if live else 0.0
	Sfx.rcs_level = clampf(sim.rcs_trans_activity.length() + sim.rcs_rot_activity.length() * 0.3, 0.0, 1.0) if live else 0.0
	Sfx.wind_level = clampf(sim.dyn_pressure / 15000.0, 0.0, 1.0) + clampf(sim.heat_flux / 200000.0, 0.0, 0.6) if live else 0.0
	Sfx.alarm_on = caution_active and not caution_silenced and not warnings.is_empty()
	Sfx.ambience = 0.6 if master_power else 0.0


func _update_leds() -> void:
	if not LedLink.enabled:
		return
	var white := Color(1, 1, 1) * 0.85
	var dim := white * 0.35
	var green := Color(0.1, 1.0, 0.2)
	var amber := Color(1.0, 0.55, 0.0)
	var red := Color(1, 0.05, 0.05)
	var blue := Color(0.2, 0.5, 1.0)
	var purple := Color(0.6, 0.2, 1.0)
	if not master_power:
		LedLink.set_all_signals(Color.BLACK, "OFF")
		LedLink.set_signal("master_power", red, "PULSE")
		return
	# Overhead checklist: green = done in order, blinking white = next step, red fast = out of order
	for i in CHECKLIST.size():
		var id: String = CHECKLIST[i]
		if seq_ok[i] and InputHub.on(id):
			LedLink.set_signal(id, green)
		elif checklist_error == i and InputHub.on(id):
			LedLink.set_signal(id, red, "FAST")
		elif i == checklist_progress:
			LedLink.set_signal(id, white, "BLINK")
		else:
			LedLink.set_signal(id, dim)
	for id in ["cabin_lights", "beacon", "strobe", "nav_lights"]:
		LedLink.set_signal(id, green if InputHub.on(id) else dim)
	LedLink.set_signal("eject", red, "PULSE")
	# Pilot
	LedLink.set_signal("engine_arm", amber if InputHub.on("engine_arm") else dim, "PULSE" if InputHub.on("engine_arm") and not sim.engine_on else "SOLID")
	LedLink.set_signal("ignition", green if sim.engine_on else (amber if InputHub.on("engine_arm") else dim), "BLINK" if InputHub.on("engine_arm") and not sim.engine_on else "SOLID")
	var moving := sim.gear_pos > 0.01 and sim.gear_pos < 0.99
	LedLink.set_signal("gear", green if sim.gear_pos > 0.99 else (amber if moving else white), "BLINK" if moving else "SOLID")
	LedLink.set_signal("gear_down_led", green if sim.gear_pos > 0.99 else (amber if moving else Color.BLACK), "BLINK" if moving else "SOLID")
	LedLink.set_signal("gear_up", white if sim.gear_pos < 0.01 else dim)
	LedLink.set_signal("gear_dn", green if sim.gear_pos > 0.99 else dim)
	LedLink.set_signal("gear_lights", green if sim.gear_pos > 0.99 else dim)
	for i in 4:
		LedLink.set_signal(["fa_off", "fa_stab", "fa_prograde", "fa_hold"][i], blue if sim.fa_mode == i else dim)
	LedLink.set_signal("assist", white)
	LedLink.set_signal("airbrake", amber if sim.airbrake else dim)
	LedLink.set_signal("flaps", amber if sim.flaps > 0.75 else (white if sim.flaps > 0.25 else dim))
	LedLink.set_signal("boost", Color(1, 0.3, 1) if sim.boost else white * 0.5)
	LedLink.set_signal("view_cycle", white * 0.6)
	LedLink.set_signal("horn", white * 0.6)
	LedLink.set_signal("throttle", white * (0.4 + 0.6 * sim.throttle))
	LedLink.set_signal("thr_max", green if sim.throttle > 0.95 else dim)
	LedLink.set_signal("thr_idle", white if sim.throttle < 0.05 else dim)
	# Ops
	for pair in [["pwr_reactor", "reactor"], ["pwr_life", "life"], ["pwr_shields", "shields"], ["pwr_comms", "comms"], ["pwr_sensors", "sensors"]]:
		var on_sw := InputHub.on(pair[0])
		var sysk: String = pair[1]
		var c := dim
		if on_sw:
			c = green if (sysk == "reactor" and reactor_out > 90.0) or powered.get(sysk, false) else amber
		var fault: bool = (sysk == "reactor" and failures["power"]) or (sysk == "sensors" and failures["sensor"]) or (sysk == "life" and failures["leak"])
		LedLink.set_signal(pair[0], red if fault else c, "FAST" if fault else "SOLID")
	LedLink.set_signal("mode", white)
	for i in 3:
		LedLink.set_signal(["mode_rcs", "mode_arm", "mode_scanner"][i], blue if ops_mode == i else dim)
	var doors_moving := cargo_door > 0.01 and cargo_door < 0.99
	LedLink.set_signal("cargo_doors", amber if doors_moving else (green if cargo_door >= 0.99 else dim), "BLINK" if doors_moving else "SOLID")
	LedLink.set_signal("dock_clamp", green if InputHub.on("dock_clamp") else dim)
	LedLink.set_signal("scanner_ping", blue if scanner_age < 2.0 else white * 0.6, "PULSE" if scanner_age < 2.0 else "SOLID")
	LedLink.set_signal("fire_suppress", red if failures["fire"] else dim, "FAST" if failures["fire"] else "SOLID")
	LedLink.set_signal("nav_target", blue if nav_index >= 0 else white * 0.5)
	LedLink.set_signal("jump_arm", purple if InputHub.on("jump_arm") else dim, "PULSE" if InputHub.on("jump_arm") and jump_charge < 100.0 else "SOLID")
	LedLink.set_signal("jump_charge", purple * clampf(jump_charge / 100.0, 0.1, 1.0), "BLINK" if jump_charge >= 100.0 else "SOLID")
	LedLink.set_signal("jump_engage", purple if jump_charge >= 100.0 else dim, "FAST" if jump_charge >= 100.0 else "SOLID")
	LedLink.set_signal("hyperspace", purple if jump_phase > 0.0 else white * 0.5, "FAST" if jump_phase > 0.0 else "SOLID")
	# Commander
	LedLink.set_signal("master_power", green)
	LedLink.set_signal("mission_select", blue if state != State.ACTIVE else dim)
	LedLink.set_signal("start", green if state == State.ACTIVE else amber, "BLINK" if state == State.BRIEFING and (checklist_progress >= CHECKLIST.size() or not mission.requires_checklist) else "SOLID")
	LedLink.set_signal("pause", amber if state == State.PAUSED else dim, "PULSE" if state == State.PAUSED else "SOLID")
	var alarm := caution_active and not caution_silenced
	LedLink.set_signal("master_caution", amber if alarm else (amber * 0.5 if not warnings.is_empty() else white * 0.3), "FAST" if alarm else "SOLID")
	LedLink.set_signal("caution_reset", amber if alarm else dim, "BLINK" if alarm else "SOLID")
	LedLink.set_signal("failures", white * 0.6)
	for f in ["fire", "leak", "power", "sensor"]:
		LedLink.set_signal("fail_" + f, red if failures[f] else white * 0.4, "FAST" if failures[f] else "SOLID")
	LedLink.set_signal("intercom", green if Ics.keyed("commander") else (amber if Ics.ok() else white * 0.4), "PULSE" if Ics.status.get("allcall", false) else "SOLID")
	LedLink.set_signal("dimmer", white * 0.6)
	LedLink.set_signal("crew_ready", green if checklist_progress >= CHECKLIST.size() else white, "SOLID" if checklist_progress >= CHECKLIST.size() else "BLINK")
	LedLink.set_signal("pilot_ready", green if InputHub.on("engine_arm") or state == State.ACTIVE else amber)
	LedLink.set_signal("ops_ready", green if InputHub.on("pwr_reactor") else amber)
	# FLT (seat_up LED id) = "pod down, ready to fly"; BRD (seat_dn) = "seats up, ready to board".
	var pod_moving := pod.pod == PodMonitor.Pod.MOVING or pod.seats == PodMonitor.Seats.MOVING
	LedLink.set_signal("seat_up", green if pod.pod == PodMonitor.Pod.DOWN_LOCKED else (amber if pod_moving else dim), "BLINK" if pod_moving else "SOLID")
	LedLink.set_signal("seat_dn", green if pod.pod == PodMonitor.Pod.UP and pod.seats == PodMonitor.Seats.UPRIGHT else dim)
	LedLink.set_signal("seat_static", white * 0.5)
