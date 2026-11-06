class_name DisplayManager
extends Node
## Owns the four screen roles and maps them to physical monitors.
## - LEFT / RIGHT: forward windows. Both cameras share the ship eye point and use
##   asymmetric (off-axis) frusta computed from the real monitor geometry, so the two
##   monitors read as one continuous windscreen (the bezel gap is a real "window post").
##   Chase view (Game.view_mode=1) keeps those frusta but yaws the shared eye so the
##   rocket clears the bezel seam (see chase_bezel_bias / chase_bezel_clear_m).
## - CONSOLE: the kids' touchscreen instrument panel (ConsoleUI), landscape or portrait.
## - COMMANDER: the grown-up's screen (CommanderUI). With only three screens it becomes a
##   tab on the console (Escape toggles it).
## Cockpit mode: one OS window per screen (fullscreen). Dev mode: all four tiled in one window.
##
## Which monitor gets which role: per role, `display/<role>_output` (an output name such as
## "DisplayPort-0", from `xrandr --listmonitors`) wins, then `display/<role>_screen` (Godot
## screen index), else automatic: the ~22" panel (or a portrait one) is the console, the
## biggest remaining one is the Commander when there are enough screens, and the rest are the
## windows from left to right. The SETUP page on the Commander screen edits these.
##
## The out-the-window outputs are generic: `out_views` (from settings display/views) lists
## them, and each is described by a physical screen rectangle in eye space
## (`screen_rect_for`), from which a generic off-axis frustum is built (`off_axis`).
## Adding more outputs (e.g. three projectors on a dome) means: add names to display/views,
## teach `screen_rect_for` their geometry, and set display/<name>_warp to a canvas_item
## shader that pre-distorts that output for the dome (the hook is already wired below).

const ROLES := ["left", "right", "console", "commander"]
const ROLE_NAMES := {"left": "LEFT WINDOW", "right": "RIGHT WINDOW", "console": "KIDS' CONSOLE", "commander": "COMMANDER"}

var NEAR := 1.0     # far/near must stay <= ~1e6 (float32 frustum planes)
var FAR := 1.0e6
## During a spacewalk the astronaut's glove can touch the canopy ~0.6-1.0 m from the eye, so the
## window cameras pull their near plane in (the frustum keeps the same shape).
var EVA_NEAR := 0.2
var near_now := 1.0

var world: WorldView
var vp := {}            # name -> SubViewport
var cont := {}          # name -> SubViewportContainer
var cams := {}          # "left"/"right" -> Camera3D
var huds := {}
var console: ConsoleUI
var commander: CommanderUI
var windows: Array[Window] = []
var mode := "dev"
var dev_root: Control
var out_views: Array[String] = []   # out-the-window outputs, e.g. ["left", "right"]
var solo_view := ""                 # screenshot helper: this view gets a centred, forward frustum
var solo_true := false              # ...unless set: keep the real (off-axis) window frustum
var monitors: Array = []            # [{i, name, pos, size, mm, diag, hz}]
var assign := {}                    # role -> screen index (-1 = none)
var reasons := {}                   # role -> "auto" | "output" | "screen" | ""
var commander_embedded := false
var _esc_was := false
var _no_input_hint := false         # WM_HINTS input=False currently set on the console window
var _touch_wins: Array[Window] = []  # windows whose touches trigger the cursor keeper
var _nudge_due := -1.0               # when to nudge the mouse pointer back into view (ms, -1 none)
var _nudge_last := -1e9
var _mouse_check_t := 0.0


func setup(w: WorldView) -> void:
	world = w
	if Settings.cli.has("far"):
		FAR = float(Settings.cli["far"])
	if Settings.cli.has("near"):
		NEAR = float(Settings.cli["near"])
	if Settings.cli.has("eva-near"):
		EVA_NEAR = float(Settings.cli["eva-near"])
	near_now = NEAR
	out_views.clear()
	for n0 in str(Settings.get_v("display", "views")).split(",", false):
		var nn: String = n0.strip_edges()
		if nn != "" and nn != "console" and nn != "commander" and not out_views.has(nn):
			out_views.append(nn)
	if out_views.is_empty():
		out_views = ["left", "right"]
	Engine.max_fps = int(Settings.get_v("display", "max_fps"))
	var all_views: Array[String] = out_views.duplicate()
	all_views.append("console")
	all_views.append("commander")
	for n: String in all_views:
		var c := SubViewportContainer.new()
		c.name = n.capitalize() + "View"
		c.stretch = true
		var v := SubViewport.new()
		v.name = n.capitalize() + "Viewport"
		v.size_2d_override = Vector2i(1920, 1080)
		v.size_2d_override_stretch = true
		v.handle_input_locally = false
		v.audio_listener_enable_3d = false
		c.add_child(v)
		vp[n] = v
		cont[n] = c
		if n == "console":
			v.transparent_bg = false
			console = ConsoleUI.new()
			console.name = "Console"
			console.display = self
			console.set_anchors_preset(Control.PRESET_FULL_RECT)
			v.add_child(console)
		elif n == "commander":
			v.transparent_bg = false
			commander = CommanderUI.new()
			commander.name = "Commander"
			commander.display = self
			commander.set_anchors_preset(Control.PRESET_FULL_RECT)
			v.add_child(commander)
		else:
			var cam := Camera3D.new()
			cam.name = "Camera"
			cam.projection = Camera3D.PROJECTION_FRUSTUM
			cam.keep_aspect = Camera3D.KEEP_HEIGHT
			cam.near = NEAR
			cam.far = FAR
			cam.cull_mask = 0xFFFFF
			v.add_child(cam)
			cam.current = true
			cams[n] = cam
			var hud := Hud.new()
			hud.name = "Hud"
			hud.side = -1 if n == "left" else 1
			_apply_warp(n)
			hud.cam = cam
			hud.set_anchors_preset(Control.PRESET_FULL_RECT)
			v.add_child(hud)
			huds[n] = hud
	apply_quality()
	apply_layout()
	Settings.changed.connect(func(section: String) -> void:
		if section == "graphics":
			apply_quality()
		elif section == "display":
			Engine.max_fps = int(Settings.get_v("display", "max_fps"))
			resolve_roles())


func role_list() -> Array[String]:
	var r: Array[String] = out_views.duplicate()
	r.append("console")
	r.append("commander")
	return r


func resolved_mode() -> String:
	var m: String = str(Settings.get_v("display", "mode"))
	if m == "auto":
		m = "cockpit" if DisplayServer.get_screen_count() >= 3 and not Settings.is_headless() and not Settings.is_test_run() else "dev"
	return m


# ======================================================================== monitors + roles
## Godot screens, with output names and physical size from `xrandr --listmonitors` when
## available (X11), else physical size from the screen DPI.
func detect_monitors() -> void:
	monitors.clear()
	var xr := _xrandr_monitors()
	for i in DisplayServer.get_screen_count():
		var pos := DisplayServer.screen_get_position(i)
		var sz := DisplayServer.screen_get_size(i)
		# (refresh rate comes from XRandR; skip it when XRandR sees fewer outputs, e.g. Xvfb + Xinerama)
		var hz := DisplayServer.screen_get_refresh_rate(i) if xr.size() >= DisplayServer.get_screen_count() or OS.get_name() != "Linux" else -1.0
		var m := {"i": i, "name": "", "pos": pos, "size": sz, "mm": Vector2.ZERO, "hz": hz}
		for x: Dictionary in xr:
			if x["pos"] == pos and x["size"] == sz:
				m["name"] = x["name"]
				m["mm"] = x["mm"]
		if (m["mm"] as Vector2) == Vector2.ZERO:
			var dpi := DisplayServer.screen_get_dpi(i)
			if dpi > 20:
				m["mm"] = Vector2(sz) / float(dpi) * 25.4
		m["diag"] = (m["mm"] as Vector2).length() / 25.4
		monitors.append(m)


func _xrandr_monitors() -> Array:
	var out: Array = []
	if OS.get_name() != "Linux" or Settings.is_headless() or Settings.is_test_run():
		return out
	var lines: Array = []
	if OS.execute("xrandr", ["--listmonitors"], lines) != 0 or lines.is_empty():
		return out
	out = parse_xrandr(str(lines[0]))
	return out


## Parses `xrandr --listmonitors` lines like " 2: +DisplayPort-0 1080/480x1920/270+3271+1080  DisplayPort-0".
static func parse_xrandr(text: String) -> Array:
	var out: Array = []
	var re := RegEx.new()
	re.compile("^\\s*\\d+:\\s+[+*]*(\\S+)\\s+(\\d+)/(\\d+)x(\\d+)/(\\d+)\\+(-?\\d+)\\+(-?\\d+)")
	for line in text.split("\n"):
		var mt := re.search(line)
		if mt == null:
			continue
		out.append({"name": mt.get_string(1), "size": Vector2i(int(mt.get_string(2)), int(mt.get_string(4))),
			"mm": Vector2(float(mt.get_string(3)), float(mt.get_string(5))), "pos": Vector2i(int(mt.get_string(6)), int(mt.get_string(7)))})
	return out


func monitor_name(i: int) -> String:
	for m: Dictionary in monitors:
		if int(m["i"]) == i:
			return str(m["name"])
	return ""


func _setting_str(key: String) -> String:
	var v: Variant = Settings.get_v("display", key)
	return "" if v == null else str(v)


func _setting_int(key: String, def: int) -> int:
	var v: Variant = Settings.get_v("display", key)
	return def if v == null else int(v)


## Decide which screen each role uses (see the header comment for the rules).
func resolve_roles() -> void:
	if monitors.is_empty():
		detect_monitors()
	assign.clear()
	reasons.clear()
	var n := monitors.size()
	var used := {}
	for role: String in role_list():
		assign[role] = -1
		reasons[role] = ""
		var out := _setting_str(role + "_output")
		var idx := _setting_int(role + "_screen", -1)
		if out != "":
			for m: Dictionary in monitors:
				if str(m["name"]) == out:
					assign[role] = int(m["i"])
					reasons[role] = "output"
		if int(assign[role]) < 0 and idx >= 0 and idx < n:
			assign[role] = idx
			reasons[role] = "screen"
		if int(assign[role]) >= 0:
			used[int(assign[role])] = true
	var free: Array = []
	for m: Dictionary in monitors:
		if not used.has(int(m["i"])):
			free.append(m)
	# console: the ~22" panel, else a portrait one, else the lowest screen
	if int(assign["console"]) < 0 and not free.is_empty():
		var best: Dictionary = {}
		var best_score := 1e9
		for m: Dictionary in free:
			var d := float(m["diag"])
			var sz: Vector2i = m["size"]
			var score := absf(d - 22.0) if d > 18.0 and d < 24.5 else 100.0
			if sz.y > sz.x:
				score = minf(score, 50.0)
			score -= float((m["pos"] as Vector2i).y) * 0.001
			if score < best_score:
				best_score = score
				best = m
		if best_score < 99.0 or free.size() > out_views.size():
			if best_score >= 99.0:
				# no size hint: the lowest screen (the console sits below the windows)
				for m: Dictionary in free:
					if (m["pos"] as Vector2i).y > (best["pos"] as Vector2i).y:
						best = m
			assign["console"] = int(best["i"])
			reasons["console"] = "auto"
			free.erase(best)
	# commander: only if there is a screen to spare beyond the windows; the biggest one
	var need_out := 0
	for v in out_views:
		if int(assign[v]) < 0:
			need_out += 1
	if int(assign["commander"]) < 0 and free.size() > need_out:
		var big: Dictionary = free[0]
		for m: Dictionary in free:
			if float(m["diag"]) > float(big["diag"]) + 0.5:
				big = m
		assign["commander"] = int(big["i"])
		reasons["commander"] = "auto"
		free.erase(big)
	# windows: left to right
	free.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var pa: Vector2i = a["pos"]
		var pb: Vector2i = b["pos"]
		return pa.x < pb.x or (pa.x == pb.x and pa.y < pb.y))
	for v in out_views:
		if int(assign[v]) < 0 and not free.is_empty():
			assign[v] = int(free[0]["i"])
			reasons[v] = "auto"
			free.remove_at(0)


func screen_of(role: String) -> int:
	if assign.is_empty():
		resolve_roles()
	return int(assign.get(role, -1))


## Setup page: cycle a role through AUTO, screen 0, 1, ... (stored by output name when known).
func cycle_role_screen(role: String, d: int) -> void:
	detect_monitors()
	var n := monitors.size()
	var cur := -1
	var out := _setting_str(role + "_output")
	if out != "":
		for m: Dictionary in monitors:
			if str(m["name"]) == out:
				cur = int(m["i"])
	elif _setting_int(role + "_screen", -1) >= 0:
		cur = _setting_int(role + "_screen", -1)
	var nxt := posmod(cur + 1 + d, n + 1) - 1
	var nm := monitor_name(nxt) if nxt >= 0 else ""
	Settings.set_v("display", role + "_output", nm, false)
	Settings.set_v("display", role + "_screen", -1 if nm != "" else nxt)


func _mon_text(i: int) -> String:
	for m: Dictionary in monitors:
		if int(m["i"]) == i:
			var sz: Vector2i = m["size"]
			return "#%d %s %d\" %dx%d%s" % [i, str(m["name"]), int(round(float(m["diag"]))), sz.x, sz.y, " portrait" if sz.y > sz.x else ""]
	return "#%d" % i


func describe_role(role: String) -> String:
	if mode != "cockpit":
		return "dev layout: tile   (cockpit: %s)" % _describe_cockpit(role)
	return _describe_cockpit(role)


func _describe_cockpit(role: String) -> String:
	var i := screen_of(role)
	var how := {"auto": "AUTO → ", "output": "", "screen": ""}.get(str(reasons.get(role, "")), "") as String
	if i < 0:
		if role == "commander":
			return "AUTO → tab on the kids' console (Esc)"
		return "not shown (no screen left)"
	return how + _mon_text(i)


func describe_monitors() -> String:
	if monitors.is_empty():
		detect_monitors()
	var s := "Screens detected: %d\n" % monitors.size()
	for m: Dictionary in monitors:
		var hz := float(m["hz"])
		s += "  %s%s at %s\n" % [_mon_text(int(m["i"])), ("  @ %.0f Hz" % hz) if hz > 0.0 else "", str(m["pos"])]
	return s


func layout_summary() -> String:
	var s := mode
	for r: String in role_list():
		s += "\n  %s: %s" % [ROLE_NAMES.get(r, r.to_upper()), describe_role(r) if mode == "cockpit" else "tile"]
	return s


## Remember the resolved output names for game/tools/setup_displays.sh (touch mapping).
func _write_role_env() -> void:
	if Settings.is_test_run():
		return
	var f := FileAccess.open("user://displays.env", FileAccess.WRITE)
	if f == null:
		return
	f.store_line("# Written by the game at start-up: which output each role uses (read by tools/setup_displays.sh)")
	for r: String in role_list():
		f.store_line("%s_OUTPUT=%s" % [r.to_upper(), monitor_name(screen_of(r))])


# ======================================================================== layout
func apply_layout() -> void:
	mode = resolved_mode()
	detect_monitors()
	resolve_roles()
	console.release_commander()
	commander_embedded = false
	for c in cont.values():
		var cc: Control = c
		if cc.get_parent():
			cc.get_parent().remove_child(cc)
		cc.visible = true
	for w in windows:
		w.queue_free()
	windows.clear()
	if dev_root:
		dev_root.queue_free()
		dev_root = null
	var root_win := get_window()
	(vp["console"] as SubViewport).size_2d_override = Vector2i(1920, 1080)
	if mode == "cockpit":
		_write_role_env()
		var fs := bool(Settings.get_v("display", "fullscreen"))
		var cs := screen_of("console")
		if cs < 0:
			cs = 0
		var csz := DisplayServer.screen_get_size(cs)
		if csz.y > csz.x:
			(vp["console"] as SubViewport).size_2d_override = Vector2i(1080, 1920)   # portrait panel
		_place_window(root_win, cs, fs)
		var host := Control.new()
		host.set_anchors_preset(Control.PRESET_FULL_RECT)
		get_parent().add_child.call_deferred(host)
		dev_root = host
		host.add_child(cont["console"])
		cont["console"].set_anchors_preset(Control.PRESET_FULL_RECT)
		var win_roles: Array[String] = out_views.duplicate()
		var commander_win: Window = null
		if screen_of("commander") >= 0:
			win_roles.append("commander")
		else:
			commander_embedded = true
			console.embed_commander(cont["commander"])
		for n: String in win_roles:
			var scr := screen_of(n)
			if scr < 0:
				push_warning("display: no screen for %s" % n)
				continue
			var w := Window.new()
			w.title = "Filament Falcon - " + str(ROLE_NAMES.get(n, n.to_upper()))
			w.borderless = true
			w.unresizable = false
			Game.hook_window(w)     # close / Alt+F4 on any window quits the whole game cleanly
			get_parent().add_child.call_deferred(w)
			w.add_child(cont[n])
			cont[n].set_anchors_preset(Control.PRESET_FULL_RECT)
			windows.append(w)
			_place_window.call_deferred(w, scr, fs)
			if n == "commander":
				commander_win = w
		_guard_touch_focus.call_deferred(root_win, commander_win)
		print("display: cockpit layout on %d screens" % monitors.size())
		for r: String in role_list():
			print("  %-14s %s" % [str(ROLE_NAMES.get(r, r)), _describe_cockpit(r)])
	else:
		_guard_touch_focus(root_win, null)
		if root_win.mode == Window.MODE_FULLSCREEN or root_win.mode == Window.MODE_EXCLUSIVE_FULLSCREEN:
			root_win.mode = Window.MODE_WINDOWED
		_apply_vsync(root_win)
		dev_root = Control.new()
		dev_root.name = "DevTiles"
		dev_root.set_anchors_preset(Control.PRESET_FULL_RECT)
		var bg := ColorRect.new()
		bg.color = Color(0.02, 0.03, 0.05)
		bg.set_anchors_preset(Control.PRESET_FULL_RECT)
		dev_root.add_child(bg)
		for n: String in cont:
			dev_root.add_child(cont[n])
		get_parent().add_child.call_deferred(dev_root)
		dev_root.resized.connect(_layout_tiles)
		_layout_tiles.call_deferred()


## Touchscreen focus guard. When the Commander has its own screen, the KIDS' CONSOLE window never
## takes keyboard focus: Godot's click-to-focus is off (unfocusable) and the window manager is told
## the window takes no input (tools/x11_no_input_hint.py, ICCCM WM_HINTS). A tap on the panel then
## leaves keyboard focus (shortcuts, Alt+F4) on the Commander. Taps and drags still work. run.sh's
## tools/touch_isolate.sh keeps the touchscreen off the mouse pointer. FALCON_TOUCH_ISOLATE=0 turns
## both off. With the Commander embedded in the console, the console keeps normal focus.
func _guard_touch_focus(console_win: Window, commander_win: Window) -> void:
	var on := commander_win != null and touch_guard_enabled()
	if console_win.unfocusable != on:
		console_win.unfocusable = on
	if DisplayServer.get_name() == "X11" and on != _no_input_hint:
		var xid := DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE, console_win.get_window_id())
		if xid != 0:
			var args := PackedStringArray([ProjectSettings.globalize_path("res://tools/x11_no_input_hint.py"), str(xid)])
			if not on:
				args.append("--restore")
			if OS.create_process("python3", args) > 0:
				_no_input_hint = on
	if on:
		commander_win.grab_focus()
		print("display: touch focus guard on (console window never takes keyboard focus)")
	_watch_touch(console_win)
	_watch_touch(get_tree().root)


## Cursor keeper. Nothing in the game ever hides or captures the mouse (mouse_mode stays
## VISIBLE, re-asserted after touches and once a second). But Cinnamon / GNOME hide the cursor
## screen-wide when the last-used device is a touchscreen and show it again only when the core
## pointer switches to a mouse, which no longer happens once touch_isolate.sh moved the
## touchscreen off the core pointer. So after a touch, tools/x11_show_cursor.py nudges the core
## pointer 1 px and back via XTEST (at most once a second, trailing): the window manager sees a
## "mouse" and shows the cursor again. FALCON_CURSOR_NUDGE=0 turns the nudge off.
func _watch_touch(w: Window) -> void:
	if w == null or w in _touch_wins:
		return
	_touch_wins.append(w)
	w.window_input.connect(_on_window_input)


func _on_window_input(ev: InputEvent) -> void:
	if ev is InputEventScreenTouch or ev is InputEventScreenDrag:
		_keep_mouse_visible()
		if ev is InputEventScreenTouch and not (ev as InputEventScreenTouch).pressed and cursor_nudge_enabled():
			_nudge_due = Time.get_ticks_msec() + 80.0


func _keep_mouse_visible() -> void:
	if Input.mouse_mode != Input.MOUSE_MODE_VISIBLE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _cursor_keeper(dt: float) -> void:
	_mouse_check_t += dt
	if _mouse_check_t >= 1.0:
		_mouse_check_t = 0.0
		_keep_mouse_visible()
	var now := float(Time.get_ticks_msec())
	if _nudge_due >= 0.0 and now >= _nudge_due and now - _nudge_last >= 1000.0:
		_nudge_due = -1.0
		_nudge_last = now
		OS.create_process("python3", PackedStringArray([ProjectSettings.globalize_path("res://tools/x11_show_cursor.py")]))


static func cursor_nudge_enabled() -> bool:
	if DisplayServer.get_name() != "X11" or not touch_guard_enabled():
		return false
	var v := OS.get_environment("FALCON_CURSOR_NUDGE").strip_edges().to_lower()
	return not (v in ["0", "off", "no", "false"])


static func touch_guard_enabled() -> bool:
	if DisplayServer.get_name() == "headless":
		return false
	var v := OS.get_environment("FALCON_TOUCH_ISOLATE").strip_edges().to_lower()
	return not (v in ["0", "off", "no", "false"])


func _place_window(w: Window, screen: int, fullscreen: bool) -> void:
	screen = clampi(screen, 0, DisplayServer.get_screen_count() - 1)
	var pos := DisplayServer.screen_get_position(screen)
	var size := DisplayServer.screen_get_size(screen)
	w.mode = Window.MODE_WINDOWED
	w.position = pos
	w.size = size
	w.current_screen = screen
	if fullscreen:
		w.mode = Window.MODE_FULLSCREEN
	w.show()
	_apply_vsync(w)


## Per-window vsync. MAILBOX = no tearing and no blocking, so a 144 Hz, a 75 Hz and a 60 Hz
## screen can all be fed from one loop (capped by Engine.max_fps) without stutter.
func _apply_vsync(w: Window) -> void:
	if Settings.is_headless():
		return
	var m := DisplayServer.VSYNC_MAILBOX
	match str(Settings.get_v("display", "vsync")):
		"fifo":
			m = DisplayServer.VSYNC_ENABLED
		"off":
			m = DisplayServer.VSYNC_DISABLED
	DisplayServer.window_set_vsync_mode(m, w.get_window_id())


func apply_vsync_all() -> void:
	_apply_vsync(get_window())
	for w in windows:
		_apply_vsync(w)


## Optional per-output post-warp (projector dome later). Empty setting = none.
func _apply_warp(n: String) -> void:
	var path := str(Settings.get_v("display", n + "_warp")) if Settings.get_v("display", n + "_warp") != null else ""
	var c: SubViewportContainer = cont[n]
	c.material = null
	if path == "" or path == "<null>":
		return
	var sh: Shader = load(path) if ResourceLoader.exists(path) else null
	if sh == null:
		push_warning("warp shader not found for %s: %s" % [n, path])
		return
	var mat := ShaderMaterial.new()
	mat.shader = sh
	c.material = mat


## Dev mode: windows across the top, console and Commander side by side underneath.
func _layout_tiles() -> void:
	if dev_root == null:
		return
	var s := dev_root.size
	if s.x < 10:
		s = Vector2(get_window().size)
	var nv := out_views.size()
	var tile_w := floorf(s.x / nv)
	var top_h := minf(floorf(tile_w * 9.0 / 16.0), floorf(s.y * 0.5))
	for i in nv:
		var c: Control = cont[out_views[i]]
		c.position = Vector2(i * tile_w + 2, 0)
		c.size = Vector2(tile_w - 4, top_h)
	var ch := s.y - top_h - 4
	var cw := minf(ch * 16.0 / 9.0, s.x * 0.5 - 4)
	ch = cw * 9.0 / 16.0
	var x0 := (s.x - cw * 2.0 - 4.0) * 0.5
	(cont["console"] as Control).position = Vector2(x0, top_h + 4)
	(cont["console"] as Control).size = Vector2(cw, ch)
	(cont["commander"] as Control).position = Vector2(x0 + cw + 4, top_h + 4)
	(cont["commander"] as Control).size = Vector2(cw, ch)


func apply_quality() -> void:
	var q := Settings.quality_index()
	for n: String in out_views:
		var v: SubViewport = vp[n]
		v.msaa_3d = [Viewport.MSAA_DISABLED, Viewport.MSAA_2X, Viewport.MSAA_4X, Viewport.MSAA_4X][q]
		v.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA if q <= 1 else Viewport.SCREEN_SPACE_AA_DISABLED
		v.use_taa = q >= 3
		v.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR if q == 0 else Viewport.SCALING_3D_MODE_BILINEAR
		v.scaling_3d_scale = 0.67 if q == 0 else 1.0
		v.use_debanding = true
		v.mesh_lod_threshold = [4.0, 2.0, 1.0, 0.5][q]
		v.positional_shadow_atlas_size = [1024, 2048, 4096, 4096][q]
	if world:
		world.apply_quality()


## Physical screen rectangle for one output, in eye space (metres; eye at origin,
## looking down -Z, +Y up): {"center": Vector3, "basis": Basis (rect's own axes;
## -Z = its normal toward the scene), "w": width, "h": height}.
## The two flat side monitors are built from the display settings; a projector dome
## would return one rectangle per projector's virtual image plane here.
func screen_rect_for(n: String) -> Dictionary:
	var W := float(Settings.get_v("display", "monitor_width_m"))
	var H := float(Settings.get_v("display", "monitor_height_m"))
	var gap := float(Settings.get_v("display", "monitor_gap_m"))
	var D := float(Settings.get_v("display", "eye_distance_m"))
	var eh := float(Settings.get_v("display", "eye_height_m"))
	var toe := deg_to_rad(float(Settings.get_v("display", "toe_in_deg")))
	var side := -1.0 if n == "left" else (1.0 if n == "right" else 0.0)
	var center := Vector3(side * (gap * 0.5 + W * 0.5 * cos(toe)) if side != 0.0 else 0.0, -eh, -D + (W * 0.5 * sin(toe) if side != 0.0 else 0.0))
	return {"center": center, "basis": Basis(Vector3.UP, -side * toe), "w": W, "h": H}


## Generic off-axis frustum through a screen rectangle.
## Returns [camera basis, size, offset] at the near plane (for Camera3D.set_frustum).
func off_axis(r: Dictionary) -> Array:
	var s := maxf(float(Settings.get_v("display", "view_scale")), 0.2)
	var yb: Basis = r["basis"]
	var cl: Vector3 = yb.inverse() * (r["center"] as Vector3)
	var dist := maxf(-cl.z, 0.05)
	var k := s * near_now / dist
	return [yb, float(r["h"]) * k, Vector2(cl.x, cl.y) * k]


## Back-compat helper: side = -1 (left) / +1 (right).
func frustum_for(side: int) -> Array:
	return off_axis(screen_rect_for("left" if side < 0 else "right"))


## Half-angle (rad) of the physical bezel gap as seen from the eye.
func bezel_half_angle() -> float:
	var gap := float(Settings.get_v("display", "monitor_gap_m"))
	var D := maxf(float(Settings.get_v("display", "eye_distance_m")), 0.05)
	return atan((gap * 0.5) / D)


## Yaw (rad) applied in chase mode so the look-at (rocket) clears the bezel.
## Positive = rocket frames toward the right panel. Zero when a single OTW view / solo shot.
func chase_bezel_yaw() -> float:
	if out_views.size() < 2:
		return 0.0
	if solo_view != "" and not solo_true:
		return 0.0  # centred screenshot frustum — keep rocket framed
	var gap := float(Settings.get_v("display", "monitor_gap_m"))
	var W := float(Settings.get_v("display", "monitor_width_m"))
	var D := maxf(float(Settings.get_v("display", "eye_distance_m")), 0.05)
	var clear := maxf(float(Settings.get_v("display", "chase_bezel_clear_m")), 0.0)
	var bias := clampf(float(Settings.get_v("display", "chase_bezel_bias")), -1.0, 1.0)
	if absf(bias) < 1e-4:
		return 0.0
	var side := 1.0 if bias >= 0.0 else -1.0
	var b := absf(bias)
	# Lateral metres on the monitor plane: past gap/2 + clear, then into the panel by bias.
	var x := side * (gap * 0.5 + clear + b * maxf(W * 0.5 - clear, 0.05))
	return atan(x / D)


## Eye-space X of a look direction after chase yaw (0 = optical centre / bezel).
func chase_look_x_on_plane(yaw: float = NAN) -> float:
	var y := chase_bezel_yaw() if is_nan(yaw) else yaw
	var D := maxf(float(Settings.get_v("display", "eye_distance_m")), 0.05)
	return tan(y) * D


## True when |x| on the monitor plane clears the bezel gap (with optional margin).
func clears_bezel(x_m: float, margin_m: float = 0.0) -> bool:
	var gap := float(Settings.get_v("display", "monitor_gap_m"))
	return absf(x_m) >= gap * 0.5 + margin_m


func _chase_rig_basis(rig: Transform3D) -> Transform3D:
	var yaw := chase_bezel_yaw()
	if absf(yaw) < 1e-6:
		return rig
	# Yaw around the chase camera's up so the look-at slides off the bezel seam.
	var up := rig.basis.y.normalized()
	if up.length_squared() < 1e-8:
		up = Vector3.UP
	return Transform3D(Basis(up, yaw) * rig.basis, rig.origin)


func _process(dt: float) -> void:
	# Escape: show/hide the Commander tab on the console (three-screen rigs)
	var esc := Input.is_physical_key_pressed(KEY_ESCAPE) and not Input.is_key_pressed(KEY_SHIFT)
	if esc and not _esc_was and commander_embedded:
		console.toggle_commander()
	_esc_was = esc
	_cursor_keeper(dt)
	if world == null:
		return
	near_now = minf(NEAR, EVA_NEAR) if Eva.active else NEAR
	var chase := Game.view_mode == 1
	var slew_cam := Game.slew.active and Game.slew.mode == "cam"
	var rig := world.rig_xform
	if chase and not slew_cam:
		rig = _chase_rig_basis(rig)
	for n: String in out_views:
		var cam: Camera3D = cams[n]
		var f := off_axis(screen_rect_for(n))
		if n == solo_view and not solo_true:
			# single-view screenshot: same field of view, but centred straight ahead
			f = [Basis.IDENTITY, f[1], Vector2.ZERO]
		cam.global_transform = rig * Transform3D(f[0], Vector3.ZERO)
		if Settings.cli.has("persp"):
			cam.set_perspective(70.0, near_now, FAR)
		else:
			cam.set_frustum(f[1], f[2], near_now, FAR)
		# Hide the Falcon's own hull from the cockpit eye point; chase / cam-slew must see it.
		cam.cull_mask = 0xFFFFF if (chase or slew_cam) else (0xFFFFF & ~WorldView.SHIP_LAYER)


## Screenshot / demo helper (dev mode only): show one view full-window, or "" for the tiles.
func solo(which: String) -> void:
	if mode != "dev":
		return
	solo_view = which
	if which == "":
		for n in cont:
			if (cont[n] as Control).get_parent() == dev_root:
				(cont[n] as Control).visible = true
		_layout_tiles()
		return
	for n in cont:
		var c: Control = cont[n]
		if c.get_parent() != dev_root:
			continue          # e.g. the Commander embedded as a console tab
		c.visible = (n == which)
		if n == which:
			c.position = Vector2.ZERO
			c.size = dev_root.size
