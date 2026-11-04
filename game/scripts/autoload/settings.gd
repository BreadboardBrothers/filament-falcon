extends Node
## Persistent settings stored in user://falcon_settings.cfg
## (on Linux: ~/.local/share/filament-falcon/falcon_settings.cfg).
## Command-line overrides (after `--`): --dev, --cockpit, --quality=low|medium|high|ultra,
## --mission=<id>, --no-voice, --no-led, --no-ics, --ics-mock, --virtual-panels, --smoke-test,
## --screenshots=<dir>, --eva-vr (also launch the VR spacewalk client), --eva-client (that client)

signal changed(section: String)

const PATH := "user://falcon_settings.cfg"
const QUALITY_LEVELS := ["low", "medium", "high", "ultra"]

const DEFAULTS := {
	"display": {
		"mode": "auto",            # auto | cockpit | dev
		# Four screen roles: left/right windows, kids' console (touch), commander.
		# <role>_output = output name from `xrandr --listmonitors` (wins when present),
		# <role>_screen = Godot screen index; -1 / "" = automatic (see DisplayManager).
		"left_output": "",
		"right_output": "",
		"console_output": "DisplayPort-0",
		"commander_output": "",
		"left_screen": -1,
		"right_screen": -1,
		"console_screen": -1,
		"commander_screen": -1,
		"layout_version": 2,
		"fullscreen": true,
		"monitor_width_m": 0.597,  # 27" 16:9 panel width
		"monitor_height_m": 0.336,
		"monitor_gap_m": 0.06,     # bezel-to-bezel gap between the two monitors
		"eye_distance_m": 0.62,    # eye point to monitor plane
		"eye_height_m": 0.0,       # eye above (+) / below (-) monitor centre
		"toe_in_deg": 0.0,         # each monitor angled toward the centre
		"view_scale": 1.15,        # >1 widens the field of view a little for drama
		# Frame pacing. The two side monitors run at different refresh rates (144 Hz and 75 Hz)
		# and the console at 60 Hz. One render loop drives all windows, so we cap the loop at
		# max_fps and present every window with MAILBOX vsync (no tearing, never blocks on
		# the slowest screen). Set the 144 Hz panel to 75 Hz with xrandr for perfectly even pacing.
		"max_fps": 75,
		"vsync": "mailbox",        # mailbox | fifo | off
		# Out-the-window outputs (in order). Each one gets its own camera, off-axis frustum
		# and optional post-warp shader (for a future projector dome: per-output warp mesh/shader).
		"views": "left,right",
		"left_warp": "",           # res:// or absolute path to a canvas_item .gdshader, "" = none
		"right_warp": "",
	},
	"graphics": {"quality": "high", "earth_month": 7},   # earth_month: Blue Marble month 1-12 (seasons)
	"audio": {"master_db": 0.0, "voice": true, "voice_engine": "auto", "piper_model": ""},
	"led": {"enabled": true, "udp_port": 47800, "serial_port": "auto", "brightness": 160},
	"game": {"start_mission": "launch", "difficulty": "normal", "skip_checklist": false,
		"home_lat": 45.9636, "home_lon": -66.6431},   # CITY LIGHTS: our house (default: downtown Fredericton)
	"ground": {"port": 8088},                         # GROUND CREW phone page: http://<pc>:8088
	# Virtual panels: on-screen copies of a Falcon board's controls appear while that board is
	# unplugged. force_virtual_panels shows them even with the boards connected (demo / testing).
	"input": {"force_virtual_panels": false},
	# Read-only crew-position senses on Falcon Command (the actuators are hardwired, see SPEC).
	# travel_s = how long one motion takes (pod or cradle, ~35-40 s); up_sense = whether the
	# optional POD_UP_LOCKED contact is wired: auto (yes once it has been seen closed) | yes | no.
	"pod": {"travel_s": 40.0, "up_sense": "auto", "callouts": true},
	# Intercom (tools/falcon_ics.py). <seat>_headset = "product|serial|usb-path" picked on
	# Commander > ICS. Per seat: mode vox|ptt, vox_db threshold, attack_ms, hang_ms, game_vol,
	# ics_vol, sidetone (0 = off), mic_gain. Global radio effect toggles.
	"ics": {
		"enabled": true, "udp_port": 47810, "game_port": 47811,
		"pilot_headset": "", "ops_headset": "", "commander_headset": "",
		# per-station INPUT / OUTPUT override: "" = the seat's headset, "none", "default",
		# or "node@bus=<usb path>" (older saves: "node@port=<short port>" or a bare node name)
		"pilot_in": "", "pilot_out": "", "ops_in": "", "ops_out": "", "commander_in": "", "commander_out": "", "eva_in": "", "eva_out": "",
		"radio_fx": true, "static": true, "squelch_tail": true, "beeps": true, "speakers": true,
		"mc_vol": 0.9, "allcall_duck": 0.25,
		"pilot_mode": "vox", "pilot_vox_db": -38.0, "pilot_attack_ms": 15.0, "pilot_hang_ms": 600.0,
		"pilot_game_vol": 0.7, "pilot_ics_vol": 1.0, "pilot_sidetone": 0.0, "pilot_mic_gain": 1.0,
		"ops_mode": "vox", "ops_vox_db": -38.0, "ops_attack_ms": 15.0, "ops_hang_ms": 600.0,
		"ops_game_vol": 0.7, "ops_ics_vol": 1.0, "ops_sidetone": 0.0, "ops_mic_gain": 1.0,
		"commander_mode": "ptt", "commander_vox_db": -38.0, "commander_attack_ms": 15.0, "commander_hang_ms": 600.0,
		"commander_game_vol": 0.7, "commander_ics_vol": 1.0, "commander_sidetone": 0.0, "commander_mic_gain": 1.0,
		# 4th seat: the VR spacewalker (Quest 3 audio through WiVRn's virtual sink / mic source)
		"eva_headset": "",
		"eva_mode": "vox", "eva_vox_db": -36.0, "eva_attack_ms": 15.0, "eva_hang_ms": 700.0,
		"eva_game_vol": 0.6, "eva_ics_vol": 1.0, "eva_sidetone": 0.15, "eva_mic_gain": 1.0,
	},
	# Spacewalks (docs/game/VR_SETUP.md). mode: auto (VR when the headset client is connected,
	# else on screen) | vr | flat. The VR client is a 2nd process of this game talking UDP on
	# localhost:port. in_missions inserts a SPACEWALK objective into missions that have one.
	"eva": {
		"port": 47820, "mode": "auto", "tether_m": 20.0, "reel_speed": 0.3, "in_missions": false,
		"xr_runtime_json": "",      # "" = system active runtime (WiVRn sets it while connected)
		"vr_quality": "medium",     # graphics quality inside the headset
		"snap_deg": 30.0, "vignette": 0.7, "play_height": "standing",   # standing | seated
	},
}

var cfg := ConfigFile.new()
var cli := {}


func _enter_tree() -> void:
	_parse_cli()
	var err := cfg.load(PATH)
	if err != OK:
		cfg = ConfigFile.new()
	var old_layout := err == OK and int(cfg.get_value("display", "layout_version", 1)) < 2
	for section in DEFAULTS:
		for key in DEFAULTS[section]:
			if not cfg.has_section_key(section, key):
				cfg.set_value(section, key, DEFAULTS[section][key])
	# v0.1 saved fixed screen numbers (left 1, right 2, console 0); v2 assigns roles automatically
	if old_layout:
		for r in ["left", "right", "console", "commander"]:
			cfg.set_value("display", r + "_screen", -1)
		cfg.set_value("display", "layout_version", 2)
		if FileAccess.file_exists(PATH) and not is_test_run():
			cfg.save(PATH)
	if cli.has("quality"):
		cfg.set_value("graphics", "quality", cli["quality"])
	if cli.has("dev"):
		cfg.set_value("display", "mode", "dev")
	if cli.has("cockpit"):
		cfg.set_value("display", "mode", "cockpit")
	if cli.has("no-voice") or is_test_run():
		cfg.set_value("audio", "voice", false)
	if cli.has("no-led") or is_test_run():
		cfg.set_value("led", "enabled", false)
	if cli.has("no-ics") or (is_test_run() and not cli.has("ics-mock")):
		cfg.set_value("ics", "enabled", false)
	if cli.has("virtual-panels"):
		cfg.set_value("input", "force_virtual_panels", true)
	if is_test_run():
		cfg.set_value("eva", "in_missions", false)
	if is_eva_client():
		# the headset process: no LEDs, intercom, voice or settings writes (the cockpit owns them)
		cfg.set_value("audio", "voice", false)
		cfg.set_value("led", "enabled", false)
		cfg.set_value("ics", "enabled", false)
		if cli.has("quality"):
			cfg.set_value("graphics", "quality", cli["quality"])
		else:
			cfg.set_value("graphics", "quality", cfg.get_value("eva", "vr_quality", "medium"))


func is_eva_client() -> bool:
	return cli.has("eva-client")


func _parse_cli() -> void:
	for a in OS.get_cmdline_user_args():
		var s: String = a
		s = s.trim_prefix("--")
		var eq := s.find("=")
		if eq >= 0:
			cli[s.substr(0, eq)] = s.substr(eq + 1)
		else:
			cli[s] = true


func is_test_run() -> bool:
	return cli.has("smoke-test") or cli.has("flight-test") or cli.has("screenshots")


func is_headless() -> bool:
	return DisplayServer.get_name() == "headless"


func get_v(section: String, key: String) -> Variant:
	return cfg.get_value(section, key, DEFAULTS.get(section, {}).get(key))


func set_v(section: String, key: String, value: Variant, save_now: bool = true) -> void:
	cfg.set_value(section, key, value)
	if save_now:
		save()
	changed.emit(section)


func save() -> void:
	if is_eva_client():
		return
	if is_test_run():
		return
	cfg.save(PATH)


func quality() -> String:
	var q: String = str(get_v("graphics", "quality"))
	return q if q in QUALITY_LEVELS else "high"


func quality_index() -> int:
	return QUALITY_LEVELS.find(quality())


## Repo root (the folder that contains game/ and shared/), when running from source.
func repo_root() -> String:
	return ProjectSettings.globalize_path("res://").path_join("..").simplify_path()


## Path to a file in the repo's shared/ contract folder (override with --shared-dir=/path).
func shared_file(file_name: String) -> String:
	if cli.has("shared-dir"):
		return str(cli["shared-dir"]).path_join(file_name)
	return repo_root().path_join("shared").path_join(file_name)
