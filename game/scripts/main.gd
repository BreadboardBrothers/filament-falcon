extends Node
## Entry point: builds the 3D world, the three views (left/right windows + console) and,
## when asked on the command line, the automated test / screenshot runners.
##   godot --path game -- --dev                 single-window tiled dev mode
##   godot --path game -- --smoke-test          run every mission headless (cheat-advance)
##   godot --path game -- --hand-test           hand tracking -> glove orientation / curls
##   godot --path game -- --flight-test         autopilot bots genuinely fly the missions
##   XDG_DATA_HOME=$(mktemp -d) godot --headless --path game -- --area-runner-test   AREAS background job runner
##   XDG_DATA_HOME=$(mktemp -d) godot --headless --path game -- --nav-map-test        nav map globe + ground inset
##   XDG_DATA_HOME=$(mktemp -d) godot --headless --path game -- --map-layer-test       AREAS map roads / rivers / names
##   XDG_DATA_HOME=$(mktemp -d) godot --headless --path game -- --solar-test           SOLAR ephemeris + view
##   XDG_DATA_HOME=$(mktemp -d) godot --headless --path game -- --booster-recovery-test  booster RTLS/catch FSM
##   XDG_DATA_HOME=$(mktemp -d) godot --headless --path game -- --chase-framing-test     chase bezel framing
##   godot --path game -- --screenshots=DIR     capture the hero shots (use xvfb + lavapipe)
##   godot --path game --xr-mode on -- --eva-client   the VR spacewalk client (see EvaClient)

var world: WorldView
var display: DisplayManager


func _ready() -> void:
	if Settings.cli.has("iss"):    # print where the ISS is now (TLE source + age)
		print("ISS NOW: ", Geo.iss_now(float(Settings.cli.get("iss", -1.0)) if str(Settings.cli["iss"]).is_valid_float() else -1.0))
		get_tree().quit()
		return
	if Settings.cli.has("asset-test"):
		add_child(load("res://tests/asset_test.gd").new())
		return
	if Settings.cli.has("region-test"):
		add_child(load("res://tests/region_test.gd").new())
		return
	if Settings.cli.has("quit-test"):
		add_child(load("res://tests/quit_test.gd").new())
		return
	if Settings.cli.has("hand-test"):
		add_child(load("res://tests/hand_test.gd").new())
		return
	if Settings.cli.has("area-runner-test"):
		add_child(load("res://tests/area_runner_test.gd").new())
		return
	if Settings.cli.has("nav-map-test"):
		add_child(load("res://tests/nav_map_test.gd").new())
	if Settings.cli.has("map-layer-test"):
		add_child(load("res://tests/map_layer_test.gd").new())
		return
	if Settings.cli.has("solar-test"):
		add_child(load("res://tests/solar_test.gd").new())
		return
	if Settings.cli.has("booster-recovery-test"):
		add_child(load("res://tests/booster_recovery_test.gd").new())
		return
	if Settings.cli.has("chase-framing-test"):
		add_child(load("res://tests/chase_framing_test.gd").new())
		return
	if Settings.cli.has("ui-fit"):
		add_child(load("res://tests/ui_fit.gd").new())
		return
	if Settings.is_eva_client():
		# the VR spacewalk client (2nd process): only the world + the spacewalker's view
		var c := EvaClient.new()
		c.name = "EvaClient"
		add_child(c)
		return
	print("The Filament Falcon v0.1 | Godot %s | renderer %s | input map: %s" % [Engine.get_version_info()["string"],
		RenderingServer.get_current_rendering_method(), InputHub.map_source])
	for e in InputHub.map_errors:
		push_warning("input map: " + e)
	world = WorldView.new()
	world.name = "World"
	add_child(world)
	display = DisplayManager.new()
	display.name = "Display"
	add_child(display)
	display.setup(world)
	if Settings.cli.has("smoke-test"):
		var st: Node = load("res://tests/smoke_test.gd").new()
		st.name = "SmokeTest"
		add_child(st)
	elif Settings.cli.has("eva-tether-test"):
		var et: Node = load("res://tests/eva_tether_test.gd").new()
		et.name = "EvaTetherTest"
		add_child(et)
	elif Settings.cli.has("eva-frame-test"):
		var ef: Node = load("res://tests/eva_frame_test.gd").new()
		ef.name = "EvaFrameTest"
		add_child(ef)
	elif Settings.cli.has("flight-test"):
		var ft: Node = load("res://tests/flight_test.gd").new()
		ft.name = "FlightTest"
		add_child(ft)
	elif Settings.cli.has("screenshots"):
		var sc: Node = load("res://tests/screenshots.gd").new()
		sc.name = "Screenshots"
		add_child(sc)


func _unhandled_input(ev: InputEvent) -> void:
	if ev is InputEventKey and ev.pressed and not ev.echo:
		var k := ev as InputEventKey
		if k.keycode == KEY_ESCAPE and k.shift_pressed:
			Game.quit_game()
		elif k.keycode == KEY_END and k.shift_pressed:   # Shift+End: dev <-> cockpit layout
			Settings.set_v("display", "mode", "cockpit" if display.mode == "dev" else "dev")
			display.apply_layout()
