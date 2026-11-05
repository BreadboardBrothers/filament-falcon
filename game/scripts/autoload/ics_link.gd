extends Node
## Intercom (ICS) link. The multi-headset audio runs in tools/falcon_ics.py (Godot can only
## open one audio device); the game talks to it over localhost UDP, like the LED bridge:
##   game -> helper :47810  hello / cfg / state (PTT, ALL-CALL, mutes) / ident / rescan
##   helper -> game :47811  status (~15 Hz: levels, gate open, devices), devices list
## run.sh starts the helper before the game; if nothing answers, the game starts it itself.
## When the helper reports its "falcon_game" sink, the game moves its audio output there so
## engine, alarms and callouts reach every headset (and the room speakers, if enabled).
## Voice callouts go to the "falcon_mc" sink = the MISSION CONTROL channel (radio effect).
## Everything fails soft: no python3/numpy/pactl -> no intercom, the game runs as before.

signal status_changed
signal devices_changed
signal recorded(path: String, secs: float)    # Captain's Log WAV written by the helper

const SEATS := ["pilot", "ops", "commander", "eva"]
const SEAT_NAMES := {"pilot": "PILOT", "ops": "OPS", "commander": "COMMANDER", "eva": "SPACEWALKER"}
## The EVA seat has no cockpit key: the VR client keys it (left X/A button) via touch_ptt.
const PTT_ACTION := {"pilot": "ptt_pilot", "ops": "ptt_ops", "commander": "ptt_commander", "eva": ""}

var enabled := false
var mock := false
var helper_pid := -1
var status := {}               # last status from the helper
var inputs: Array = []         # [{name, desc, spec}] every mic / source
var outputs: Array = []        # every speaker / sink
var routes: Dictionary = {}    # seat -> [source, sink] actually opened
var devices: Array = []        # [{id, label, product, serial, path, sink, source}]
var assign := {}               # seat -> device id
var touch_ptt := {"pilot": false, "ops": false, "commander": false, "eva": false}
var touch_allcall := false
var mute := {"pilot": false, "ops": false, "commander": false, "eva": false}
var state_text := "off"
var _rx := PacketPeerUDP.new()
var _tx := PacketPeerUDP.new()
var _last_rx := -100.0
var _hello_t := 0.0
var _state_t := 0.0
var _sent_state := ""
var _start_tried := false
var _t0 := 0.0
var _routed := false
var _prev_device := "Default"
var _demo := false


func _ready() -> void:
	Settings.changed.connect(func(sec: String) -> void:
		if sec != "ics" or _demo:
			return
		var want := bool(Settings.get_v("ics", "enabled"))
		if want and not enabled:
			start(mock)                      # INTERCOM switched on at runtime
		elif not want and enabled:
			stop()
			state_text = "disabled"
		elif enabled:
			_send({"cmd": "cfg", "values": config_values()}))
	if bool(Settings.get_v("ics", "enabled")):
		start(Settings.cli.has("ics-mock"))
	else:
		state_text = "disabled"


## Bind the reply port and start talking to the helper (run.sh's, or our own after 1.5 s).
func start(use_mock: bool) -> void:
	if enabled:
		return
	mock = use_mock
	enabled = true
	_start_tried = false
	var port := int(Settings.get_v("ics", "game_port"))
	if _rx.bind(port, "127.0.0.1") != OK:
		state_text = "UDP port %d busy (another game running?)" % port
		enabled = false
		return
	_tx.set_dest_address("127.0.0.1", int(Settings.get_v("ics", "udp_port")))
	_t0 = _now()
	state_text = "waiting for the helper"
	_migrate_headset_to_io()
	_hello()


## Stop our helper (if we started it) and the link; the game keeps running without intercom.
func stop() -> void:
	if not enabled:
		return
	_send({"cmd": "quit"})
	if helper_pid > 0:
		OS.kill(helper_pid)
		helper_pid = -1
	_rx.close()
	enabled = false
	status = {}
	_last_rx = -100.0
	_route_audio()
	state_text = "stopped"


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


func config_values() -> Dictionary:
	var out := {}
	for k in Settings.DEFAULTS["ics"]:
		if k in ["udp_port", "game_port"]:
			continue
		out[k] = Settings.get_v("ics", k)
	return out


func _send(obj: Dictionary) -> void:
	if not enabled:
		return
	_tx.put_packet(JSON.stringify(obj).to_utf8_buffer())


## Captain's Log: the helper mixes the crew's (gated) headset voices into a WAV at `abs_path`.
func record_start(abs_path: String, max_s: float = 90.0) -> bool:
	if not ok():
		return false
	_send({"cmd": "record", "path": abs_path, "max_s": max_s})
	return true


func record_stop() -> void:
	_send({"cmd": "record_stop"})


func _hello() -> void:
	_send({"cmd": "hello", "pid": OS.get_process_id(), "values": config_values()})


## run.sh normally starts the helper; this is the fallback when the game is launched directly.
func _start_helper() -> void:
	_start_tried = true
	var script := ProjectSettings.globalize_path("res://tools/falcon_ics.py")
	if not FileAccess.file_exists(script):
		state_text = "helper script missing"
		return
	if OS.execute("sh", ["-c", "command -v python3"]) != 0:
		state_text = "python3 not found (intercom off)"
		return
	var logf := ProjectSettings.globalize_path("user://ics.log")
	var args := [script, "--parent-pid", str(OS.get_process_id()), "--port", str(Settings.get_v("ics", "udp_port")),
		"--game-port", str(Settings.get_v("ics", "game_port")), "--log", logf]
	if mock:
		args.append("--mock")
	helper_pid = OS.create_process("python3", args)
	state_text = "helper started (pid %d)" % helper_pid if helper_pid > 0 else "helper failed to start"


func connected() -> bool:
	return _demo or (enabled and _now() - _last_rx < 1.5)


func ok() -> bool:
	return connected() and bool(status.get("ok", false))


func seat(s: String) -> Dictionary:
	var seats: Dictionary = status.get("seats", {})
	return seats.get(s, {})


func keyed(s: String) -> bool:
	return bool(seat(s).get("open", false))


func ptt_down(s: String) -> bool:
	var act := str(PTT_ACTION.get(s, ""))
	return bool(touch_ptt.get(s, false)) or (act != "" and InputHub.on(act))


func allcall_down() -> bool:
	return touch_allcall or InputHub.on("all_call")


## Sink the voice callouts should go to ("" = default output): the MISSION CONTROL channel.
func mc_sink() -> String:
	return str(status.get("mc_sink", "")) if ok() and not _demo else ""


func set_cfg(key: String, value: Variant) -> void:
	Settings.set_v("ics", key, value)


func identify(device_id: String) -> void:
	_send({"cmd": "ident", "device": device_id})
	Sfx.click()


## IDENTIFY a station: chime + "<seat> station" through that station's AUDIO OUT stream.
func identify_seat(s: String) -> void:
	_send({"cmd": "ident", "seat": s})
	Sfx.click()


## Saved value for a picker entry. New picks are "node@bus=<usb path>" so a ".2" rename
## still finds the same jack, and analog vs digital on that jack stay different picks.
## Older saves are "node@port=<short port>" or a bare node name.
static func io_value(dv: Dictionary) -> String:
	return str(dv.get("key", dv.get("name", "")))


static var _fam_re: RegEx


## Node name without the trailing ".2" counter. Analog and iec958 stay different.
static func _family(name: String) -> String:
	if _fam_re == null:
		_fam_re = RegEx.new()
		_fam_re.compile("\\.\\d+$")
	return _fam_re.sub(name, "", true)


static func _choice_parts(value: String) -> Dictionary:
	var name := value
	var bus := ""
	var port := ""
	if "@bus=" in value:
		name = value.get_slice("@bus=", 0)
		bus = value.get_slice("@bus=", 1)
	elif "@port=" in value:
		name = value.get_slice("@port=", 0)
		port = value.get_slice("@port=", 1)
	return {"name": name, "bus": bus, "port": port}


## True when this live device is the one a saved AUDIO OUT / MIC IN value points at,
## including after the node name's ".2" counter swaps.
func _io_matches(dv: Dictionary, value: String) -> bool:
	if value == "" or dv.is_empty():
		return false
	if io_value(dv) == value or str(dv.get("name", "")) == value:
		return true
	var p := _choice_parts(value)
	var nm := str(dv.get("name", ""))
	if str(p["name"]) != "" and nm == str(p["name"]):
		return true
	if _family(str(p["name"])) != _family(nm):
		return false          # same jack, other profile (analog vs digital): not this pick
	if str(p["bus"]) != "" and str(dv.get("bus", "")) == str(p["bus"]):
		return true
	if str(p["port"]) != "" and str(dv.get("port", "")) == str(p["port"]):
		return true
	return false


func _io_find(kind: String, value: String) -> Dictionary:
	var lst: Array = inputs if kind == "in" else outputs
	var hit := {}
	for dv: Dictionary in lst:
		if not _io_matches(dv, value):
			continue
		var p := _choice_parts(value)
		if io_value(dv) == value or str(dv.get("name", "")) == value or str(dv.get("name", "")) == str(p["name"]):
			return dv
		if hit.is_empty():
			hit = dv
	return hit


func _io_taken(s: String, kind: String, dv: Dictionary) -> bool:
	for o in SEATS:
		if o == s:
			continue
		var v := str(Settings.get_v("ics", "%s_%s" % [o, kind]))
		if v != "" and v != "none" and v != "default" and _io_matches(dv, v):
			return true
	return false


func rescan() -> void:
	_send({"cmd": "rescan"})


func toggle_mute(s: String) -> void:
	mute[s] = not bool(mute.get(s, false))
	Voice.say("%s microphone %s" % [SEAT_NAMES[s], "muted" if mute[s] else "on"])


## Legacy: headset pairing was removed from the UI. MIC IN / AUDIO OUT are the real routing.
## Kept so old callers / saves still resolve; prefer cycle_io / set_cfg on *_in / *_out.
func cycle_headset(s: String, d: int) -> void:
	var ids: Array = [""]
	for dv in devices:
		var taken := false
		for o in SEATS:
			if o != s and str(Settings.get_v("ics", o + "_headset")) == str(dv["id"]):
				taken = true
		if not taken:
			ids.append(str(dv["id"]))
	var cur := str(Settings.get_v("ics", s + "_headset"))
	var i := ids.find(cur)
	if i < 0:
		i = 0
	set_cfg(s + "_headset", ids[posmod(i + d, ids.size())])


## Step a station's INPUT ("in") or OUTPUT ("out") through: none, system default,
## then every device not already picked by another station (never steals one).
func cycle_io(s: String, kind: String, d: int) -> void:
	var lst: Array = inputs if kind == "in" else outputs
	var opts: Array = ["none", "default"]
	for dv: Dictionary in lst:
		if not _io_taken(s, kind, dv):
			opts.append(io_value(dv))
	var cur := str(Settings.get_v("ics", "%s_%s" % [s, kind]))
	if cur == "":
		cur = "none"
	var cd := _io_find(kind, cur)
	var i := opts.find(io_value(cd) if not cd.is_empty() else cur)
	if i < 0:
		i = 0
	set_cfg("%s_%s" % [s, kind], opts[posmod(i + d, opts.size())])


## [[value, text]] for a station's dropdown: None, System default, then free devices
## (plus this station's own pick, even if unplugged). One device per station.
func io_options(s: String, kind: String) -> Array:
	var lst: Array = inputs if kind == "in" else outputs
	var out: Array = [["none", "None"], ["default", "System default"]]
	var cur := str(Settings.get_v("ics", "%s_%s" % [s, kind]))
	if cur == "":
		cur = "none"
	var have_cur := cur in ["none", "default"]
	var owner := _io_find(kind, cur)
	for dv: Dictionary in lst:
		if _io_taken(s, kind, dv):
			continue
		var val := io_value(dv)
		if not owner.is_empty() and str(dv.get("name", "")) == str(owner.get("name", "")):
			val = cur
		out.append([val, friendly(val, kind)])
		have_cur = have_cur or val == cur
	if not have_cur and cur != "":
		out.append([cur, friendly(cur, kind) + "  (not plugged in)"])
	return out


## "Blue Snowball", "Logi USB Headset (port 3.3.4)": description + USB port when two match.
func friendly(value: String, kind: String) -> String:
	var lst: Array = inputs if kind == "in" else outputs
	var fd := _io_find(kind, value)
	var nm := str(fd.get("name", _choice_parts(value)["name"]))
	var desc := str(fd.get("desc", ""))
	if desc == "":
		desc = nm.get_slice(".", 1).trim_prefix("usb-").replace("_", " ") if nm.count(".") >= 1 else nm
		return desc
	desc = desc.replace(" Mono", "").replace(" Analog Stereo", "").replace(" Digital Stereo", "")
	var dup := 0
	for dv: Dictionary in lst:
		if str(dv["desc"]).begins_with(desc):
			dup += 1
	if dup > 1:
		var port := str(lst.filter(func(x: Dictionary) -> bool: return str(x["name"]) == nm)[0].get("port", ""))
		desc += "  (port %s)" % port if port != "" else ("  #2" if nm.ends_with(".2") or nm.contains(".2.") else "  #1")
	return desc


func io_label(s: String, kind: String) -> String:
	var cur := str(Settings.get_v("ics", "%s_%s" % [s, kind]))
	var opened: Array = routes.get(s, ["", ""])
	var now := str(opened[0 if kind == "in" else 1]) if opened.size() == 2 else ""
	var pretty := func(nm: String) -> String:
		var fd := _io_find(kind, nm)
		return str(fd["desc"]) if not fd.is_empty() else str(_choice_parts(nm)["name"])
	match cur:
		"", "none":
			return "None"
		"default":
			return "System default" + ("  → " + pretty.call(now) if now != "" else "")
	var found := _io_find(kind, cur)
	var live_name := str(found.get("name", ""))
	return pretty.call(cur) + ("" if live_name != "" and now == live_name else "  (not found)")


func device_label(id: String) -> String:
	for dv in devices:
		if str(dv["id"]) == id:
			return str(dv["label"])
	if id == "":
		return "(none)"
	return id.get_slice("|", 0) + "  (not plugged in)"


func _process(dt: float) -> void:
	if not enabled:
		return
	while _rx.get_available_packet_count() > 0:
		var d: Variant = JSON.parse_string(_rx.get_packet().get_string_from_utf8())
		if typeof(d) != TYPE_DICTIONARY:
			continue
		_last_rx = _now()
		match str(d.get("type", "")):
			"status":
				status = d
				state_text = str(d.get("msg", ""))
				status_changed.emit()
			"devices":
				devices = d.get("list", [])
				inputs = d.get("inputs", [])
				outputs = d.get("outputs", [])
				routes = d.get("routes", {})
				assign = d.get("assign", {})
				_migrate_headset_to_io()
				devices_changed.emit()
			"record":
				recorded.emit(str(d.get("path", "")), float(d.get("secs", 0.0)))
	_hello_t += dt
	if _hello_t > 1.0:
		_hello_t = 0.0
		_hello()
	# run.sh already started the helper (it can take a few s to open the devices): never start a
	# second one, which raced it, reset the sinks and looked like endless restarts.
	if not connected() and not _start_tried and OS.get_environment("FALCON_ICS") != "runsh" and _now() - _t0 > 5.0:
		_start_helper()
	elif not connected() and helper_pid > 0 and not OS.is_process_running(helper_pid):
		helper_pid = -1
		state_text = "helper stopped: see ~/.local/share/filament-falcon/ics.log"
	# PTT / ALL-CALL / mutes: on change, and every 0.5 s (UDP may drop a packet)
	var ptt := {}
	for s in SEATS:
		ptt[s] = ptt_down(s)
	var st := {"cmd": "state", "ptt": ptt, "allcall": allcall_down(), "mute": mute}
	var js := JSON.stringify(st)
	_state_t += dt
	if js != _sent_state or _state_t > 0.5:
		_state_t = 0.0
		_sent_state = js
		_send(st)
	_route_audio()


## Move Godot's own audio into the helper's falcon_game sink while the helper runs; back to the
## default output if the helper goes away (so the game never goes silent).
func _route_audio() -> void:
	if Settings.is_headless() or mock or _demo:
		return
	var want := ok() and str(status.get("game_sink", "")) != ""
	if want == _routed:
		return
	if want:
		var target := ""
		for dv in AudioServer.get_output_device_list():
			var n := str(dv).to_lower()
			if n.contains("falcon_game") or n.contains("falcon-game"):
				target = dv
				break
		if target == "":
			return
		_prev_device = AudioServer.output_device
		AudioServer.output_device = target
		_routed = true
		print("[ICS] game audio -> ", target)
	else:
		AudioServer.output_device = _prev_device if _prev_device != "" else "Default"
		_routed = false
		print("[ICS] game audio -> ", AudioServer.output_device)



## One-time (and on each device list): if a seat still has a legacy *_headset and empty
## *_in / *_out, copy that headset's source/sink into the IO picks, then clear *_headset.
## Keeps one-device-per-station and IDENTIFY-via-AUDIO-OUT working after the headset UI went away.
func _migrate_headset_to_io() -> void:
	var dirty := false
	for s in SEATS:
		var hid := str(Settings.get_v("ics", s + "_headset"))
		if hid == "":
			# normalize legacy empty IO ("follow headset") to explicit none
			if str(Settings.get_v("ics", s + "_in")) == "":
				Settings.set_v("ics", s + "_in", "none", false)
				dirty = true
			if str(Settings.get_v("ics", s + "_out")) == "":
				Settings.set_v("ics", s + "_out", "none", false)
				dirty = true
			continue
		var dev := {}
		for dv in devices:
			if str(dv.get("id", "")) == hid:
				dev = dv
				break
		if dev.is_empty():
			continue
		var src := str(dev.get("source", ""))
		var snk := str(dev.get("sink", ""))
		if str(Settings.get_v("ics", s + "_in")) == "" and src != "":
			var fd := _io_find("in", src)
			Settings.set_v("ics", s + "_in", io_value(fd) if not fd.is_empty() else src, false)
			dirty = true
		elif str(Settings.get_v("ics", s + "_in")) == "":
			Settings.set_v("ics", s + "_in", "none", false)
			dirty = true
		if str(Settings.get_v("ics", s + "_out")) == "" and snk != "":
			var fd2 := _io_find("out", snk)
			Settings.set_v("ics", s + "_out", io_value(fd2) if not fd2.is_empty() else snk, false)
			dirty = true
		elif str(Settings.get_v("ics", s + "_out")) == "":
			Settings.set_v("ics", s + "_out", "none", false)
			dirty = true
		Settings.set_v("ics", s + "_headset", "", false)
		dirty = true
	if dirty:
		Settings.save()
		_send({"cmd": "cfg", "values": config_values()})


## Screenshots / UI tests: plausible status without a helper.
func inject_demo() -> void:
	_demo = true
	devices = [
		{"id": "USB Audio Device|C-Media_Electronics_Inc._USB_Audio_Device|pci-0000:0e:00.3-usb-0:3:1.0", "label": "USB Audio Device  (USB 0:3:1.0)"},
		{"id": "USB Audio Device|C-Media_Electronics_Inc._USB_Audio_Device|pci-0000:0e:00.3-usb-0:4:1.0", "label": "USB Audio Device  (USB 0:4:1.0)"},
		{"id": "Logitech USB Headset|Logitech_Logitech_USB_Headset|pci-0000:0e:00.3-usb-0:2:1.0", "label": "Logitech USB Headset  (USB 0:2:1.0)"},
		{"id": "Meta Quest (WiVRn)||wivrn", "label": "Meta Quest 3 (WiVRn audio)"}]
	assign = {"pilot": devices[0]["id"], "ops": devices[1]["id"], "commander": devices[2]["id"], "eva": devices[3]["id"]}
	inputs = [
		{"name": "alsa_input.usb-pilot", "desc": "Pilot mic", "key": "alsa_input.usb-pilot"},
		{"name": "alsa_input.usb-ops", "desc": "Ops mic", "key": "alsa_input.usb-ops"},
		{"name": "alsa_input.usb-commander", "desc": "Commander mic", "key": "alsa_input.usb-commander"},
		{"name": "WiVRn(microphone)", "desc": "WiVRn mic", "key": "WiVRn(microphone)"}]
	outputs = [
		{"name": "alsa_output.usb-pilot", "desc": "Pilot headset", "key": "alsa_output.usb-pilot"},
		{"name": "alsa_output.usb-ops", "desc": "Ops headset", "key": "alsa_output.usb-ops"},
		{"name": "alsa_output.usb-commander", "desc": "Commander headset", "key": "alsa_output.usb-commander"},
		{"name": "WiVRn", "desc": "WiVRn", "key": "WiVRn"}]
	routes = {
		"pilot": ["alsa_input.usb-pilot", "alsa_output.usb-pilot"],
		"ops": ["alsa_input.usb-ops", "alsa_output.usb-ops"],
		"commander": ["alsa_input.usb-commander", "alsa_output.usb-commander"],
		"eva": ["WiVRn(microphone)", "WiVRn"]}
	for i in 4:
		Settings.set_v("ics", SEATS[i] + "_headset", "", false)
		Settings.set_v("ics", SEATS[i] + "_in", str(inputs[i]["key"]), false)
		Settings.set_v("ics", SEATS[i] + "_out", str(outputs[i]["key"]), false)
	Settings.set_v("ics", "enabled", true, false)
	status = {"ok": true, "msg": "running on PulseAudio (on PipeWire 1.0.5)", "server": "PulseAudio (on PipeWire 1.0.5)", "xruns": 0, "latency_ms": 35,
		"game_sink": "falcon_game", "mc_sink": "falcon_mc",
		"allcall": false, "seats": {
			"pilot": {"level": -24.0, "peak": -19.0, "open": true, "mode": "vox", "device": devices[0]["label"], "connected": true},
			"ops": {"level": -52.0, "peak": -47.0, "open": false, "mode": "vox", "device": devices[1]["label"], "connected": true},
			"commander": {"level": -61.0, "peak": -58.0, "open": false, "mode": "ptt", "device": devices[2]["label"], "connected": true},
			"eva": {"level": -40.0, "peak": -33.0, "open": false, "mode": "ptt", "device": devices[3]["label"], "connected": true}}}
	state_text = str(status["msg"])
	devices_changed.emit()
	status_changed.emit()


func _exit_tree() -> void:
	if _routed:
		AudioServer.output_device = _prev_device
	stop()
