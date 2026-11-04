#!/usr/bin/env python3
"""Filament Falcon ICS (intercom system) helper.

Three USB headsets (PILOT, OPS, COMMANDER) talk to each other with a radio effect, and the game
audio reaches all three. A 4th seat, EVA, is the VR spacewalker: the Meta Quest 3's audio shows
up on the PC as WiVRn's virtual speaker ("WiVRn") and microphone ("WiVRn(microphone)") while the
headset is connected; it is picked automatically and gets a "suit radio" (narrower band, more
static, Apollo Quindar tones). No WiVRn devices -> the seat is simply empty.

Godot can only open one audio device, so this helper does the multi-headset work and the game
talks to it over localhost UDP (like the LED bridge).

Audio graph (PulseAudio, or PipeWire through pipewire-pulse; `pactl info` tells which):
    game (Godot)  -> null sink "falcon_game" --monitor-->  helper  -> every headset (per-seat volume)
    voice callouts-> null sink "falcon_mc"   --monitor-->  helper  = MISSION CONTROL channel (radio fx)
    headset mics  -> parec -> helper: VOX/PTT gate, radio fx, beeps -> the OTHER headsets (pacat)
    optional: module-loopback falcon_game.monitor (+ falcon_mc) -> the default sink (room speakers)
The helper loads/unloads the null sinks and loopbacks itself and removes stale ones from a
crashed run. Every stream crosses a small adaptive ring that drops/repeats one sample per 5 ms
block when needed, so the four different USB/sink clocks never drift apart.

Latency budget (48 kHz, 5 ms blocks): capture ~10 ms + ring ~5-8 ms + playback ~15 ms + USB
~2-5 ms ~= 30-40 ms mouth-to-ear. Measure with --latency-test SEAT (mic held to the earcup).

Protocol: JSON datagrams. Game -> helper on 127.0.0.1:47810, helper -> game on :47811.
    {"cmd":"hello","pid":N}  {"cmd":"cfg","values":{...}}  {"cmd":"state","ptt":{seat:bool},
    "allcall":bool,"mute":{seat:bool}}  {"cmd":"ident","device":ID|"seat":S}  {"cmd":"rescan"}
    {"cmd":"record","path":P,"max_s":N}  {"cmd":"record_stop"}   (Captain's Log: the crew's gated
    voices mixed to a 48 kHz mono WAV; helper -> game {"type":"record","path":P,"secs":S})
    {"cmd":"quit"}
    helper -> game: {"type":"status",...} ~15 Hz (levels, gate state), {"type":"devices",...}
Config: the [ics] section of ~/.local/share/filament-falcon/falcon_settings.cfg (written by the
game's Commander > ICS page); live changes arrive as "cfg" messages.

Needs: python3-numpy and pulseaudio-utils (pactl, parec, pacat). Exits quietly with a reason
when something is missing; the game keeps running without the intercom.
Usage: falcon_ics.py [--parent-pid N] [--port 47810] [--game-port 47811] [--mock] [--list]
                     [--ident SEAT|DEVICE] [--latency-test SEAT] [--setup-only] [--log FILE]
"""
import argparse
import json
import math
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time

try:
    import numpy as np
except ImportError:  # pragma: no cover - reported to the game
    np = None

RATE = 48000
BLOCK = 480                    # 10 ms (5 ms blocks + Python sleep jitter underran -> garble)
SEATS = ("pilot", "ops", "commander", "eva")
KIDS = ("pilot", "ops")
LISTENERS_DUCKED = ("pilot", "ops", "eva")    # ALL-CALL: the Commander talks over everyone else
WIVRN_ID = "Meta Quest (WiVRn)||wivrn"         # the spacewalker's headset: WiVRn's virtual sink + mic
GAME_SINK = "falcon_game"
MC_SINK = "falcon_mc"
SETTINGS = os.path.expanduser("~/.local/share/filament-falcon/falcon_settings.cfg")

DEFAULTS = {
    "enabled": True,
    "pilot_headset": "", "ops_headset": "", "commander_headset": "", "eva_headset": "",
    "radio_fx": True, "static": True, "squelch_tail": True, "beeps": True,
    "speakers": True, "mc_vol": 0.9, "allcall_duck": 0.25,
}
SEAT_DEFAULTS = {"mode": "vox", "vox_db": -38.0, "attack_ms": 15.0, "hang_ms": 600.0,
                 "game_vol": 0.7, "ics_vol": 1.0, "sidetone": 0.0, "mic_gain": 1.0}
for _s in SEATS:
    for _k, _v in SEAT_DEFAULTS.items():
        DEFAULTS[f"{_s}_{_k}"] = _v
DEFAULTS["commander_mode"] = "ptt"      # dad keys the INTERCOM button; kids default to VOX
# the spacewalker (Quest 3 mic through WiVRn): VOX, a touch more hang, a little sidetone so the
# helmet does not feel "dead"
DEFAULTS.update({"eva_vox_db": -36.0, "eva_hang_ms": 700.0, "eva_game_vol": 0.6, "eva_sidetone": 0.15})


def log(*a):
    print("[ics]", *a, file=sys.stderr, flush=True)


# ============================================================================ config
def parse_godot_cfg(text, section="ics"):
    """Minimal reader for Godot ConfigFile text: returns {key: python value} of one section."""
    out, cur = {}, None
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith(";"):
            continue
        m = re.match(r"^\[(.+)\]$", line)
        if m:
            cur = m.group(1)
            continue
        if cur != section or "=" not in line:
            continue
        k, v = line.split("=", 1)
        k, v = k.strip(), v.strip()
        if v in ("true", "false"):
            out[k] = v == "true"
        elif len(v) >= 2 and v[0] == '"' and v[-1] == '"':
            out[k] = v[1:-1].replace('\\"', '"').replace("\\\\", "\\")
        else:
            try:
                out[k] = float(v) if any(c in v for c in ".eE") else int(v)
            except ValueError:
                out[k] = v
    return out


def load_config(path=SETTINGS):
    cfg = dict(DEFAULTS)
    try:
        with open(path, encoding="utf-8") as f:
            cfg.update(parse_godot_cfg(f.read()))
    except OSError:
        pass
    return cfg


# ============================================================================ DSP
def db(x):
    return 20.0 * math.log10(max(float(x), 1e-9))


def rms(x):
    return float(np.sqrt(np.mean(np.square(x, dtype=np.float64)))) if len(x) else 0.0


class OnePole:
    """First-order low-pass y = a*y + (1-a)*x, vectorised per block with the closed form
    y[n] = a^(n+1) y[-1] + (1-a) sum a^(n-k) x[k] (chunks of 64 keep a^-n well inside float64)."""

    def __init__(self, fc, rate=RATE):
        self.a = math.exp(-2.0 * math.pi * fc / rate)
        self.y = 0.0
        n = np.arange(64, dtype=np.float64)
        self._pow = self.a ** n            # a^n
        self._ipow = self.a ** (-n)        # a^-n

    def lowpass(self, x):
        x = np.asarray(x, dtype=np.float64)
        out = np.empty_like(x)
        for s in range(0, len(x), 64):
            c = x[s:s + 64]
            m = len(c)
            acc = np.cumsum(c * self._ipow[:m]) * (1.0 - self.a)
            y = self._pow[:m] * (self.a * self.y + acc)
            out[s:s + m] = y
            self.y = float(y[-1])
        return out

    def highpass(self, x):
        return np.asarray(x, dtype=np.float64) - self.lowpass(x)


class BandPass:
    """Radio voice band: 2 x one-pole high-pass at lo + 2 x one-pole low-pass at hi (12 dB/oct
    each side, zero latency)."""

    def __init__(self, lo=300.0, hi=3400.0, rate=RATE):
        self.h = [OnePole(lo, rate), OnePole(lo, rate)]
        self.l = [OnePole(hi, rate), OnePole(hi, rate)]

    def process(self, x):
        for f in self.h:
            x = f.highpass(x)
        for f in self.l:
            x = f.lowpass(x)
        return x


class Compressor:
    """Light feed-forward compressor at block rate (gain interpolated across the block)."""

    def __init__(self, threshold_db=-30.0, ratio=3.0, makeup_db=9.0, attack_ms=5.0, release_ms=120.0):
        self.t, self.r, self.mk = threshold_db, ratio, makeup_db
        bt = BLOCK / RATE * 1000.0
        self.ca = math.exp(-bt / attack_ms)
        self.cr = math.exp(-bt / release_ms)
        self.env = -90.0
        self.g = 1.0

    def process(self, x):
        lvl = db(rms(x))
        c = self.ca if lvl > self.env else self.cr
        self.env = c * self.env + (1.0 - c) * lvl
        over = self.env - self.t
        gr = over - over / self.r if over > 0 else 0.0
        g = 10 ** ((self.mk - gr) / 20.0)
        ramp = np.linspace(self.g, g, len(x), endpoint=False)
        self.g = g
        return x * ramp


class VoxGate:
    """Voice-operated switch: opens when the mic level stays above threshold for attack_ms,
    closes hang_ms after it falls below (threshold - 4 dB hysteresis)."""

    def __init__(self, threshold_db=-38.0, attack_ms=15.0, hang_ms=600.0):
        self.threshold_db, self.attack_ms, self.hang_ms = threshold_db, attack_ms, hang_ms
        self.open = False
        self._above = 0.0
        self._below = 0.0

    def update(self, level_db, dt_ms=BLOCK / RATE * 1000.0):
        if level_db >= self.threshold_db:
            self._above += dt_ms
            self._below = 0.0
            if not self.open and self._above >= self.attack_ms:
                self.open = True
        else:
            self._above = 0.0
            if self.open:
                if level_db < self.threshold_db - 4.0:
                    self._below += dt_ms
                if self._below >= self.hang_ms:
                    self.open = False
                    self._below = 0.0
        return self.open


def tone(freq, ms, amp=0.25, rate=RATE, fade_ms=4.0):
    n = int(rate * ms / 1000.0)
    t = np.arange(n) / rate
    s = np.sin(2 * np.pi * freq * t) * amp
    f = max(1, int(rate * fade_ms / 1000.0))
    env = np.ones(n)
    env[:f] = np.linspace(0, 1, f)
    env[-f:] = np.linspace(1, 0, f)
    return s * env


class Sounds:
    """Procedural intercom sounds (all short, all band-limited)."""

    def __init__(self, seed=7):
        self.rng = np.random.default_rng(seed)

    def click(self):            # mic key-down click
        n = int(RATE * 0.012)
        burst = self.rng.standard_normal(n) * np.exp(-np.arange(n) / (RATE * 0.002)) * 0.25
        return np.concatenate([BandPass(800, 3000).process(burst) * 2.0, tone(1250, 22, 0.10)])

    def roger(self):            # key-up roger beep (two quick tones)
        return np.concatenate([tone(2100, 55, 0.16), tone(1500, 75, 0.16)])

    def squelch(self, ms=140):  # squelch tail: filtered noise burst that decays
        n = int(RATE * ms / 1000.0)
        noise = self.rng.standard_normal(n) * 0.18 * np.exp(-np.arange(n) / (RATE * ms / 3000.0))
        return BandPass(500, 3000).process(noise)

    def allcall(self):          # PA chime
        return np.concatenate([tone(880, 120, 0.2), tone(660, 160, 0.2)])

    def ident(self):
        gap = np.zeros(int(RATE * 0.08))
        return np.concatenate([tone(660, 140, 0.3), gap, tone(880, 140, 0.3), gap, tone(1320, 220, 0.3)])

    def static(self, n, level_db=-44.0):
        return self.rng.standard_normal(n) * 10 ** (level_db / 20.0)

    def quindar(self, up=True):  # Apollo-style "suit radio" tones: 2525 Hz key-down, 2475 Hz key-up
        return tone(2525 if up else 2475, 250, 0.14)


class Channel:
    """One talker on the intercom (a headset mic or the MISSION CONTROL channel).
    process() returns (voice, tails): voice = gated (radio-processed) speech, tails = beeps,
    squelch tail and static, both float64 blocks."""

    def __init__(self, name, cfg, sounds, mc=False):
        self.name, self.cfg, self.snd, self.mc = name, cfg, sounds, mc
        self.suit = name == "eva"     # spacewalker: narrower "suit radio" band, more static, Quindar tones
        self.radio = BandPass(400.0, 2600.0) if self.suit else BandPass()
        self.comp = Compressor()
        self.vox = VoxGate()
        self.keyed = False
        self.level_db = -90.0
        self.peak_db = -90.0
        self.gain = 0.0
        self.pending = np.zeros(0)
        self.ptt = False
        self.muted = False
        self.force = False           # ALL-CALL keys the commander channel
        self.talk_time = 0.0

    def _p(self, k, default=None):
        if self.mc:
            return {"mode": "vox", "vox_db": -55.0, "attack_ms": 5.0, "hang_ms": 350.0, "mic_gain": 1.0}.get(k, default)
        return self.cfg.get(f"{self.name}_{k}", default)

    def queue(self, snd):
        if len(snd) > len(self.pending):
            snd = snd.copy()
            snd[:len(self.pending)] += self.pending
            self.pending = snd
        else:
            self.pending = self.pending.copy()
            self.pending[:len(snd)] += snd

    def process(self, x):
        x = np.asarray(x, dtype=np.float64) * float(self._p("mic_gain", 1.0))
        n = len(x)
        lv = db(rms(x))
        self.level_db = lv
        self.peak_db = max(lv, self.peak_db - 1.5)
        self.vox.threshold_db = float(self._p("vox_db", -38.0))
        self.vox.attack_ms = float(self._p("attack_ms", 15.0))
        self.vox.hang_ms = float(self._p("hang_ms", 600.0))
        vox_open = self.vox.update(lv)
        mode = str(self._p("mode", "vox"))
        keyed = (self.ptt or self.force or (mode == "vox" and vox_open)) and not self.muted
        radio = bool(self.cfg.get("radio_fx", True))
        y = self.comp.process(self.radio.process(x)) if radio else x
        if radio:
            y = np.tanh(y * 1.6) / 1.6
        if keyed != self.keyed:
            beeps = bool(self.cfg.get("beeps", True))
            if keyed and beeps:
                self.queue(self.snd.quindar(True) if self.suit else self.snd.click())
            if not keyed:
                if beeps:
                    self.queue(self.snd.quindar(False) if self.suit else self.snd.roger())
                if radio and bool(self.cfg.get("squelch_tail", True)):
                    self.queue(np.concatenate([np.zeros(int(RATE * (0.14 if beeps else 0.0))), self.snd.squelch()]))
            self.keyed = keyed
        target = 1.0 if keyed else 0.0
        env = np.linspace(self.gain, target, n, endpoint=False) if self.gain != target else np.full(n, target)
        self.gain = target
        voice = y * env
        if keyed:
            self.talk_time += n / RATE
        tails = np.zeros(n)
        if len(self.pending):
            m = min(n, len(self.pending))
            tails[:m] = self.pending[:m]
            self.pending = self.pending[m:]
        if keyed and radio and bool(self.cfg.get("static", True)):
            tails += self.snd.static(n, -36.0 if self.suit else -44.0)
        return voice, tails


class Engine:
    """Pure DSP + routing, no I/O: feed one block per input, get one block per headset."""

    def __init__(self, cfg=None):
        self.voice_mix = np.zeros(BLOCK) if np else None
        self.cfg = dict(DEFAULTS)
        if cfg:
            self.cfg.update(cfg)
        self.snd = Sounds()
        self.ch = {s: Channel(s, self.cfg, self.snd) for s in SEATS}
        self.mc = Channel("mc", self.cfg, self.snd, mc=True)
        self.allcall = False
        self._allcall_prev = False
        self.extra = {s: np.zeros(0) for s in SEATS}     # one-off sounds per listener (ident, chime)
        self.duck = {s: 1.0 for s in SEATS}

    def set_cfg(self, values):
        self.cfg.update(values)

    def play(self, seat, snd):
        e = self.extra[seat]
        if len(snd) > len(e):
            snd = snd.copy()
            snd[:len(e)] += e
            self.extra[seat] = snd
        else:
            e = e.copy()
            e[:len(snd)] += snd
            self.extra[seat] = e

    def process(self, mics, game=None, mc=None, n=BLOCK):
        """mics: {seat: block or None}; game/mc: blocks (or None). Returns {seat: block}."""
        z = np.zeros(n)
        self.ch["commander"].force = self.allcall
        if self.allcall and not self._allcall_prev:
            for k in KIDS:
                self.play(k, self.snd.allcall())
        self._allcall_prev = self.allcall
        out_v, out_t = {}, {}
        for s in SEATS:
            x = mics.get(s)
            out_v[s], out_t[s] = self.ch[s].process(z if x is None else x)
        self.voice_mix = sum(out_v[s] for s in SEATS)
        mcv, mct = self.mc.process(z if mc is None else mc)
        g = z if game is None else np.asarray(game, dtype=np.float64)
        res = {}
        for s in SEATS:
            c = self.cfg
            ics = float(c.get(f"{s}_ics_vol", 1.0))
            gv = float(c.get(f"{s}_game_vol", 0.7))
            target_duck = float(c.get("allcall_duck", 0.25)) if (self.allcall and s in LISTENERS_DUCKED) else 1.0
            # smooth ducking so the PA does not click
            d = np.linspace(self.duck[s], target_duck, n, endpoint=False)
            self.duck[s] = target_duck
            y = g * gv * d
            y = y + (mcv + mct) * float(c.get("mc_vol", 0.9)) * ics
            for t in SEATS:
                if t == s:
                    continue
                w = ics
                if self.allcall and s in LISTENERS_DUCKED:
                    w *= 1.25 if t == "commander" else float(c.get("allcall_duck", 0.25))
                y = y + (out_v[t] + out_t[t]) * w
            st = float(c.get(f"{s}_sidetone", 0.0))
            if st > 0.0:
                y = y + out_v[s] * st
            e = self.extra[s]
            if len(e):
                m = min(n, len(e))
                y[:m] += e[:m]
                self.extra[s] = e[m:]
            peak = float(np.max(np.abs(y))) if len(y) else 0.0
            if peak > 0.85:                       # soft limiter
                y = np.tanh(y / 0.85) * 0.85
            res[s] = y
        return res

    def status(self):
        return {s: {"level": round(self.ch[s].level_db, 1), "peak": round(self.ch[s].peak_db, 1),
                    "open": self.ch[s].keyed, "muted": self.ch[s].muted, "ptt": self.ch[s].ptt,
                    "mode": str(self.cfg.get(f"{s}_mode", "vox"))} for s in SEATS} | {
            "mc": {"level": round(self.mc.level_db, 1), "open": self.mc.keyed}}


# ============================================================================ rings (clock drift)
class Ring:
    """Single-producer/single-consumer sample FIFO with gentle drift control: when the fill
    drifts more than a quarter block from the target, read() resamples n+1 or n-1 samples into n
    (one sample per 10 ms block = up to 2000 ppm, inaudible). Target ~30 ms of cushion.."""

    def __init__(self, target=BLOCK * 3, cap=RATE):
        self.buf = np.zeros(cap)
        self.r = 0
        self.w = 0
        self.cap = cap
        self.target = target
        self.lock = threading.Lock()
        self.underruns = 0
        self.overruns = 0
        self.adjust = 0
        self.primed = False

    def fill(self):
        return self.w - self.r

    def write(self, x):
        x = np.asarray(x, dtype=np.float64)
        with self.lock:
            if self.fill() + len(x) > self.cap:        # consumer gone: keep the newest audio
                self.r = self.w + len(x) - self.target
                self.overruns += 1
            i = self.w % self.cap
            k = min(len(x), self.cap - i)
            self.buf[i:i + k] = x[:k]
            self.buf[:len(x) - k] = x[k:]
            self.w += len(x)

    def _take(self, m):
        i = self.r % self.cap
        k = min(m, self.cap - i)
        out = np.concatenate([self.buf[i:i + k], self.buf[:m - k]])
        self.r += m
        return out

    def read(self, n=BLOCK):
        with self.lock:
            f = self.fill()
            if not self.primed:
                if f < self.target:
                    return None
                self.primed = True
            if f < n:
                self.underruns += 1
                self.primed = False            # re-buffer to the target
                part = self._take(f) if f > 0 else np.zeros(0)
                return np.concatenate([part, np.zeros(n - len(part))])
            if f > self.target * 4 + n:        # far behind (stall): jump to the target
                self.r = self.w - self.target
                self.overruns += 1
                f = self.fill()
            m = n
            if f > self.target + n // 4 and f >= n + 1:
                m = n + (2 if f > self.target + n and f >= n + 2 else 1)
            elif f < self.target - n // 4 and f >= n - 1:
                m = n - (2 if f < self.target - n // 2 else 1)
            seg = self._take(m)
        if m != n:
            self.adjust += 1
            seg = np.interp(np.linspace(0, m - 1, n), np.arange(m), seg)
        return seg


# ============================================================================ PulseAudio / PipeWire
def run(cmd, timeout=5.0):
    env = dict(os.environ, LC_ALL="C")
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=env)
        return p.returncode, p.stdout
    except (OSError, subprocess.TimeoutExpired) as e:
        return -1, str(e)


def parse_pactl_list(text):
    """Parse `pactl list sinks|sources` (LC_ALL=C) into [{name, description, props{}}]."""
    items, cur, in_props = [], None, False
    for raw in text.splitlines():
        line = raw.strip()
        if re.match(r"^(Sink|Source) #\d+", raw):
            cur = {"index": int(raw.split("#")[1]), "name": "", "description": "", "props": {}}
            items.append(cur)
            in_props = False
            continue
        if cur is None:
            continue
        if line.startswith("Name:"):
            cur["name"] = line[5:].strip()
        elif line.startswith("Description:"):
            cur["description"] = line[12:].strip()
        elif line.startswith("Sample Specification:"):
            cur["spec"] = line[21:].strip()
        elif line.startswith("Mute:"):
            cur["mute"] = line[5:].strip()
        elif line.startswith("State:"):
            cur["state"] = line[6:].strip()
        elif line.startswith("Properties:"):
            in_props = True
        elif in_props:
            m = re.match(r'^([\w.\-]+) = "(.*)"$', line)
            if m:
                cur["props"][m.group(1)] = m.group(2)
            elif line and not raw.startswith("\t\t") and ":" in line:
                in_props = False
    return items


def headsets_from(sinks, sources):
    """Group USB sinks + sources into headsets. Returns [{id, label, product, serial, path,
    sink, source}]; id = "product|serial|path" (stable over replug and re-ordering)."""
    def bus_path(p):           # PulseAudio: device.bus_path, PipeWire: device.bus-path (either may appear)
        return p.get("device.bus_path") or p.get("device.bus-path") or ""

    def key(it):
        p = it["props"]
        if bus_path(p):
            return bus_path(p)
        if p.get("alsa.card"):
            return "alsa-card-" + p["alsa.card"]
        return p.get("sysfs.path") or p.get("device.string") or it["name"]

    hs = {}
    for kind, items in (("sink", sinks), ("source", sources)):
        for it in items:
            p = it["props"]
            if it["name"].endswith(".monitor") or p.get("device.class") == "monitor":
                continue
            usb = p.get("device.bus") == "usb" or ".usb-" in it["name"]
            wivrn = is_wivrn(it)
            if it["name"].startswith("falcon_") or not (usb or wivrn):
                continue
            if wivrn:
                h = hs.setdefault("wivrn", {"product": "Meta Quest (WiVRn)", "serial": "", "path": "wivrn", "vendor": "WiVRn",
                                            "sink": "", "source": "", "label": ""})
                if kind == "sink" and not h["sink"]:
                    h["sink"] = it["name"]
                if kind == "source" and not h["source"]:
                    h["source"] = it["name"]
                continue
            k = key(it)
            h = hs.setdefault(k, {"product": p.get("device.product.name") or p.get("api.alsa.card.name") or p.get("alsa.card_name")
                                  or it["description"],
                                  "serial": p.get("device.serial", ""), "path": bus_path(p),
                                  "vendor": p.get("device.vendor.name", ""), "sink": "", "source": "",
                                  "label": ""})
            if not h[kind] or (_node_rank(it["name"]) < _node_rank(h[kind])):
                h[kind] = it["name"]
    out = []
    for h in hs.values():
        port = re.search(r"usb-[\d:.\-]+", h["path"] or "")
        h["id"] = f'{h["product"]}|{h["serial"]}|{h["path"]}'
        h["label"] = h["product"] + (f'  (USB {port.group(0)[4:]})' if port else "")
        if h["path"] == "wivrn":
            h["label"] = "Meta Quest 3 (WiVRn audio)" + ("" if h["source"] else "  · mic off in the headset app")
        out.append(h)
    out.sort(key=lambda h: (h["product"], h["path"], h["serial"]))
    # identical headsets: make labels unique so the Commander can tell them apart
    seen = {}
    for h in out:
        seen[h["label"]] = seen.get(h["label"], 0) + 1
    for h in out:
        if seen[h["label"]] > 1:
            h["label"] += f' #{h["sink"][-6:] or h["source"][-6:]}'
    return out


def _node_rank(name):
    """Lower = the node to use when one USB card exposes several (analog before digital/pro)."""
    n = name.lower()
    return 2 if ("iec958" in n or "hdmi" in n or "pro-" in n) else (0 if "analog" in n or "mono" in n else 1)


def spec_channels(spec):
    m = re.search(r"(\d+)ch", spec or "")
    return int(m.group(1)) if m else 2


def sink_channels(spec):
    """Channels to open the sink with. Mono stays mono; 5.1/7.1 stay native (a stereo
    stream with an explicit map is rejected by PipeWire). Anything else is stereo."""
    ch = spec_channels(spec)
    return ch if 1 <= ch <= 8 else 2


def split_choice(choice):
    """Saved pick -> (node name, bus path, short port).

    New picks: "node@bus=pci-0000:00:14.0-usb-0:3:1.0" (the whole USB path; the short
    port number collides across controllers). Older picks: "node@port=3" or a bare name.
    """
    choice = choice or ""
    if "@bus=" in choice:
        name, bus = choice.split("@bus=", 1)
        return name, bus, ""
    if "@port=" in choice:
        name, port = choice.split("@port=", 1)
        return name, "", port
    return choice, "", ""


def _family(name):
    """Node name without the trailing ".2" counter Pulse/PipeWire append when two cards
    share a USB id. Does NOT strip ".1" in the middle of a name (HDMI port, "pro-output-0"),
    so analog and iec958 on the same dongle stay different devices."""
    return re.sub(r"\.\d+$", "", name or "")


def _bus_path(props):
    return props.get("device.bus_path") or props.get("device.bus-path") or ""


def _short_port(bus):
    m = re.search(r"usbv?\d*-\d+:([\d.]+):", bus or "")
    return m.group(1) if m else ""


def _device_key(name, bus, port):
    if bus:
        return name + "@bus=" + bus
    if port:
        return name + "@port=" + port
    return name


def plain_list(items):
    """Every real source/sink (no monitors, none of ours) for the MIC IN / AUDIO OUT pickers.
    The saved key is the node name plus the USB bus path, so a ".2" rename still finds the
    same jack and a second profile on that jack (analog vs digital) stays a different pick."""
    out = []
    for it in items:
        p = it["props"]
        if it["name"].endswith(".monitor") or p.get("device.class") == "monitor" or it["name"].startswith("falcon_"):
            continue
        bus = _bus_path(p)
        port = _short_port(bus)
        out.append({"name": it["name"], "desc": it["description"] or it["name"], "spec": it.get("spec", ""),
                    "bus": bus, "port": port, "key": _device_key(it["name"], bus, port),
                    "ch": sink_channels(it.get("spec", "")),
                    "mute": it.get("mute", ""), "state": it.get("state", "")})
    return out


def _match_group(cands, name, used):
    """The saved node inside one physical device. Same profile only (family): never the
    other output on that jack (analog picked, digital returned). Empty if it isn't here
    or several free nodes still match (two controllers that reported the same short port)."""
    free = [d for d in cands if d["name"] not in used]
    exact = [d for d in free if d["name"] == name]
    if exact:
        return exact[0]["name"]
    fam = [d for d in free if _family(d["name"]) == _family(name)]
    if len(fam) == 1:
        return fam[0]["name"]
    return ""


def resolve(choice, lst, default_name, used=(), strict=False):
    """choice: "" (follow the seat's headset), "none", "default", or a node name. Returns a
    device name, "" (nothing) or None (= use the headset). Falls back from name to description."""
    if choice in ("", None):
        return None
    if choice == "none":
        return ""
    if choice == "default":
        return default_name
    name, bus, port = split_choice(choice)
    used = set(used)
    if bus:
        hit = _match_group([d for d in lst if d.get("bus") == bus], name, used)
        if hit:
            return hit
        if strict:
            return ""
    elif port:
        group = [d for d in lst if d.get("port") == port]
        hit = _match_group(group, name, used)
        if hit:
            return hit
        if strict:
            return ""          # first pass: this USB port only, never a different profile
    rest = [d for d in lst if d["name"] not in used]
    names = [d["name"] for d in rest]
    if name in names:
        return name
    for d in rest:                         # name changed between boots: same description
        if d["desc"] == name or d["desc"] == choice:
            return d["name"]
    # same card, different profile (Snowball analog-stereo -> mono-fallback). Only when the
    # core matches exactly one device in the whole list: if a taken twin also matches, the
    # remaining one is the other headset and must not be guessed.
    core = name.split(".")[1] if name.count(".") >= 2 else ""
    all_core = [d["name"] for d in lst if core and core in d["name"]]
    free_core = [n for n in all_core if n not in used]
    if len(all_core) == 1 and free_core:
        return free_core[0]
    return ""


def is_wivrn(it):
    """WiVRn's virtual speaker ("WiVRn") / microphone ("WiVRn(microphone)") while a headset is
    connected (PulseAudio module or PipeWire node, depending on the system)."""
    p = it.get("props", {})
    txt = " ".join([it.get("name", ""), it.get("description", ""), p.get("node.name", ""), p.get("node.description", ""),
                    p.get("application.name", ""), p.get("device.description", "")]).lower()
    return "wivrn" in txt


def match_assignments(devs, saved):
    """saved: {seat: id string}. Returns {seat: device or None}. Match order per seat: exact id;
    product + serial (when the serial is unique); USB port path (identical headsets plugged
    into the same ports); product name when only one such headset is left."""
    out, used = {}, set()

    def free(d):
        return d["id"] not in used

    def parts(sid):
        p = (sid or "").split("|")
        return (p + ["", "", ""])[:3]

    for rule in range(4):
        for seat in SEATS:
            if seat in out or not saved.get(seat):
                continue
            prod, ser, path = parts(saved[seat])
            cands = []
            for d in devs:
                if not free(d):
                    continue
                if rule == 0 and d["id"] == saved[seat]:
                    cands.append(d)
                elif rule == 1 and ser and d["serial"] == ser and d["product"] == prod and \
                        sum(1 for e in devs if e["serial"] == ser and e["product"] == prod) == 1:
                    cands.append(d)
                elif rule == 2 and path and d["path"] == path:
                    cands.append(d)
                elif rule == 3 and d["product"] == prod:
                    cands.append(d)
            if rule == 3 and len(cands) != 1:
                continue
            if cands:
                out[seat] = cands[0]
                used.add(cands[0]["id"])
    # the Quest (WiVRn audio) belongs to the spacewalker unless the Commander chose otherwise
    if "eva" in SEATS and "eva" not in out and not saved.get("eva"):
        q = next((d for d in devs if d.get("path") == "wivrn" and free(d)), None)
        if q:
            out["eva"] = q
            used.add(q["id"])
    return {s: out.get(s) for s in SEATS}


class Pulse:
    def __init__(self):
        self.modules = []

    def available(self):
        missing = [c for c in ("pactl", "parec", "pacat") if shutil.which(c) is None]
        if missing:
            return False, "missing %s (sudo apt install pulseaudio-utils)" % ", ".join(missing)
        rc, out = run(["pactl", "info"])
        if rc != 0:
            return False, "no PulseAudio/PipeWire server (on PipeWire: sudo apt install pipewire-pulse)"
        return True, out

    @staticmethod
    def server_name(info):
        m = re.search(r"Server Name: (.+)", info)
        return m.group(1).strip() if m else "unknown"

    @staticmethod
    def default_sink(info):
        m = re.search(r"Default Sink: (.+)", info)
        return m.group(1).strip() if m else ""

    def list(self, what):
        rc, out = run(["pactl", "list", what])
        return parse_pactl_list(out) if rc == 0 else []

    def cleanup_stale(self):
        rc, out = run(["pactl", "list", "short", "modules"])
        if rc != 0:
            return
        for line in out.splitlines():
            if "falcon_game" in line or "falcon_mc" in line or "falcon_ics" in line:
                run(["pactl", "unload-module", line.split()[0]])

    def load(self, *args):
        rc, out = run(["pactl", "load-module", *args])
        if rc == 0 and out.strip().isdigit():
            self.modules.append(out.strip())
            return out.strip()
        log("load-module failed:", " ".join(args), out.strip())
        return None

    def unload_all(self):
        for m in reversed(self.modules):
            run(["pactl", "unload-module", m])
        self.modules.clear()


class Capture(threading.Thread):
    """parec -> Ring. Restarts the recorder if the device disappears (replug)."""

    def __init__(self, device, ring, name, latency_ms=20):
        super().__init__(daemon=True, name="cap-" + name)
        self.device, self.ring, self.latency_ms = device, ring, latency_ms
        self.proc = None
        self.stop = False

    def run(self):
        while not self.stop:
            cmd = ["parec", "--raw", "--format=s16le", f"--rate={RATE}", "--channels=1",
                   f"--latency-msec={self.latency_ms}", f"--device={self.device}", "--client-name=falcon-ics",
                   "--stream-name=" + self.name]
            try:
                self.proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            except OSError:
                return
            nbytes = BLOCK * 2
            while not self.stop:
                b = self.proc.stdout.read(nbytes)
                if not b or len(b) < nbytes:
                    break
                self.ring.write(np.frombuffer(b, dtype="<i2").astype(np.float64) / 32768.0)
            self.kill()
            if not self.stop:
                time.sleep(1.0)

    def kill(self):
        if self.proc and self.proc.poll() is None:
            self.proc.kill()

    def close(self):
        self.stop = True
        self.kill()


class Playback(threading.Thread):
    """Ring -> pacat. The sink's clock paces the blocking write; the ring absorbs drift."""

    def __init__(self, device, ring, name, latency_ms=30, channels=1):
        super().__init__(daemon=True, name="play-" + name)
        self.device, self.ring, self.latency_ms = device, ring, latency_ms
        self.channels = channels
        self.proc = None
        self.stop = False
        self.name_ = name
        self.state = "opening"
        self.err = ""
        self.restarts = 0
        self.last_write = 0.0

    def stream_state(self):
        if self.state == "error":
            return "error"
        return "playing" if time.monotonic() - self.last_write < 0.5 else self.state

    def run(self):
        while not self.stop:
            cmd = ["pacat", "--playback", "--raw", "--format=s16le", f"--rate={RATE}", f"--channels={self.channels}",
                   f"--latency-msec={self.latency_ms}", f"--device={self.device}", "--client-name=falcon-ics",
                   "--stream-name=ICS " + self.name_]
            if self.channels == 2:
                cmd.append("--channel-map=front-left,front-right")
            try:
                self.proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stderr=subprocess.PIPE)
            except OSError as e:
                self.state, self.err = "error", str(e)
                log(f"{self.name_}: OUTPUT stream failed to start: {e}")
                return
            self.state = "opening"
            try:
                while not self.stop:
                    x = self.ring.read(BLOCK)
                    if x is None:
                        x = np.zeros(BLOCK)
                        time.sleep(BLOCK / RATE * 0.5)
                    pcm = (np.clip(x, -1, 1) * 32767).astype("<i2")
                    if self.channels > 1:
                        pcm = np.repeat(pcm, self.channels)   # same voice in every channel
                    self.proc.stdin.write(pcm.tobytes())
                    self.proc.stdin.flush()
                    self.last_write = time.monotonic()
            except (BrokenPipeError, OSError, ValueError):
                pass
            self.kill()
            if not self.stop:
                try:
                    self.err = (self.proc.stderr.read() or b"").decode(errors="replace").strip()[-200:]
                except (OSError, ValueError):
                    self.err = ""
                self.state = "error"
                self.restarts += 1
                if self.restarts <= 3 or self.restarts % 30 == 0:
                    log(f"{self.name_}: OUTPUT stream to {self.device} closed (restart {self.restarts}): {self.err or 'no message'}")
                time.sleep(1.0)

    def kill(self):
        if self.proc and self.proc.poll() is None:
            self.proc.kill()

    def close(self):
        self.stop = True
        self.kill()


SEAT_TITLES = {"pilot": "Pilot", "ops": "Ops", "commander": "Commander", "eva": "Spacewalker"}
_SAY_CACHE = {}


def say_samples(text):
    """Speech for IDENTIFY via espeak-ng/espeak (if installed) -> float mono at RATE, or None."""
    if text in _SAY_CACHE:
        return _SAY_CACHE[text]
    exe = shutil.which("espeak-ng") or shutil.which("espeak")
    out = None
    if exe:
        import io
        import wave
        try:
            wav = subprocess.run([exe, "--stdout", "-s", "150", text], capture_output=True, timeout=5).stdout
            with wave.open(io.BytesIO(wav)) as w:
                sr, nch = w.getframerate(), w.getnchannels()
                x = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.float64) / 32768.0
            if nch > 1:
                x = x.reshape(-1, nch).mean(axis=1)
            if len(x):
                x = np.interp(np.arange(int(len(x) * RATE / sr)) * sr / RATE, np.arange(len(x)), x)
                out = x * (0.5 / max(1e-6, float(np.max(np.abs(x)))))
        except (OSError, subprocess.TimeoutExpired, wave.Error, EOFError, ValueError):
            out = None
    _SAY_CACHE[text] = out
    return out


def play_once(sink, samples):
    """Fire-and-forget playback of a short sound on one sink (IDENTIFY)."""
    if shutil.which("pacat") is None:
        return
    data = (np.clip(samples, -1, 1) * 32767).astype("<i2").tobytes()
    try:
        p = subprocess.Popen(["pacat", "--playback", "--raw", "--format=s16le", f"--rate={RATE}", "--channels=1",
                              f"--device={sink}", "--client-name=falcon-ics", "--stream-name=IDENTIFY"],
                             stdin=subprocess.PIPE, stderr=subprocess.DEVNULL)
        threading.Thread(target=lambda: (p.communicate(data, timeout=10)), daemon=True).start()
    except OSError:
        pass


# ============================================================================ mock audio (tests, screenshots)
class MockTalker:
    """Synthetic 'speech': band-limited noise bursts with syllable modulation, per seat."""

    def __init__(self, seed, period_s, duty):
        self.rng = np.random.default_rng(seed)
        self.t = 0.0
        self.period, self.duty = period_s, duty
        self.bp = BandPass(200, 3000)

    def block(self, n=BLOCK):
        ph = (self.t % self.period) / self.period
        self.t += n / RATE
        if ph > self.duty:
            return self.rng.standard_normal(n) * 0.0015
        syll = 0.5 + 0.5 * math.sin(2 * math.pi * 4.0 * self.t)
        return self.bp.process(self.rng.standard_normal(n)) * 0.25 * syll


# ============================================================================ the helper process
class Helper:
    def __init__(self, args):
        self.args = args
        self.cfg = load_config(args.settings)
        self.engine = Engine(self.cfg)
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.game_addr = ("127.0.0.1", args.game_port)
        self.pulse = Pulse()
        self.server = "mock" if args.mock else "?"
        self.ok = False
        self.msg = "starting"
        self.devs = []
        self.assign = {s: None for s in SEATS}
        self.caps, self.plays = {}, {}
        self.in_rings = {}
        self.out_rings = {}
        self.parent = args.parent_pid
        self.last_hello = time.monotonic()
        self.running = True
        self.lock = threading.Lock()
        self.mock = {s: MockTalker(i + 3, 2.6 + i * 0.9, 0.45) for i, s in enumerate(SEATS)} if args.mock else {}
        self.ticks = 0
        self.late = 0
        self.default_sink = ""
        self.rec = None              # Captain's Log recording: [path, [blocks], max_blocks]
        self.out_pk, self.out_max = {}, {}   # per-seat output peak (meter) / peak since the last log line

    # ---------------------------------------------------------------- setup
    def setup_audio(self):
        if self.args.mock:
            self.devs = [{"id": f"Mock Headset {i}|MOCK{i}|pci-0000:00:14.0-usb-0:{i}:1.0", "label": f"Mock Headset {i}  (USB 0:{i}:1.0)",
                          "product": f"Mock Headset {i}", "serial": f"MOCK{i}", "path": f"pci-0000:00:14.0-usb-0:{i}:1.0",
                          "sink": f"mock_sink_{i}", "source": f"mock_source_{i}"} for i in (1, 2, 3)]
            self.devs.append({"id": WIVRN_ID, "label": "Meta Quest 3 (WiVRn audio)", "product": "Meta Quest (WiVRn)", "serial": "",
                              "path": "wivrn", "sink": "mock_wivrn_sink", "source": "mock_wivrn_source"})
            self._rematch()
            self.ok, self.msg = True, "mock audio (no devices touched)"
            return True
        ok, info = self.pulse.available()
        if not ok:
            self.msg = info
            return False
        self.server = Pulse.server_name(info)
        self.default_sink = Pulse.default_sink(info)
        self.pulse.cleanup_stale()
        desc_g = "device.description=Falcon-Game-Audio"
        desc_m = "device.description=Falcon-Mission-Control"
        if not self.pulse.load("module-null-sink", f"sink_name={GAME_SINK}", f"sink_properties={desc_g}",
                               f"rate={RATE}", "channels=2"):
            self.msg = "could not create the falcon_game sink"
            return False
        self.pulse.load("module-null-sink", f"sink_name={MC_SINK}", f"sink_properties={desc_m}", f"rate={RATE}", "channels=1")
        self.in_rings["game"] = Ring()
        self.in_rings["mc"] = Ring()
        self.caps["game"] = Capture(GAME_SINK + ".monitor", self.in_rings["game"], "game")
        self.caps["mc"] = Capture(MC_SINK + ".monitor", self.in_rings["mc"], "mc")
        for c in self.caps.values():
            c.start()
        self._speakers()
        self.rescan()
        self.ok = True
        self.msg = "running on " + self.server
        return True

    def _speakers(self):
        for m in list(getattr(self, "_spk_mods", [])):
            run(["pactl", "unload-module", m])
            if m in self.pulse.modules:
                self.pulse.modules.remove(m)
        self._spk_mods = []
        if self.args.mock or not bool(self.cfg.get("speakers", True)):
            return
        headset_sinks = {d["sink"] for d in self.devs}
        if not self.default_sink or self.default_sink in headset_sinks or self.default_sink.startswith("falcon_"):
            return
        for src in (GAME_SINK, MC_SINK):
            m = self.pulse.load("module-loopback", f"source={src}.monitor", f"sink={self.default_sink}",
                                "latency_msec=40", "source_dont_move=true", "sink_dont_move=true")
            if m:
                self._spk_mods.append(m)

    def rescan(self):
        if self.args.mock:
            return
        sinks, sources = self.pulse.list("sinks"), self.pulse.list("sources")
        self.devs = headsets_from(sinks, sources)
        self.inputs = plain_list(sources)
        self.outputs = plain_list(sinks)
        self._rematch()

    def _rematch(self):
        saved = {s: str(self.cfg.get(f"{s}_headset", "")) for s in SEATS}
        new = match_assignments(self.devs, saved)
        info = run(["pactl", "info"])[1]
        dsrc = (re.search(r"Default Source: (.+)", info) or [None, ""])[1].strip()
        dsink = Pulse.default_sink(info)
        if not hasattr(self, "routes"):
            self.routes = {}
        used_in, used_out = set(), set()
        picked = {}
        for s in SEATS:   # explicit picks first (resolved by USB port), so a headset never takes a device another seat chose
            for kind, used, lst, dflt in (("in", used_in, getattr(self, "inputs", []), dsrc),
                                          ("out", used_out, getattr(self, "outputs", []), dsink)):
                v = str(self.cfg.get(f"{s}_{kind}", ""))
                if v not in ("", "none", "default"):
                    picked[(s, kind)] = resolve(v, lst, dflt, used, strict=True)
                    if picked[(s, kind)]:
                        used.add(picked[(s, kind)])
        for s in SEATS:   # 2nd pass: picks whose USB port is empty fall back by name, never onto a taken device
            for kind, used, lst, dflt in (("in", used_in, getattr(self, "inputs", []), dsrc),
                                          ("out", used_out, getattr(self, "outputs", []), dsink)):
                if picked.get((s, kind)) == "":
                    picked[(s, kind)] = resolve(str(self.cfg.get(f"{s}_{kind}", "")), lst, dflt, used)
                    if picked[(s, kind)]:
                        used.add(picked[(s, kind)])
        for s in SEATS:
            hs = new.get(s) or {}
            src = picked[(s, "in")] if (s, "in") in picked else resolve(str(self.cfg.get(f"{s}_in", "")), getattr(self, "inputs", []), dsrc, used_in)
            snk = picked[(s, "out")] if (s, "out") in picked else resolve(str(self.cfg.get(f"{s}_out", "")), getattr(self, "outputs", []), dsink, used_out)
            if src is None:
                src = hs.get("source", "")
                src = "" if src in used_in else src
            if snk is None:
                snk = hs.get("sink", "")
                snk = "" if snk in used_out else snk
            if src and src != dsrc:
                used_in.add(src)
            if snk and snk != dsink:
                used_out.add(snk)
            route = (src, snk)
            if self.routes.get(s) != route:
                log(f"{s}: route  in={src or '-'}  out={snk or '-'}  (picked in={self.cfg.get(s + '_in', '') or 'headset'}"
                    f" out={self.cfg.get(s + '_out', '') or 'headset'}; default sink {dsink or '?'})")
            pl = self.plays.get(s)
            dead = (snk and (pl is None or not pl.is_alive())) or (src and (s not in self.caps or not self.caps[s].is_alive()))
            if self.routes.get(s) != route or (any(route) and not self.args.mock and dead):
                self._attach(s, {"source": route[0], "sink": route[1], "label": hs.get("label") or (route[0] or route[1] or "none")} if any(route) else None)
                self.routes[s] = route
        self.assign = new
        self._send_devices()

    def _send_devices(self):
        self.send({"type": "devices", "list": self.devs, "assign": {s: (d["id"] if d else "") for s, d in self.assign.items()},
                   "inputs": getattr(self, "inputs", []), "outputs": getattr(self, "outputs", []),
                   "routes": {s: list(r) for s, r in getattr(self, "routes", {}).items()}})

    def _attach(self, seat, dev):
        for d in (self.caps, self.plays):
            if seat in d:
                d.pop(seat).close()
        self.in_rings.pop(seat, None)
        self.out_rings.pop(seat, None)
        if dev is None or self.args.mock:
            return
        if dev.get("source"):
            spec = next((d.get("spec", "") for d in getattr(self, "inputs", []) if d["name"] == dev["source"]), "?")
            # a muted or suspended source records pure silence: wake it (logged)
            if not dev["source"].startswith("@"):
                run(["pactl", "suspend-source", dev["source"], "0"])
                rc, out = run(["pactl", "get-source-mute", dev["source"]])
                if "yes" in out:
                    run(["pactl", "set-source-mute", dev["source"], "0"])
                    log(f"{seat}: source was MUTED in the system mixer; unmuted it")
            log(f"{seat}: INPUT {dev['source']}  native [{spec}] -> captured as s16le 48000 Hz mono (server converts)")
            self.in_rings[seat] = Ring()
            self.caps[seat] = Capture(dev["source"], self.in_rings[seat], seat)
            self.caps[seat].start()
        if dev.get("sink"):
            o = next((d for d in getattr(self, "outputs", []) if d["name"] == dev["sink"]), {})
            ch = sink_channels(o.get("spec", "")) if o else 2
            if not dev["sink"].startswith("@"):
                run(["pactl", "suspend-sink", dev["sink"], "0"])
                if "yes" in run(["pactl", "get-sink-mute", dev["sink"]])[1]:
                    run(["pactl", "set-sink-mute", dev["sink"], "0"])
                    log(f"{seat}: sink was MUTED in the system mixer; unmuted it")
                vol = re.findall(r"(\d+)%", run(["pactl", "get-sink-volume", dev["sink"]])[1])
                if vol and max(int(v) for v in vol) < 5:
                    log(f"{seat}: WARNING sink volume is {max(int(v) for v in vol)}% in the system mixer")
            log(f"{seat}: OUTPUT {dev['sink']}  native [{o.get('spec', '?')}] state {o.get('state', '?')} -> s16le 48000 Hz {ch}ch")
            self.out_rings[seat] = Ring()
            self.plays[seat] = Playback(dev["sink"], self.out_rings[seat], seat, channels=ch)
            self.plays[seat].start()
        log(f"{seat}: {dev['label']}")

    # ---------------------------------------------------------------- UDP
    def send(self, obj):
        try:
            self.sock.sendto(json.dumps(obj).encode(), self.game_addr)
        except OSError:
            pass

    def handle(self, msg):
        cmd = msg.get("cmd")
        self.last_hello = time.monotonic()
        if cmd == "hello":
            if msg.get("pid"):
                self.parent = int(msg["pid"])
            if isinstance(msg.get("values"), dict):
                self.apply_cfg(msg["values"])
            self._send_devices()
        elif cmd == "cfg":
            self.apply_cfg(msg.get("values", {}))
        elif cmd == "state":
            with self.lock:
                for s, v in (msg.get("ptt") or {}).items():
                    if s in self.engine.ch:
                        self.engine.ch[s].ptt = bool(v)
                for s, v in (msg.get("mute") or {}).items():
                    if s in self.engine.ch:
                        self.engine.ch[s].muted = bool(v)
                self.engine.allcall = bool(msg.get("allcall", False))
        elif cmd == "ident" and msg.get("seat") in SEATS:
            self.ident_seat(msg["seat"])
        elif cmd == "ident":
            dev = next((d for d in self.devs if d["id"] == msg.get("device")), None)
            if dev and not self.args.mock:
                play_once(dev["sink"], self.engine.snd.ident())
            self.send({"type": "ident", "device": dev["id"] if dev else ""})
        elif cmd == "rescan":
            self.rescan()
        elif cmd == "record":
            with self.lock:
                self.rec = [str(msg.get("path", "")), [], int(float(msg.get("max_s", 90)) * RATE / BLOCK)]
        elif cmd == "record_stop":
            self.finish_record()
        elif cmd == "quit":
            self.running = False

    def ident_seat(self, seat):
        """IDENTIFY a station: chime + "<Seat> station" mixed into that seat's own output, so it
        plays through exactly the AUDIO OUT stream the station hears (not the mic's headset)."""
        sink = (getattr(self, "routes", {}).get(seat) or ("", ""))[1]
        with self.lock:
            self.engine.play(seat, self.engine.snd.ident())
        log(f"{seat}: IDENTIFY -> {sink or '(no output device)'}  stream {self.out_state(seat)}")
        self.send({"type": "ident", "seat": seat, "sink": sink, "state": self.out_state(seat)})

        def speak():
            v = say_samples(SEAT_TITLES.get(seat, seat) + " station")
            if v is not None:
                with self.lock:
                    self.engine.play(seat, np.concatenate([np.zeros(int(RATE * 0.75)), v]))
        threading.Thread(target=speak, daemon=True).start()

    def out_state(self, seat):
        if self.args.mock:
            return "mock"
        pl = self.plays.get(seat)
        return pl.stream_state() if pl else "none"

    def finish_record(self):
        with self.lock:
            rec, self.rec = self.rec, None
        if not rec or not rec[0]:
            return
        import wave
        x = np.concatenate(rec[1]) if rec[1] else np.zeros(RATE // 10)
        peak = float(np.max(np.abs(x))) or 1.0
        pcm = (np.clip(x * min(4.0, 0.9 / peak), -1.0, 1.0) * 32767).astype("<i2")
        try:
            os.makedirs(os.path.dirname(rec[0]), exist_ok=True)
            with wave.open(rec[0], "wb") as w:
                w.setnchannels(1)
                w.setsampwidth(2)
                w.setframerate(RATE)
                w.writeframes(pcm.tobytes())
            log("captain's log saved", rec[0], f"{len(x) / RATE:.1f} s")
        except OSError as ex:
            log("captain's log failed", ex)
        self.send({"type": "record", "path": rec[0], "secs": round(len(x) / RATE, 1)})

    def apply_cfg(self, values):
        with self.lock:
            changed_dev = any((k.endswith("_headset") or k.endswith("_in") or k.endswith("_out")) and self.cfg.get(k) != v for k, v in values.items())
            spk = "speakers" in values and bool(values["speakers"]) != bool(self.cfg.get("speakers"))
            self.cfg.update(values)
            self.engine.set_cfg(values)
        if changed_dev:
            self._rematch()
        if spk:
            self._speakers()

    def udp_loop(self):
        while self.running:
            try:
                data, _ = self.sock.recvfrom(65536)
            except socket.timeout:
                continue
            except OSError:
                break
            try:
                msg = json.loads(data.decode())
            except ValueError:
                continue
            if isinstance(msg, dict):
                self.handle(msg)

    # ---------------------------------------------------------------- audio loop
    def tick(self):
        mics = {}
        for s in SEATS:
            if self.mock:
                mics[s] = self.mock[s].block()
            elif s in self.in_rings:
                mics[s] = self.in_rings[s].read(BLOCK)
        game = self.in_rings["game"].read(BLOCK) if "game" in self.in_rings else None
        mc = self.in_rings["mc"].read(BLOCK) if "mc" in self.in_rings else None
        with self.lock:
            outs = self.engine.process(mics, game, mc)
            if self.rec is not None:
                self.rec[1].append(self.engine.voice_mix.copy())
                stop = len(self.rec[1]) >= self.rec[2]
            else:
                stop = False
        if stop:
            self.finish_record()
        for s, y in outs.items():
            pk = float(np.max(np.abs(y))) if len(y) else 0.0
            self.out_pk[s] = max(pk, self.out_pk.get(s, 0.0) * 0.93)       # ~150 ms fall
            self.out_max[s] = max(pk, self.out_max.get(s, 0.0))
            if s in self.out_rings:
                self.out_rings[s].write(y)

    def status(self):
        st = self.engine.status()
        for s in SEATS:
            d = self.assign.get(s)
            st[s]["device"] = d["label"] if d else ""
            st[s]["connected"] = d is not None
            st[s]["out_level"] = round(db(self.out_pk.get(s, 0.0)), 1)
            st[s]["out_state"] = self.out_state(s)
            st[s]["out_sink"] = (getattr(self, "routes", {}).get(s) or ("", ""))[1]
        xr = sum(r.underruns for r in self.in_rings.values()) + sum(r.underruns for r in self.out_rings.values())
        return {"type": "status", "ok": self.ok, "msg": self.msg, "server": self.server, "seats": st,
                "allcall": self.engine.allcall, "xruns": xr, "late": self.late, "mock": bool(self.args.mock),
                "game_sink": GAME_SINK if self.ok and not self.args.mock else "", "mc_sink": MC_SINK if self.ok and not self.args.mock else "",
                "latency_ms": 55 if not self.args.mock else 0}

    def parent_alive(self):
        if not self.parent:
            return True
        try:
            os.kill(self.parent, 0)
            return True
        except OSError:
            return False

    def main(self):
        try:
            self.sock.bind(("127.0.0.1", self.args.port))
        except OSError as e:
            log(f"UDP port {self.args.port} busy ({e}); another ICS helper running?")
            return 0
        self.sock.settimeout(0.5)
        threading.Thread(target=self.udp_loop, daemon=True).start()
        started = self.setup_audio()
        log(self.msg)
        if self.args.setup_only:
            return 0 if started else 1
        period = BLOCK / RATE
        nxt = time.monotonic()
        last_status = 0.0
        last_scan = time.monotonic()
        try:
            while self.running:
                now = time.monotonic()
                if started:
                    self.tick()
                    self.ticks += 1
                    nxt += period
                    delay = nxt - time.monotonic()
                    if delay > 0:
                        time.sleep(delay)
                    elif delay < -period * 8:
                        self.late += 1
                        nxt = time.monotonic()
                else:
                    time.sleep(0.2)
                if now - last_status > 1 / 15:
                    last_status = now
                    self.send(self.status())
                    if started and now - getattr(self, "_lvl_t", 0.0) > 10.0:
                        self._lvl_t = now
                        st = self.engine.status()
                        log("levels: " + "  ".join(f"{s}={st[s].get('level', -90):.0f}dB{'(open)' if st[s].get('open') else ''}"
                                                   f"[{(getattr(self, 'routes', {}).get(s) or ('', ''))[0] or '-'}]" for s in SEATS))
                        log("outputs: " + "  ".join(f"{s}={db(self.out_max.get(s, 0.0)):.0f}dB {self.out_state(s)}"
                                                    f"[{(getattr(self, 'routes', {}).get(s) or ('', ''))[1] or '-'}]" for s in SEATS))
                        self.out_max = {}
                    if not self.parent_alive():
                        log("game exited; stopping")
                        break
                if started and now - last_scan > 3.0:          # hot-plug: re-match headsets
                    last_scan = now
                    self.rescan()
        finally:
            self.shutdown()
        return 0

    def shutdown(self):
        self.running = False
        for d in (self.caps, self.plays):
            for t in d.values():
                t.close()
        if not self.args.mock:
            self.pulse.unload_all()


# ============================================================================ CLI tools
def cli_list():
    p = Pulse()
    ok, info = p.available()
    if not ok:
        print(info)
        return 1
    print("server:", Pulse.server_name(info), "  default sink:", Pulse.default_sink(info))
    devs = headsets_from(p.list("sinks"), p.list("sources"))
    cfg = load_config()
    asg = match_assignments(devs, {s: str(cfg.get(f"{s}_headset", "")) for s in SEATS})
    if not devs:
        print("no USB headsets found")
    for d in devs:
        seat = next((s for s, a in asg.items() if a and a["id"] == d["id"]), "-")
        print(f"[{seat:9}] {d['label']}\n            sink   {d['sink']}\n            source {d['source']}\n            id     {d['id']}")
    return 0


def cli_ident(which):
    p = Pulse()
    ok, _ = p.available()
    if not ok:
        return 1
    devs = headsets_from(p.list("sinks"), p.list("sources"))
    cfg = load_config()
    if which in SEATS:
        d = match_assignments(devs, {s: str(cfg.get(f"{s}_headset", "")) for s in SEATS})[which]
    else:
        d = next((x for x in devs if which in (x["id"], x["sink"], x["label"])), None)
    if not d:
        print("not found:", which)
        return 1
    snd = Sounds().ident()
    subprocess.run(["pacat", "--playback", "--raw", "--format=s16le", f"--rate={RATE}", "--channels=1", f"--device={d['sink']}"],
                   input=(snd * 32767).astype("<i2").tobytes(), check=False)
    print("played on", d["label"])
    return 0


def cli_latency(seat):
    """Plays a click into SEAT's headset and listens on the same headset's mic (hold the mic to
    the earcup). Measures the round trip through PulseAudio/PipeWire (one helper hop is ~ half)."""
    p = Pulse()
    ok, _ = p.available()
    if not ok:
        return 1
    devs = headsets_from(p.list("sinks"), p.list("sources"))
    cfg = load_config()
    d = match_assignments(devs, {s: str(cfg.get(f"{s}_headset", "")) for s in SEATS})[seat]
    if not d:
        print("no headset assigned to", seat)
        return 1
    ring = Ring()
    cap = Capture(d["source"], ring, "lat")
    cap.start()
    time.sleep(0.6)
    while ring.read(BLOCK) is not None:
        pass
    click = np.zeros(int(RATE * 0.4))
    click[:48] = np.hanning(48) * 0.9
    t0 = time.monotonic()
    subprocess.run(["pacat", "--playback", "--raw", "--format=s16le", f"--rate={RATE}", "--channels=1", "--latency-msec=15",
                    f"--device={d['sink']}"], input=(click * 32767).astype("<i2").tobytes(), check=False)
    got = []
    while time.monotonic() - t0 < 1.0:
        x = ring.read(BLOCK)
        if x is None:
            time.sleep(0.002)
            continue
        got.append(x)
    cap.close()
    sig = np.concatenate(got) if got else np.zeros(1)
    noise = np.median(np.abs(sig)) * 8 + 0.01
    hit = np.argmax(np.abs(sig) > noise)
    if not np.abs(sig[hit]) > noise:
        print("no click heard: hold the microphone against the earcup and retry")
        return 1
    print(f"round trip ~{hit / RATE * 1000:.0f} ms (play + record through the sound server)")
    return 0


def serve_error(args, msg):
    """No numpy: keep answering the game (stdlib only) so the ICS page can show why, until the
    game exits."""
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.bind(("127.0.0.1", args.port))
        sock.settimeout(0.5)
    except OSError:
        return 0
    pkt = json.dumps({"type": "status", "ok": False, "msg": msg, "server": "", "seats": {}}).encode()
    while True:
        if args.parent_pid:
            try:
                os.kill(args.parent_pid, 0)
            except ProcessLookupError:
                return 0
            except PermissionError:
                pass
        try:
            data, _ = sock.recvfrom(65536)
            if b'"quit"' in data:
                return 0
        except (socket.timeout, OSError):
            pass
        try:
            sock.sendto(pkt, ("127.0.0.1", args.game_port))
        except OSError:
            pass


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", type=int, default=47810)
    ap.add_argument("--game-port", type=int, default=47811)
    ap.add_argument("--parent-pid", type=int, default=0)
    ap.add_argument("--settings", default=SETTINGS)
    ap.add_argument("--mock", action="store_true", help="synthetic headsets/voices, touches no audio device")
    ap.add_argument("--list", action="store_true", help="list USB headsets and the current seat assignment")
    ap.add_argument("--ident", metavar="SEAT|DEVICE", help="play the identify tones in one headset")
    ap.add_argument("--latency-test", metavar="SEAT")
    ap.add_argument("--setup-only", action="store_true", help="create the sinks, report, exit (checks the setup)")
    ap.add_argument("--log", help="append stderr to this file")
    args = ap.parse_args()
    if args.log:
        try:
            sys.stderr = open(args.log, "a", buffering=1, encoding="utf-8")
        except OSError:
            pass
    if np is None:
        msg = "python3-numpy missing (sudo apt install python3-numpy); intercom off"
        log(msg)
        if args.list or args.ident or args.latency_test or args.setup_only:
            return 1
        return serve_error(args, msg)
    if args.list:
        return cli_list()
    if args.ident:
        return cli_ident(args.ident)
    if args.latency_test:
        return cli_latency(args.latency_test)
    cfg = load_config(args.settings)
    if not bool(cfg.get("enabled", True)) and not args.mock:
        log("intercom disabled in the settings ([ics] enabled=false)")
        return 0
    h = Helper(args)
    signal.signal(signal.SIGTERM, lambda *_: setattr(h, "running", False))
    signal.signal(signal.SIGINT, lambda *_: setattr(h, "running", False))
    return h.main()


if __name__ == "__main__":
    sys.exit(main())
