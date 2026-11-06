extends Node
## Lean booster recovery FSM check (`-- --booster-recovery-test`).
## Places a free booster near the pad catch point and ticks until caught / fail-safe landed.

const DT := 1.0 / 30.0

var _ok := true


func _ready() -> void:
	Game.external_clock = true
	_run.call_deferred()


func _check(cond: bool, what: String) -> void:
	print(("  ok   " if cond else "  FAIL ") + what)
	if not cond:
		_ok = false


func _ticks(seconds: float) -> void:
	for i in int(round(seconds / DT)):
		Game.tick(DT)


func _run() -> void:
	Game.load_mission("launch")
	await get_tree().process_frame
	_check(Game.mission != null and Game.mission.id == "launch", "launch mission loaded")
	# Physics / entity recovery only integrates while ACTIVE.
	Game.state = Game.State.ACTIVE
	var pads := Game.entities_of("pad")
	_check(not pads.is_empty(), "pad entity present")
	var boosters := Game.entities_of("booster")
	_check(not boosters.is_empty(), "booster entity present")
	var pad: Dictionary = pads[0]
	var booster: Dictionary = boosters[0]
	# Stage-like free state near chopsticks (fail-safe / catch path).
	Game.sim.booster_attached = false
	booster["mode"] = "free"
	booster["basis"] = pad.get("basis", Basis.IDENTITY)
	var catch: BigVec = pad["pos"].copy()
	catch.add(Game._booster_catch_offset(pad))
	var up: Vector3 = (pad.get("basis", Basis.IDENTITY) as Basis).y
	var east: Vector3 = (pad.get("basis", Basis.IDENTITY) as Basis).x
	booster["pos"] = catch.copy()
	booster["pos"].add(up * 120.0 + east * 80.0)
	booster["vel"] = pad.get("vel", Vector3.ZERO) - up * 12.0
	Game.begin_booster_recovery(booster)
	# Jump straight to landing so the lean test stays short.
	booster["recovery"] = "landing"
	booster["recovery_t"] = 0.0
	booster["legs_deployed"] = true
	booster["fins_deployed"] = true
	_check(str(booster.get("recovery", "")) == "landing", "recovery starts in landing")

	var caught := false
	var max_t := 80.0
	var t := 0.0
	while t < max_t:
		_ticks(0.5)
		t += 0.5
		var ph := str(booster.get("recovery", ""))
		if ph == "caught" or (booster.get("mode", "") == "landed" and ph == "caught"):
			caught = true
			break
	_check(caught, "booster reached caught within %.0fs (phase=%s mode=%s)" % [t, str(booster.get("recovery","")), str(booster.get("mode",""))])
	if caught:
		var dist := catch.rel(booster["pos"]).length()
		_check(dist < 120.0, "caught near pad catch point (dist=%.1f m)" % dist)
		_check(float(booster.get("thrust_frac", 1.0)) < 0.05, "engines off after catch")
	# Chopsticks exist on pad model factory (World builds from Models.pad).
	var pad_model := Models.pad()
	_check(pad_model.get_node_or_null("Chopsticks") != null, "Models.pad has Chopsticks")
	pad_model.free()
	var bmodel := Models.booster()
	_check(bmodel.get_node_or_null("GridFins") != null, "booster has GridFins")
	_check(bmodel.get_node_or_null("LandingLegs") != null, "booster has LandingLegs")
	_check(bmodel.get_node_or_null("Plume") != null and bmodel.get_node_or_null("Light") != null, "booster Plume/Light nodes")
	# Count engine bells roughly: many MeshInstance children under root
	var meshes := 0
	for c in bmodel.get_children():
		if c is MeshInstance3D:
			meshes += 1
	_check(meshes >= 20, "dense Raptor cluster mesh count (%d)" % meshes)
	bmodel.free()

	print("BOOSTER RECOVERY TEST: ", "PASS" if _ok else "FAIL")
	get_tree().quit(0 if _ok else 1)
