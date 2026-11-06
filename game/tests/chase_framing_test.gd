extends Node
## Headless chase / bezel framing checks (`-- --chase-framing-test`).
## Proves the twin-OTW off-axis centre sits in the bezel, and chase yaw clears it
## for ship-only and full-stack lengths without changing cockpit geometry.

var _ok := true


func _ready() -> void:
	_run.call_deferred()


func _check(cond: bool, what: String) -> void:
	print(("  ok   " if cond else "  FAIL ") + what)
	if not cond:
		_ok = false


func _run() -> void:
	var dm := DisplayManager.new()
	dm.name = "DisplayMgrTest"
	add_child(dm)
	dm.out_views = ["left", "right"]
	dm.near_now = dm.NEAR

	# Defaults match twin 27" 1080p (settings DEFAULTS).
	var gap := float(Settings.get_v("display", "monitor_gap_m"))
	var W := float(Settings.get_v("display", "monitor_width_m"))
	var D := float(Settings.get_v("display", "eye_distance_m"))
	_check(gap > 0.0 and W > 0.4 and D > 0.3, "27\"-class geometry defaults (gap=%.3f W=%.3f D=%.3f)" % [gap, W, D])

	var half_bez := dm.bezel_half_angle()
	_check(half_bez > 0.01 and half_bez < 0.2, "bezel half-angle sane (%.3f rad)" % half_bez)

	# Optical centre (yaw 0) is inside the bezel — the chase bug Yves hit.
	_check(not dm.clears_bezel(0.0, 0.0), "yaw 0 look-at sits inside bezel (root cause)")
	_check(not dm.clears_bezel(dm.chase_look_x_on_plane(0.0), 0.0), "look_x(0) inside bezel")

	var yaw := dm.chase_bezel_yaw()
	_check(absf(yaw) > half_bez, "default chase yaw (%.3f) exceeds bezel half-angle (%.3f)" % [yaw, half_bez])
	var x := dm.chase_look_x_on_plane(yaw)
	var clear := float(Settings.get_v("display", "chase_bezel_clear_m"))
	_check(dm.clears_bezel(x, clear * 0.5), "default chase look clears bezel (x=%.3f m, clear=%.3f)" % [x, clear])
	_check(x > 0.0, "default bias frames toward +X (right panel)")

	# Left bias
	Settings.set_v("display", "chase_bezel_bias", -0.55)
	var yaw_l := dm.chase_bezel_yaw()
	_check(yaw_l < 0.0 and dm.clears_bezel(dm.chase_look_x_on_plane(yaw_l), 0.0), "negative bias clears bezel on left")
	Settings.set_v("display", "chase_bezel_bias", 0.55)

	# Single OTW / solo: no yaw (centred framing)
	dm.out_views = ["left"]
	_check(is_zero_approx(dm.chase_bezel_yaw()), "single OTW view → no bezel yaw")
	dm.out_views = ["left", "right"]
	dm.solo_view = "left"
	dm.solo_true = false
	_check(is_zero_approx(dm.chase_bezel_yaw()), "solo centred screenshot → no bezel yaw")
	dm.solo_view = ""

	# Cockpit frusta unchanged: left/right screen rects still straddle the gap.
	var left := dm.screen_rect_for("left")
	var right := dm.screen_rect_for("right")
	_check(float(left["center"].x) < 0.0 and float(right["center"].x) > 0.0, "cockpit left/right rects straddle bezel")
	var fl: Array = dm.off_axis(left)
	var fr: Array = dm.off_axis(right)
	_check(fl[1] > 0.0 and fr[1] > 0.0, "cockpit off-axis frustum sizes positive")

	# Stack angular size vs panel: whole rocket should fit beside the bezel at chase distance.
	for pair: Array in [[false, 15.0, 34.0], [true, 42.0, 75.0]]:
		var with_b: bool = pair[0]
		var length: float = pair[1]
		var dist: float = pair[2]
		var half_ang := atan((length * 0.5) / dist)
		var panel_half := atan((W * 0.5) / D)
		_check(half_ang < panel_half * 0.95, "%s stack half-angle %.3f < panel %.3f" % ["full" if with_b else "ship", half_ang, panel_half])
		# After yaw, stack centre is at x; stack extent ± (length/2)* (D/dist) approx on plane
		var extent := (length * 0.5) * (D / dist)
		var x2 := dm.chase_look_x_on_plane()
		var inner := absf(x2) - extent
		_check(inner > gap * 0.5, "%s stack inner edge clears bezel (inner=%.3f gap/2=%.3f)" % ["full" if with_b else "ship", inner, gap * 0.5])

	# World chase_xform + distance helpers (need a minimal sim)
	if Game and Game.sim:
		# Do not enter the tree — WorldView._ready builds the whole scene.
		var w := WorldView.new()
		Game.sim.booster_attached = false
		_check(absf(w.chase_distance(Game.sim) - 34.0) < 0.01, "chase_distance ship-only = 34")
		Game.sim.booster_attached = true
		_check(absf(w.chase_distance(Game.sim) - 75.0) < 0.01, "chase_distance with booster = 75")
		_check(w.chase_stack_length_m(Game.sim) >= 40.0, "full-stack length ≥ 40 m")
		var xf: Transform3D = w.chase_xform(Game.sim)
		_check(xf.origin.length() > 10.0, "chase_xform places eye behind stack")
		var forward := -xf.basis.z
		_check(forward.dot(-xf.origin.normalized()) > 0.5, "chase camera looks toward stack")
		Game.sim.booster_attached = false
		w.free()
	else:
		_check(false, "Game.sim available")

	# Bias 0 reproduces the bug (document + guard)
	Settings.set_v("display", "chase_bezel_bias", 0.0)
	_check(is_zero_approx(dm.chase_bezel_yaw()), "bias 0 → no yaw (legacy bezel-hidden)")
	Settings.set_v("display", "chase_bezel_bias", 0.55)

	dm.queue_free()
	print("CHASE FRAMING TEST: ", "PASS" if _ok else "FAIL")
	print("ROOT: twin off-axis OTW centre = bezel; chase yaws look-at clear of seam.")
	get_tree().quit(0 if _ok else 1)
