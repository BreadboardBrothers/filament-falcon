extends Node
## Headless Flight 15 profile (`-- --flight15-test`).
## After a real launch (arm / ignition / throttle only), no further crew input.
## Checks event order, booster low-fuel-mass abort + Gulf FTS, 26 PEZ deploys,
## entry flaps/plasma, flip, and ship catch near the tower.

const DT := 1.0 / 30.0

var _ok := true
var _track: Array = []


func _ready() -> void:
	Game.external_clock = true
	_run.call_deferred()


func _check(cond: bool, what: String) -> void:
	print(("  ok   " if cond else "  FAIL ") + what)
	if not cond:
		_ok = false


func _ticks(seconds: float) -> void:
	for i in int(round(seconds / DT)):
		InputHub._process(DT)
		Game.tick(DT)
		_sample_track()


func _sample_track() -> void:
	var m: Mission = Game.mission
	if m == null or str(m.phase) not in ["entry", "swoosh", "flip", "landing", "catching"]:
		return
	var ll := Geo.latlon(Game.sim.pos.rel(Game.earth.pos))
	_track.append(ll)


func _event_names(m: Mission) -> PackedStringArray:
	var out := PackedStringArray()
	for e in m.events:
		out.append(str(e["name"]))
	return out


func _index(names: PackedStringArray, n: String) -> int:
	for i in names.size():
		if names[i] == n:
			return i
	return -1


func _gulf_water(lat: float, lon: float) -> bool:
	# South Texas Gulf: east of the Boca Chica / South Padre coastline (~97.15 W).
	if lon > -97.05 and lon < -96.3 and lat > 25.55 and lat < 26.65:
		return true
	if Game.earth.terrain:
		var s: Vector3 = Game.earth.terrain.sample(Geo.game_dir(lat, lon))
		if s.y > 0.55:
			return true
	return false


func _run() -> void:
	Game.load_mission("flight15")
	await get_tree().process_frame
	var m: Mission = Game.mission
	_check(m != null and str(m.id) == "flight15", "Flight 15 mission loaded")
	if m == null or str(m.id) != "flight15":
		print("FLIGHT 15 TEST: FAIL (mission did not load)")
		get_tree().quit(1)
		return
	var pad_ll := Geo.latlon(Game.pad_dir)
	_check(absf(pad_ll.x - 25.99677) < 0.05 and absf(pad_ll.y + 97.15799) < 0.05, "pad is at Starbase OLP-2 (%.3f, %.3f)" % [pad_ll.x, pad_ll.y])
	_check(str(Game.entities_of("pad")[0].get("site", "")) == "starbase", "pad site tagged starbase")
	var site := Models.starbase()
	_check(site.get_node_or_null("Chopsticks") != null, "Starbase model includes Mechazilla chopsticks")
	site.free()
	_check(Game.sim.booster_attached, "stacked on the tower at T-0")
	_check(m.sats.size() == 26, "26 Starlink V3 loaded")

	# Overhead checklist, then only launch inputs.
	Game.state = Game.State.ACTIVE
	m.start()
	for sid in Game.CHECKLIST:
		InputHub.set_switch(sid, true)
		_ticks(0.1)
	InputHub.set_switch("engine_arm", true)
	InputHub.set_switch("ignition", true)
	InputHub.set_axis_override("throttle", 1.0)
	# Countdown + ignition: hold throttle through liftoff.
	var launched := false
	for i in 40:
		if i == 8:
			# just_pressed needs a rising edge; pulse ignition once after arm.
			InputHub.set_switch("ignition", false)
			_ticks(DT)
			InputHub.set_switch("ignition", true)
		_ticks(0.5)
		if m.liftoff:
			launched = true
			break
	_check(launched, "liftoff with launch controls only")
	# From here: no more flight inputs (views only are allowed; we send none).
	InputHub.set_switch("ignition", false)
	InputHub.set_switch("engine_arm", true)
	InputHub.set_axis_override("throttle", 0.0)
	for a in ["pitch", "yaw", "roll", "tx", "ty", "tz"]:
		InputHub.set_axis_override(a, 0.0)
	for s in ["ops_trigger", "cargo_doors", "flaps_up", "flaps_down", "pilot_trigger"]:
		InputHub.set_switch(s, false)
	_check(Game.watch_only, "watch-only lock engages after liftoff")

	var t := 0.0
	var max_t := 180.0
	while t < max_t and Game.state == Game.State.ACTIVE:
		_ticks(0.5)
		t += 0.5
		if m.caught and str(m.phase) == "caught":
			break
	_check(Game.state == Game.State.COMPLETE or m.caught, "flight completed with no input after launch (state=%s phase=%s t=%.0fs)" % [Game.STATE_NAMES[Game.state], m.phase, t])

	var names := _event_names(m)
	print("  events: ", ", ".join(names))
	var order := ["liftoff", "staging", "booster_error", "booster_divert", "booster_fts", "deploy_start", "deploy_complete", "entry", "plasma_on", "flip", "catch"]
	var last := -1
	for ev in order:
		var i := _index(names, ev)
		_check(i >= 0, "event '%s' happened" % ev)
		if i >= 0:
			_check(i > last, "event '%s' is in order" % ev)
			last = i if i > last else last

	var b: Dictionary = m.booster
	_check(str(b.get("error", "")) == "low fuel mass alarm", "booster error is the real low fuel mass alarm")
	_check(bool(b.get("abort", false)), "GNC abort / divert was raised")
	_check(str(b.get("recovery", "")) == "destroyed" or bool(b.get("destroyed", false)), "booster self-destructed (FTS), not caught")
	_check(Game.warnings.has("booster_fuel") and str(Game.warnings["booster_fuel"]).findn("low fuel mass") >= 0, "Commander shows low fuel mass alarm wording")
	_check(Game.warnings.has("booster_gnc") and str(Game.warnings["booster_gnc"]).findn("offshore") >= 0, "Commander shows GNC abort / offshore divert wording")
	_check(Game.warnings.has("booster_fts") and str(Game.warnings["booster_fts"]).findn("termination") >= 0, "Commander shows flight termination wording")
	var dpos: BigVec = b.get("destruct_pos", b.get("pos"))
	var dll := Geo.latlon(dpos.rel(Game.earth.pos))
	var pad_pos: BigVec = Game.entities_of("pad")[0]["pos"]
	var dist := pad_pos.rel(dpos).length()
	_check(_gulf_water(dll.x, dll.y), "FTS point is over the Gulf (%.3f, %.3f)" % [dll.x, dll.y])
	_check(dist > 15000.0, "FTS is away from the shore / pad (%.1f km)" % (dist / 1000.0))
	# Not over Brownsville (~25.90, -97.50) or South Padre town (~26.12, -97.17).
	var spi := Vector2(26.12, -97.17)
	var brownsville := Vector2(25.90, -97.50)
	var d_spi := Vector2(dll.x - spi.x, (dll.y - spi.y) * cos(deg_to_rad(26.0))).length() * 111000.0
	var d_br := Vector2(dll.x - brownsville.x, (dll.y - brownsville.y) * cos(deg_to_rad(26.0))).length() * 111000.0
	_check(d_spi > 10000.0 and d_br > 10000.0, "FTS away from South Padre and Brownsville (%.1f / %.1f km)" % [d_spi / 1000.0, d_br / 1000.0])

	_check(m.deployed == 26, "all 26 Starlink V3 deployed (%d)" % m.deployed)
	_check(Game.pez_door > 0.8, "PEZ door opened for deploy")
	_check(m.flaps_moved, "flaps actuated during entry")
	_check(m.plasma_seen, "plasma was shown during entry")
	# Ground track of the final return (swoosh): stay over water / away from towns until the beach.
	var over_town := 0
	var over_water := 0
	for ll in _track:
		var p: Vector2 = ll
		var from_pad := Vector2(p.x - pad_ll.x, (p.y - pad_ll.y) * cos(deg_to_rad(26.0))).length() * 111000.0
		# Inhabited boxes, excluding the Starbase beach itself.
		var over_spi := p.x > 26.08 and p.x < 26.20 and p.y < -97.12 and p.y > -97.22
		var over_brownsville := p.x > 25.85 and p.x < 26.02 and p.y < -97.40 and p.y > -97.55
		if from_pad > 8000.0 and (over_spi or over_brownsville):
			over_town += 1
		if _gulf_water(p.x, p.y):
			over_water += 1
	_check(over_town == 0, "final approach does not cut over Brownsville / South Padre (%d samples)" % over_town)
	if not _track.is_empty():
		_check(over_water > 0, "return swoosh has samples over the Gulf (%d/%d)" % [over_water, _track.size()])
	if not _track.is_empty():
		var last_ll: Vector2 = _track[_track.size() - 1]
		print("  last track=%.3f, %.3f  samples=%d  booster rec=%s  fts=%.3f, %.3f" % [last_ll.x, last_ll.y, _track.size(), str(b.get("recovery", "")), dll.x, dll.y])

	_check(m.caught, "ship was caught")
	var catch_d := pad_pos.rel(Game.sim.pos).length()
	_check(catch_d < 120.0, "ship caught near the tower (%.1f m)" % catch_d)
	_check(float(m.guidance.get("chopstick_close", 0.0)) > 0.5, "chopsticks closed on the ship")
	_check(not Game.sim.engine_on, "engines off after catch")

	print("FLIGHT 15 TEST: ", "PASS" if _ok else "FAIL")
	get_tree().quit(0 if _ok else 1)
