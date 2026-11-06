extends Node
## Fully procedural cockpit audio (no sample files): engine rumble tied to thrust, RCS hiss
## and puffs, re-entry wind/plasma roar, master-caution alarm, cabin fan ambience, and
## UI beeps / chimes / fanfare. Everything is synthesised into one AudioStreamGenerator.

const RATE := 48000.0

var player: AudioStreamPlayer
var pb: AudioStreamGeneratorPlayback

# Continuous levels, set by Game every frame (0..1+)
var engine_level := 0.0
var rcs_level := 0.0
var wind_level := 0.0
var alarm_on := false
var ambience := 0.5
var muted := false

var _eng := 0.0
var _rcs := 0.0
var _wind := 0.0
var _brown := 0.0
var _lp_e := 0.0
var _lp_e2 := 0.0
var _lp_w := 0.0
var _hp_r := 0.0
var _prev_white := 0.0
var _ph := [0.0, 0.0, 0.0, 0.0]
var _ph_w := 0.0      # turbopump whine
var _ph_f2 := 0.0     # second cabin fan (slightly detuned -> slow beat)
var _rcs_prev := 0.0  # RCS onset detector -> valve 'thunk'
var _thunk := 0.0
var _alarm_t := 0.0
var _tones: Array = []   # {f0, f1, dur, t, vol, wave, delay}
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = RATE
	gen.buffer_length = 0.5    # survive SOLAR/frame hitches without rhythmic underruns
	player = AudioStreamPlayer.new()
	player.stream = gen
	player.volume_db = float(Settings.get_v("audio", "master_db"))
	add_child(player)
	player.play()
	pb = player.get_stream_playback() as AudioStreamGeneratorPlayback


## Queue a tone. wave: sine | square | noise | saw. delay in seconds.
func tone(f0: float, dur: float, vol: float = 0.25, wave: String = "sine", f1: float = -1.0, delay: float = 0.0) -> void:
	if _tones.size() > 48:
		return
	_tones.append({"f0": f0, "f1": f1 if f1 > 0.0 else f0, "dur": dur, "t": -delay, "vol": vol, "wave": wave, "ph": 0.0})


func beep() -> void:
	tone(1320.0, 0.07, 0.18, "square")


func click() -> void:
	tone(2400.0, 0.02, 0.15, "noise")


func chime() -> void:
	tone(988.0, 0.35, 0.22)
	tone(1319.0, 0.5, 0.2, "sine", -1.0, 0.18)


func caution_chime() -> void:
	tone(740.0, 0.18, 0.25, "square")
	tone(740.0, 0.18, 0.25, "square", -1.0, 0.25)


func countdown_tick(final_tick: bool = false) -> void:
	tone(1760.0 if final_tick else 880.0, 0.12 if not final_tick else 0.5, 0.22)


func rcs_puff() -> void:
	tone(3000.0, 0.09, 0.12, "noise")


func clunk() -> void:
	tone(90.0, 0.35, 0.5, "square", 45.0)
	tone(300.0, 0.08, 0.3, "noise")


func explosion() -> void:
	tone(70.0, 1.4, 0.6, "noise", 30.0)
	tone(45.0, 1.2, 0.5, "square", 25.0)


func laser() -> void:
	tone(1800.0, 0.25, 0.15, "saw", 400.0)


func jump_spool() -> void:
	tone(120.0, 6.0, 0.25, "saw", 1600.0)


func fanfare() -> void:
	var notes := [523.25, 659.25, 783.99, 1046.5, 783.99, 1046.5]
	var durs := [0.18, 0.18, 0.18, 0.45, 0.18, 0.9]
	var t := 0.0
	for i in notes.size():
		tone(notes[i], durs[i], 0.2, "square", -1.0, t)
		tone(notes[i] * 0.5, durs[i], 0.12, "sine", -1.0, t)
		t += durs[i] * 0.9


func sad_trombone() -> void:
	var notes := [392.0, 370.0, 349.0, 330.0]
	for i in notes.size():
		tone(notes[i], 0.4 if i < 3 else 1.0, 0.2, "saw", notes[i] * (0.97 if i == 3 else 1.0), i * 0.42)


func _process(_dt: float) -> void:
	if pb == null:
		return
	# After a hitch the generator can be nearly empty; refill in chunks until
	# topped up so engine rumble does not rhythmically drop out under SOLAR load.
	var safety := 0
	while pb.get_frames_available() > 256 and safety < 48:
		_fill_audio_chunk(mini(pb.get_frames_available(), 2048))
		safety += 1


func _fill_audio_chunk(n: int) -> void:
	if n <= 0:
		return
	var buf := PackedVector2Array()
	buf.resize(n)
	var inv := 1.0 / RATE
	var eng_t := clampf(engine_level, 0.0, 1.5)
	var rcs_t := clampf(rcs_level, 0.0, 1.0)
	var wind_t := clampf(wind_level, 0.0, 1.5)
	var amb := ambience
	var ph0: float = _ph[0]
	var ph1: float = _ph[1]
	var ph2: float = _ph[2]
	var ph3: float = _ph[3]
	for i in n:
		_eng += (eng_t - _eng) * 0.0008
		_rcs += (rcs_t - _rcs) * 0.01
		_wind += (wind_t - _wind) * 0.0005
		var white := _rng.randf() * 2.0 - 1.0
		_brown = clampf(_brown * 0.995 + white * 0.06, -1.0, 1.0)
		var s := 0.0
		# Engine: low-passed brown noise + sub-bass throb + crackle
		if _eng > 0.002:
			_lp_e += (_brown - _lp_e) * 0.05
			_lp_e2 += (_lp_e - _lp_e2) * 0.08
			ph0 = fmod(ph0 + 41.0 * inv, 1.0)
			ph1 = fmod(ph1 + 63.0 * inv, 1.0)
			var throb := sin(ph0 * TAU) * 0.35 + sin(ph1 * TAU) * 0.2
			var crackle := white * 0.25 if _rng.randf() < 0.002 * _eng else 0.0
			# Turbopump whine rises with throttle (heard through the structure, quiet)
			_ph_w = fmod(_ph_w + (1800.0 + 2600.0 * _eng) * inv, 1.0)
			var whine := sin(_ph_w * TAU) * 0.018 * _eng
			s += (_lp_e2 * 2.6 + throb * 0.5 + crackle + whine) * _eng * 0.55
		# RCS: solenoid valve thunk on each pulse onset, then high-passed hiss
		if rcs_t > 0.05 and _rcs_prev <= 0.05:
			_thunk = 1.0
		_rcs_prev = rcs_t
		if _thunk > 0.001:
			s += _brown * _thunk * 0.35
			_thunk *= 0.993
		if _rcs > 0.002:
			var hp := white - _prev_white
			_hp_r += (hp - _hp_r) * 0.5
			s += _hp_r * _rcs * 0.18
		_prev_white = white
		# Wind / plasma roar
		if _wind > 0.002:
			_lp_w += (white - _lp_w) * (0.02 + 0.05 * _wind)
			s += _lp_w * _wind * 0.6
		# Cabin ambience: fan hum + air
		ph2 = fmod(ph2 + 118.0 * inv, 1.0)
		_ph_f2 = fmod(_ph_f2 + 119.3 * inv, 1.0)
		s += (sin(ph2 * TAU) * 0.012 + sin(_ph_f2 * TAU) * 0.008 + _brown * 0.02) * amb
		# Master caution alarm (two-tone)
		if alarm_on:
			_alarm_t += inv
			var f := 880.0 if fmod(_alarm_t, 0.5) < 0.25 else 660.0
			ph3 = fmod(ph3 + f * inv, 1.0)
			var sq := 1.0 if ph3 < 0.5 else -1.0
			s += sq * 0.07 * (0.6 + 0.4 * sin(ph3 * TAU))
		# Soft clip: layered sources can sum past 1.0 (hard clipping = harsh garble)
		s = s / (1.0 + absf(s))
		buf[i] = Vector2(s, s)
	_ph[0] = ph0
	_ph[1] = ph1
	_ph[2] = ph2
	_ph[3] = ph3
	# Tones (rendered block-wise)
	if not _tones.is_empty():
		var keep: Array = []
		for t in _tones:
			var tt: float = t["t"]
			var dur: float = t["dur"]
			var vol: float = t["vol"]
			var ph: float = t["ph"]
			var wave: String = t["wave"]
			for i in n:
				tt += inv
				if tt < 0.0:
					continue
				if tt > dur:
					break
				var k := tt / dur
				var f := lerpf(t["f0"], t["f1"], k)
				ph = fmod(ph + f * inv, 1.0)
				var env := minf(1.0, tt * 200.0) * (1.0 - k) * (1.0 - k * 0.3)
				var v := 0.0
				match wave:
					"square":
						v = 0.6 if ph < 0.5 else -0.6
					"saw":
						v = ph * 2.0 - 1.0
					"noise":
						v = _rng.randf() * 2.0 - 1.0
					_:
						v = sin(ph * TAU)
				var add := v * env * vol
				buf[i] += Vector2(add, add)
			t["t"] = tt
			t["ph"] = ph
			if tt < dur:
				keep.append(t)
		_tones = keep
	if muted:
		buf.fill(Vector2.ZERO)
	pb.push_buffer(buf)
