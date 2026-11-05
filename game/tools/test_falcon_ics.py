#!/usr/bin/env python3
"""Headless tests for the intercom helper (no audio hardware needed).
    python3 game/tools/test_falcon_ics.py -v
DSP and VOX/PTT gating with synthetic audio, routing (who hears whom), ALL-CALL, mute,
beeps, clock-drift rings, pactl parsing for PulseAudio and PipeWire, headset matching after
replug/re-ordering, Godot config parsing, and the UDP protocol against a --mock helper."""
import json
import math
import os
import socket
import subprocess
import sys
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np  # noqa: E402
import falcon_ics as ics  # noqa: E402

R, B = ics.RATE, ics.BLOCK


def sine(f, secs, amp=0.3):
    t = np.arange(int(R * secs)) / R
    return np.sin(2 * np.pi * f * t) * amp


def blocks(x):
    return [x[i:i + B] for i in range(0, len(x) - B + 1, B)]


def gain_db(f, filt):
    x = sine(f, 0.5)
    y = np.concatenate([filt.process(b) for b in blocks(x)])
    return 20 * math.log10(ics.rms(y[R // 5:]) / ics.rms(x[R // 5:]))


class Dsp(unittest.TestCase):
    def test_bandpass_shape(self):
        self.assertGreater(gain_db(1000, ics.BandPass()), -3.5)
        self.assertLess(gain_db(100, ics.BandPass()), -15)
        self.assertLess(gain_db(9000, ics.BandPass()), -14)

    def test_onepole_matches_reference(self):
        f = ics.OnePole(500)
        x = np.random.default_rng(1).standard_normal(1000)
        y = np.concatenate([f.lowpass(x[i:i + 100]) for i in range(0, 1000, 100)])
        ref, yy = np.zeros(1000), 0.0
        for i, v in enumerate(x):
            yy = f.a * yy + (1 - f.a) * v
            ref[i] = yy
        self.assertLess(np.max(np.abs(y - ref)), 1e-9)

    def test_compressor_reduces_range(self):
        c = ics.Compressor()
        loud = [c.process(b) for b in blocks(sine(1000, 0.6, 0.5))][-1]
        c2 = ics.Compressor()
        quiet = [c2.process(b) for b in blocks(sine(1000, 0.6, 0.05))][-1]
        in_range = 20 * math.log10(0.5 / 0.05)
        out_range = 20 * math.log10(ics.rms(loud) / ics.rms(quiet))
        self.assertLess(out_range, in_range - 6)

    def test_vox_attack_and_hang(self):
        g = ics.VoxGate(-38, attack_ms=15, hang_ms=300)
        dt = B / R * 1000
        self.assertFalse(g.update(-60, dt))
        opened_after = None
        for i in range(20):
            if g.update(-20, dt):
                opened_after = (i + 1) * dt
                break
        self.assertIsNotNone(opened_after)
        self.assertGreaterEqual(opened_after, 15)
        self.assertLessEqual(opened_after, 20)
        closed_after = None
        for i in range(200):
            if not g.update(-70, dt):
                closed_after = (i + 1) * dt
                break
        self.assertAlmostEqual(closed_after, 300, delta=dt)

    def test_vox_ignores_short_click(self):
        g = ics.VoxGate(-38, attack_ms=20, hang_ms=300)
        dt = B / R * 1000
        g.update(-10, dt)             # one 5 ms click
        self.assertFalse(g.update(-70, dt))


def run_engine(eng, seconds, talkers, game=None):
    """talkers: {seat: amplitude}; returns {seat: concatenated output}."""
    outs = {s: [] for s in ics.SEATS}
    rng = np.random.default_rng(5)
    n = int(seconds * R / B)
    for i in range(n):
        mics = {}
        for s in ics.SEATS:
            a = talkers.get(s, 0.0)
            mics[s] = (ics.BandPass(300, 3000).process(rng.standard_normal(B)) * a) if a else rng.standard_normal(B) * 0.0005
        g = np.full(B, 0.0) if game is None else sine(200, B / R, game)
        res = eng.process(mics, g)
        for s in ics.SEATS:
            outs[s].append(res[s])
    return {s: np.concatenate(v) for s, v in outs.items()}


class Quality(unittest.TestCase):
    def test_presets_widen_band(self):
        lo = ics.BandPass(**{k: ics.QUALITY["low"][k] for k in ("lo", "hi")})
        hi = ics.BandPass(**{k: ics.QUALITY["hifi"][k] for k in ("lo", "hi")})
        self.assertGreater(gain_db(6000, hi), gain_db(6000, lo) + 6)

    def test_hifi_drive_is_unity(self):
        self.assertAlmostEqual(ics.QUALITY["hifi"]["drive"], 1.0)
        self.assertGreater(ics.QUALITY["low"]["drive"], ics.QUALITY["high"]["drive"])

    def test_soft_limiter_holds_ceiling(self):
        lim = ics.SoftLimiter(ceiling=0.9)
        y = lim.process(np.ones(B) * 2.0)
        self.assertLessEqual(float(np.max(np.abs(y))), 0.901)

    def test_cubic_resampler_preserves_dc(self):
        x = np.full(100, 0.25)
        y = ics._resample_cubic(x, 97)
        self.assertAlmostEqual(float(np.mean(y)), 0.25, places=6)


class SuitRadio(unittest.TestCase):
    """4th seat: the VR spacewalker (Meta Quest 3 audio through WiVRn's virtual devices)."""

    def test_eva_band_is_narrower(self):
        # Suit radio is always narrower than the crew band at the same quality preset.
        cfg = dict(ics.DEFAULTS)
        cfg["audio_quality"] = "normal"   # classic radio numbers, clear gap at 5 kHz / 300 Hz
        eva = ics.Channel("eva", cfg, ics.Sounds()).radio
        crew = ics.Channel("pilot", cfg, ics.Sounds()).radio
        self.assertLess(gain_db(5000, eva), gain_db(5000, crew) - 2.0)
        self.assertLess(gain_db(300, eva), gain_db(300, crew) - 1.5)
        self.assertGreater(gain_db(1200, eva), -3.5)

    def test_quindar_tones_on_key_up_and_down(self):
        cfg = dict(ics.DEFAULTS)
        cfg.update({"eva_mode": "ptt", "static": False, "squelch_tail": False})
        ch = ics.Channel("eva", cfg, ics.Sounds())
        quiet = np.zeros(B)

        def tails_for(blocks_n):
            return np.concatenate([ch.process(quiet)[1] for _ in range(blocks_n)])

        ch.ptt = True
        down = tails_for(60)                 # 300 ms after keying
        ch.ptt = False
        up = tails_for(60)
        for sig, f in ((down, 2525.0), (up, 2475.0)):
            spec = np.abs(np.fft.rfft(sig[: int(R * 0.25)]))
            peak = np.fft.rfftfreq(int(R * 0.25), 1 / R)[int(np.argmax(spec))]
            self.assertAlmostEqual(peak, f, delta=8.0)

    def test_wivrn_devices_become_the_eva_headset(self):
        sinks = [{"name": "alsa_output.usb-C-Media_USB_Audio-00.analog-stereo", "description": "USB Audio Device",
                  "props": {"device.bus": "usb", "device.bus_path": "pci-0000:0e:00.3-usb-0:3:1.0", "device.product.name": "USB Audio Device"}},
                 {"name": "wivrn.sink", "description": "WiVRn", "props": {"node.name": "wivrn.sink"}}]
        sources = [{"name": "alsa_input.usb-C-Media_USB_Audio-00.mono-fallback", "description": "USB Audio Device",
                    "props": {"device.bus": "usb", "device.bus_path": "pci-0000:0e:00.3-usb-0:3:1.0", "device.product.name": "USB Audio Device"}},
                   {"name": "wivrn.sink.monitor", "description": "Monitor of WiVRn", "props": {"device.class": "monitor"}},
                   {"name": "wivrn.source", "description": "WiVRn(microphone)", "props": {}}]
        devs = ics.headsets_from(sinks, sources)
        q = [d for d in devs if d["path"] == "wivrn"]
        self.assertEqual(len(q), 1)
        self.assertEqual((q[0]["sink"], q[0]["source"]), ("wivrn.sink", "wivrn.source"))
        asg = ics.match_assignments(devs, {"pilot": devs[0]["id"] if devs[0]["path"] != "wivrn" else devs[1]["id"]})
        self.assertEqual(asg["eva"]["path"], "wivrn")
        self.assertNotEqual((asg["pilot"] or {}).get("path"), "wivrn")
        # an explicit Commander choice wins over the automatic Quest assignment
        asg2 = ics.match_assignments(devs, {"eva": "nothing|plugged|in"})
        self.assertIsNone(asg2["eva"])

    def test_spacewalker_hears_crew_and_crew_hears_spacewalker(self):
        eng = ics.Engine({"beeps": False, "static": False, "squelch_tail": False})
        o = run_engine(eng, 1.0, {"eva": 0.4})
        tail = slice(R // 2, None)
        for s in ("pilot", "ops", "commander"):
            self.assertGreater(ics.rms(o[s][tail]), 0.01)
        eng2 = ics.Engine({"beeps": False, "static": False, "squelch_tail": False})
        o2 = run_engine(eng2, 1.0, {"pilot": 0.4})
        self.assertGreater(ics.rms(o2["eva"][tail]), 0.02)


class Routing(unittest.TestCase):
    def cfg(self, **kw):
        c = {"beeps": False, "static": False, "squelch_tail": False, "pilot_mode": "vox", "ops_mode": "vox"}
        c.update(kw)
        return c

    def test_others_hear_me_not_myself(self):
        eng = ics.Engine(self.cfg())
        o = run_engine(eng, 1.0, {"pilot": 0.4})
        tail = slice(R // 2, None)
        self.assertGreater(ics.rms(o["ops"][tail]), 0.02)
        self.assertGreater(ics.rms(o["commander"][tail]), 0.02)
        self.assertLess(ics.rms(o["pilot"][tail]), 1e-4)

    def test_sidetone(self):
        eng = ics.Engine(self.cfg(pilot_sidetone=0.2))
        o = run_engine(eng, 1.0, {"pilot": 0.4})
        tail = slice(R // 2, None)
        self.assertGreater(ics.rms(o["pilot"][tail]), 0.003)
        self.assertLess(ics.rms(o["pilot"][tail]), ics.rms(o["ops"][tail]) * 0.5)

    def test_ptt_mode_needs_key(self):
        eng = ics.Engine(self.cfg(pilot_mode="ptt"))
        o = run_engine(eng, 0.5, {"pilot": 0.4})
        self.assertLess(ics.rms(o["ops"]), 1e-4)
        eng.ch["pilot"].ptt = True
        o = run_engine(eng, 0.5, {"pilot": 0.4})
        self.assertGreater(ics.rms(o["ops"][R // 10:]), 0.02)

    def test_quiet_mic_stays_closed_in_vox(self):
        eng = ics.Engine(self.cfg())
        o = run_engine(eng, 0.8, {"pilot": 0.002})
        self.assertFalse(eng.ch["pilot"].keyed)
        self.assertLess(ics.rms(o["ops"]), 1e-4)

    def test_mute(self):
        eng = ics.Engine(self.cfg())
        eng.ch["ops"].muted = True
        o = run_engine(eng, 1.0, {"ops": 0.4})
        self.assertLess(ics.rms(o["pilot"]), 1e-4)
        self.assertLess(ics.rms(o["commander"]), 1e-4)

    def test_allcall_ducks_game_and_reaches_kids(self):
        eng = ics.Engine(self.cfg(commander_mode="ptt"))
        o1 = run_engine(eng, 0.6, {}, game=0.3)
        g_before = ics.rms(o1["pilot"][R // 4:])
        eng.allcall = True
        o2 = run_engine(eng, 1.0, {"commander": 0.3}, game=0.3)
        self.assertTrue(eng.ch["commander"].keyed)
        lo = ics.BandPass(1000, 3000)                       # voice band only (game is 200 Hz)
        self.assertGreater(ics.rms(lo.process(o2["pilot"][R // 2:])), 0.01)
        hp = ics.BandPass(150, 260)
        game_during = ics.rms(hp.process(o2["ops"][R // 2:]))
        self.assertLess(game_during, ics.rms(hp.process(o1["ops"][R // 4:])) * 0.5)
        self.assertGreater(g_before, 0.05)
        self.assertGreater(ics.rms(o2["commander"][R // 2:]), 0.03)   # dad still hears the game

    def test_game_audio_to_every_seat_with_volume(self):
        eng = ics.Engine(self.cfg(pilot_game_vol=1.0, ops_game_vol=0.25, commander_game_vol=0.0))
        o = run_engine(eng, 0.5, {}, game=0.2)
        self.assertAlmostEqual(ics.rms(o["pilot"]), 0.2 / math.sqrt(2), delta=0.01)
        self.assertAlmostEqual(ics.rms(o["ops"]), 0.25 * 0.2 / math.sqrt(2), delta=0.005)
        self.assertLess(ics.rms(o["commander"]), 1e-6)

    def test_beeps_on_key_up(self):
        eng = ics.Engine(self.cfg(beeps=True, pilot_mode="ptt"))
        eng.ch["pilot"].ptt = True
        run_engine(eng, 0.3, {"pilot": 0.3})
        eng.ch["pilot"].ptt = False
        o = run_engine(eng, 0.3, {})
        self.assertGreater(ics.rms(o["ops"][:int(R * 0.13)]), 0.03)      # roger beep
        self.assertLess(ics.rms(o["pilot"]), 1e-4)                        # not to myself

    def test_radio_off_is_clean(self):
        eng = ics.Engine(self.cfg(radio_fx=False, pilot_mode="ptt"))
        eng.ch["pilot"].ptt = True
        x = sine(100, 0.5, 0.2)
        outs = [eng.process({"pilot": b})["ops"] for b in blocks(x)]
        y = np.concatenate(outs)[R // 10:]
        self.assertAlmostEqual(ics.rms(y), ics.rms(x[R // 10:]), delta=0.01)     # 100 Hz passes

    def test_mc_channel_reaches_everyone(self):
        eng = ics.Engine(self.cfg())
        rng = np.random.default_rng(3)
        res = None
        for _ in range(100):
            res = eng.process({}, None, ics.BandPass(400, 2500).process(rng.standard_normal(B)) * 0.3)
        for s in ics.SEATS:
            self.assertGreater(ics.rms(res[s]), 0.01)


class Rings(unittest.TestCase):
    def test_drift_both_ways(self):
        for ratio in (1.003, 0.997):
            r = ics.Ring()
            acc, produced, under = 0.0, 0, 0
            for _ in range(4000):                     # 20 s
                acc += B * ratio
                k = int(acc) - produced
                r.write(np.ones(k))
                produced += k
                x = r.read(B)
                if x is None:
                    continue
                self.assertEqual(len(x), B)
            self.assertLess(r.underruns, 3, ratio)
            self.assertLess(abs(r.fill() - r.target), B * 2, ratio)
            self.assertGreater(r.adjust, 5)

    def test_prime_and_underrun(self):
        r = ics.Ring()
        self.assertIsNone(r.read(B))
        r.write(np.ones(r.target))
        self.assertEqual(len(r.read(B)), B)


PA_SINKS = """Sink #0
	State: SUSPENDED
	Name: alsa_output.pci-0000_0b_00.4.analog-stereo
	Description: Starship/Matisse HD Audio Controller Analog Stereo
	Properties:
		alsa.card = "1"
		device.bus_path = "pci-0000:0b:00.4"
		device.bus = "pci"
		device.description = "Starship/Matisse HD Audio Controller Analog Stereo"
Sink #3
	State: RUNNING
	Name: alsa_output.usb-Logitech_Logitech_USB_Headset-00.analog-stereo
	Description: Logitech USB Headset Analog Stereo
	Properties:
		alsa.card = "3"
		device.bus_path = "pci-0000:0e:00.3-usb-0:2:1.0"
		device.bus = "usb"
		device.serial = "Logitech_Logitech_USB_Headset"
		device.product.name = "Logitech USB Headset"
Sink #4
	Name: alsa_output.usb-C-Media_Electronics_Inc._USB_Audio_Device-00.analog-stereo
	Description: USB Audio Device Analog Stereo
	Properties:
		alsa.card = "4"
		device.bus_path = "pci-0000:0e:00.3-usb-0:3:1.0"
		device.bus = "usb"
		device.serial = "C-Media_Electronics_Inc._USB_Audio_Device"
		device.product.name = "USB Audio Device"
Sink #5
	Name: alsa_output.usb-C-Media_Electronics_Inc._USB_Audio_Device-00.analog-stereo.2
	Description: USB Audio Device Analog Stereo
	Properties:
		alsa.card = "5"
		device.bus_path = "pci-0000:0e:00.3-usb-0:4:1.0"
		device.bus = "usb"
		device.serial = "C-Media_Electronics_Inc._USB_Audio_Device"
		device.product.name = "USB Audio Device"
"""
PA_SOURCES = """Source #2
	Name: alsa_output.usb-Logitech_Logitech_USB_Headset-00.analog-stereo.monitor
	Description: Monitor of Logitech USB Headset Analog Stereo
	Properties:
		device.class = "monitor"
		device.bus = "usb"
Source #6
	Name: alsa_input.usb-Logitech_Logitech_USB_Headset-00.mono-fallback
	Description: Logitech USB Headset Mono
	Properties:
		alsa.card = "3"
		device.bus_path = "pci-0000:0e:00.3-usb-0:2:1.0"
		device.bus = "usb"
		device.serial = "Logitech_Logitech_USB_Headset"
		device.product.name = "Logitech USB Headset"
Source #7
	Name: alsa_input.usb-C-Media_Electronics_Inc._USB_Audio_Device-00.mono-fallback
	Properties:
		device.bus_path = "pci-0000:0e:00.3-usb-0:3:1.0"
		device.bus = "usb"
		device.serial = "C-Media_Electronics_Inc._USB_Audio_Device"
		device.product.name = "USB Audio Device"
Source #8
	Name: alsa_input.usb-C-Media_Electronics_Inc._USB_Audio_Device-00.mono-fallback.2
	Properties:
		device.bus_path = "pci-0000:0e:00.3-usb-0:4:1.0"
		device.bus = "usb"
		device.serial = "C-Media_Electronics_Inc._USB_Audio_Device"
		device.product.name = "USB Audio Device"
"""
# PipeWire (pipewire-pulse) spells the bus path with a hyphen and names cards via api.alsa.*
PW_SINKS = """Sink #61
	State: SUSPENDED
	Name: alsa_output.usb-Jabra_Jabra_EVOLVE_20_A4A1B2-00.analog-stereo
	Description: Jabra EVOLVE 20 Analog Stereo
	Driver: PipeWire
	Properties:
		api.alsa.card.name = "Jabra EVOLVE 20"
		alsa.card = "2"
		device.bus = "usb"
		device.bus-path = "pci-0000:00:14.0-usb-0:7:1.0"
		device.serial = "Jabra_Jabra_EVOLVE_20_A4A1B2"
		node.name = "alsa_output.usb-Jabra_Jabra_EVOLVE_20_A4A1B2-00.analog-stereo"
"""
PW_SOURCES = """Source #62
	Name: alsa_input.usb-Jabra_Jabra_EVOLVE_20_A4A1B2-00.mono-fallback
	Description: Jabra EVOLVE 20 Mono
	Driver: PipeWire
	Properties:
		api.alsa.card.name = "Jabra EVOLVE 20"
		alsa.card = "2"
		device.bus = "usb"
		device.bus-path = "pci-0000:00:14.0-usb-0:7:1.0"
		device.serial = "Jabra_Jabra_EVOLVE_20_A4A1B2"
"""


class Devices(unittest.TestCase):
    def devs(self, sinks=PA_SINKS, sources=PA_SOURCES):
        return ics.headsets_from(ics.parse_pactl_list(sinks), ics.parse_pactl_list(sources))

    def test_pulseaudio_grouping(self):
        d = self.devs()
        self.assertEqual(len(d), 3)                       # onboard audio and monitors excluded
        lg = next(x for x in d if x["product"] == "Logitech USB Headset")
        self.assertTrue(lg["sink"].startswith("alsa_output.usb-Logitech"))
        self.assertTrue(lg["source"].startswith("alsa_input.usb-Logitech"))
        labels = [x["label"] for x in d]
        self.assertEqual(len(set(labels)), 3)             # identical C-Media sticks get unique labels

    def test_pipewire_grouping(self):
        d = self.devs(PW_SINKS, PW_SOURCES)
        self.assertEqual(len(d), 1)
        self.assertEqual(d[0]["product"], "Jabra EVOLVE 20")
        self.assertEqual(d[0]["path"], "pci-0000:00:14.0-usb-0:7:1.0")
        self.assertTrue(d[0]["source"])

    def test_match_survives_reorder_and_replug(self):
        d = self.devs()
        cm = [x for x in d if x["product"] == "USB Audio Device"]
        saved = {"pilot": cm[0]["id"], "ops": cm[1]["id"], "commander": next(x["id"] for x in d if "Logitech" in x["product"])}
        # replug: pulse renames the sinks (.2 swaps), card numbers change; ports stay
        sinks = PA_SINKS.replace("analog-stereo.2", "TMP").replace(
            "USB_Audio_Device-00.analog-stereo\n", "USB_Audio_Device-00.analog-stereo.2\n").replace("TMP", "analog-stereo")
        d2 = self.devs(sinks, PA_SOURCES)
        m = ics.match_assignments(d2, saved)
        self.assertEqual(m["pilot"]["path"], cm[0]["path"])
        self.assertEqual(m["ops"]["path"], cm[1]["path"])
        self.assertIn("Logitech", m["commander"]["product"])
        # Logitech moved to another USB port: unique serial still finds it
        d3 = self.devs(PA_SINKS.replace("usb-0:2:1.0", "usb-0:9:1.0"), PA_SOURCES.replace("usb-0:2:1.0", "usb-0:9:1.0"))
        self.assertIn("Logitech", ics.match_assignments(d3, saved)["commander"]["product"])

    def test_output_pick_follows_usb_port_not_node_name(self):
        outs = ics.plain_list(ics.parse_pactl_list(PA_SINKS))
        port3 = next(o for o in outs if o["port"] == "3")
        self.assertIn("@bus=pci-0000:0e:00.3-usb-0:3:1.0", port3["key"])
        self.assertEqual(ics.resolve(port3["key"], outs, "dflt"), port3["name"])
        # replug/reboot: the ".2" counter swaps between the identical sticks -> still the port-3 one
        sinks = PA_SINKS.replace("analog-stereo.2", "TMP").replace(
            "USB_Audio_Device-00.analog-stereo\n", "USB_Audio_Device-00.analog-stereo.2\n").replace("TMP", "analog-stereo")
        outs2 = ics.plain_list(ics.parse_pactl_list(sinks))
        got = ics.resolve(port3["key"], outs2, "dflt")
        self.assertEqual(next(o for o in outs2 if o["name"] == got)["port"], "3")
        self.assertNotEqual(got, port3["name"])
        # an older save (name@port=3, no bus path) still follows that port
        old = port3["name"] + "@port=3"
        self.assertEqual(ics.resolve(old, outs2, "dflt"), got)
        # its port is empty and the twin is another station's pick: nothing, never the twin
        outs3 = [o for o in outs2 if o["port"] != "3"]
        self.assertEqual(ics.resolve(port3["key"], outs3, "dflt", strict=True), "")
        self.assertEqual(ics.resolve(old, outs3, "dflt", used={o["name"] for o in outs3}), "")
        # old saves (plain names) and the specials still work
        self.assertEqual(ics.resolve(port3["name"], outs, "dflt"), port3["name"])
        self.assertEqual(ics.resolve("default", outs, "dflt"), "dflt")
        self.assertIsNone(ics.resolve("", outs, "dflt"))

    def test_output_pick_does_not_change_profile_or_steal_the_twin(self):
        # analog + digital on the SAME usb port. Picking analog must not come back as digital,
        # even when the analog node is already taken by another station.
        sinks = PA_SINKS.replace("Sink #4", """Sink #9
	Name: alsa_output.usb-C-Media_Electronics_Inc._USB_Audio_Device-00.iec958-stereo
	Description: USB Audio Device Digital Stereo
	Sample Specification: s16le 2ch 48000Hz
	Properties:
		alsa.card = "4"
		device.bus_path = "pci-0000:0e:00.3-usb-0:3:1.0"
		device.bus = "usb"
		device.serial = "C-Media_Electronics_Inc._USB_Audio_Device"
		device.product.name = "USB Audio Device"
Sink #4""")
        outs = ics.plain_list(ics.parse_pactl_list(sinks))
        analog = next(o for o in outs if o["port"] == "3" and "analog" in o["name"])
        digital = next(o for o in outs if "iec958" in o["name"])
        self.assertEqual(analog["bus"], digital["bus"])
        self.assertEqual(ics.resolve(analog["key"], outs, "dflt"), analog["name"])
        self.assertEqual(ics.resolve(digital["key"], outs, "dflt"), digital["name"])
        # analog is taken: digital pick still digital, and the analog pick is NOT quietly
        # rerouted onto the digital jack
        self.assertEqual(ics.resolve(digital["key"], outs, "dflt", used={analog["name"]}), digital["name"])
        self.assertEqual(ics.resolve(analog["key"], outs, "dflt", used={analog["name"]}, strict=True), "")
        # two controllers, same short port number, and the ".2" counter moved so the
        # saved node name is gone. A short @port=3 save must not guess which controller;
        # the full bus path still finds the one the Commander picked.
        renamed = dict(analog)
        renamed["name"] = analog["name"] + ".2"
        renamed["key"] = renamed["name"] + "@bus=" + analog["bus"]
        other = dict(analog)
        other["name"] = analog["name"].replace("analog-stereo", "analog-stereo.3")
        other["bus"] = "pci-0000:03:00.0-usb-0:3:1.0"
        other["key"] = other["name"] + "@bus=" + other["bus"]
        both = [o for o in outs if o["name"] != analog["name"]] + [renamed, other]
        self.assertEqual(ics.resolve(analog["name"] + "@port=3", both, "dflt", strict=True), "")
        self.assertEqual(ics.resolve(analog["key"], both, "dflt"), renamed["name"])
        self.assertEqual(ics.resolve(other["key"], both, "dflt"), other["name"])
        # a taken twin must not be replaced by the other identical headset (core fallback)
        twin = next(o for o in outs if o["port"] == "4" and "C-Media" in o["name"])
        self.assertEqual(ics.resolve(analog["name"], outs, "dflt", used={analog["name"]}), "")
        self.assertNotEqual(twin["name"], analog["name"])
        # 5.1 / 7.1 sinks are opened at their real channel count (stereo map gets rejected)
        self.assertEqual(ics.sink_channels("s16le 6ch 48000Hz"), 6)
        self.assertEqual(ics.sink_channels("s16le 1ch 48000Hz"), 1)
        self.assertEqual(ics.sink_channels(""), 2)

    def test_headset_uses_the_analog_sink_and_channels(self):
        extra = PA_SINKS.replace("Sink #4", """Sink #9
	Name: alsa_output.usb-C-Media_Electronics_Inc._USB_Audio_Device-00.iec958-stereo
	Description: USB Audio Device Digital Stereo
	Sample Specification: s16le 2ch 48000Hz
	Properties:
		alsa.card = "4"
		device.bus_path = "pci-0000:0e:00.3-usb-0:3:1.0"
		device.bus = "usb"
		device.serial = "C-Media_Electronics_Inc._USB_Audio_Device"
		device.product.name = "USB Audio Device"
Sink #4""")
        d = self.devs(extra, PA_SOURCES)
        cm = next(x for x in d if x["path"].endswith("0:3:1.0"))
        self.assertIn("analog-stereo", cm["sink"])
        self.assertEqual(ics.spec_channels("s16le 1ch 48000Hz"), 1)
        self.assertEqual(ics.spec_channels("float32le 2ch 48000Hz"), 2)
        pw = ics.parse_pactl_list(PW_SINKS)
        self.assertEqual(pw[0]["state"], "SUSPENDED")

    def test_missing_headset_is_none(self):
        d = self.devs(PW_SINKS, PW_SOURCES)
        m = ics.match_assignments(d, {"pilot": "Logitech USB Headset|x|pci-1"})
        self.assertIsNone(m["pilot"])


class Config(unittest.TestCase):
    def test_parse_godot_cfg(self):
        txt = '[display]\nmode="dev"\n\n[ics]\nenabled=true\npilot_headset="USB Audio Device|C-Media|pci-0000:0e:00.3-usb-0:3:1.0"\npilot_vox_db=-42.5\nops_mode="ptt"\nbeeps=false\nmc_vol=1\n'
        c = ics.parse_godot_cfg(txt)
        self.assertEqual(c["pilot_vox_db"], -42.5)
        self.assertEqual(c["ops_mode"], "ptt")
        self.assertFalse(c["beeps"])
        self.assertEqual(c["mc_vol"], 1)
        self.assertNotIn("mode", c)
        self.assertTrue(c["pilot_headset"].endswith("3:1.0"))


class Protocol(unittest.TestCase):
    def test_mock_helper_udp(self):
        game = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        game.bind(("127.0.0.1", 0))
        gport = game.getsockname()[1]
        probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        probe.bind(("127.0.0.1", 0))
        hport = probe.getsockname()[1]
        probe.close()
        p = subprocess.Popen([sys.executable, ics.__file__, "--mock", "--port", str(hport), "--game-port", str(gport),
                              "--settings", "/nonexistent"], stderr=subprocess.DEVNULL)
        try:
            game.settimeout(5)
            seen = {}
            t0 = time.time()
            sent_ptt = False
            while time.time() - t0 < 8 and not ("devices" in seen and seen.get("open")):
                game.sendto(json.dumps({"cmd": "hello", "pid": os.getpid(),
                                        "values": {"pilot_headset": "Mock Headset 2|MOCK2|pci-0000:00:14.0-usb-0:2:1.0", "ops_mode": "ptt"}}).encode(), ("127.0.0.1", hport))
                if "devices" in seen and not sent_ptt:
                    game.sendto(json.dumps({"cmd": "state", "ptt": {"ops": True}, "mute": {}, "allcall": False}).encode(), ("127.0.0.1", hport))
                    sent_ptt = True
                try:
                    msg = json.loads(game.recv(65536).decode())
                except socket.timeout:
                    continue
                seen[msg["type"]] = msg
                if msg["type"] == "status" and msg["seats"]["ops"]["open"]:
                    seen["open"] = True
            self.assertIn("devices", seen)
            self.assertEqual(len(seen["devices"]["list"]), 4)       # 3 mock USB headsets + the Quest (WiVRn)
            self.assertEqual(seen["devices"]["assign"].get("eva"), ics.WIVRN_ID)
            self.assertEqual(seen["devices"]["assign"]["pilot"], "Mock Headset 2|MOCK2|pci-0000:00:14.0-usb-0:2:1.0")
            self.assertTrue(seen.get("open"), "PTT did not key the ops channel")
            self.assertTrue(seen["status"]["ok"])
            # IDENTIFY a station: the chime is mixed into THAT station's output only
            game.sendto(b'{"cmd":"ident","seat":"commander"}', ("127.0.0.1", hport))
            got_ident, loud = None, -90.0
            t0 = time.time()
            while time.time() - t0 < 4 and not (got_ident and loud > -30):
                try:
                    msg = json.loads(game.recv(65536).decode())
                except socket.timeout:
                    continue
                if msg["type"] == "ident":
                    got_ident = msg
                if msg["type"] == "status" and got_ident:
                    loud = max(loud, msg["seats"]["commander"]["out_level"])
                    self.assertIn("out_state", msg["seats"]["pilot"])
            self.assertEqual((got_ident or {}).get("seat"), "commander")
            self.assertGreater(loud, -30, "identify chime did not reach the commander output")
            game.sendto(b'{"cmd":"quit"}', ("127.0.0.1", hport))
            p.wait(timeout=5)
        finally:
            game.close()
            if p.poll() is None:
                p.kill()


if __name__ == "__main__":
    unittest.main()
