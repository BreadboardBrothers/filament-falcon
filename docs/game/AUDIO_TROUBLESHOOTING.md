# Filament Falcon audio
## Audio troubleshooting (garbled / choppy sound)

1. Run the game without the intercom: `./run.sh --no-ics`. Clean sound here means the intercom helper is the problem.
2. Check the server rate (should be 48000): `pactl info | grep -i 'sample spec'`
3. Read the intercom log: `tail -n 40 ~/.local/share/filament-falcon/ics.log`. Look for underruns/xruns.
4. Look for leftover sinks from a crash: `pactl list short modules | grep -i falcon`. To clear them: `pactl list short modules | awk '/falcon/{print $1}' | xargs -r -n1 pactl unload-module`
5. Measure the delay through a headset: `python3 tools/falcon_ics.py --latency-test pilot`

The intercom runs at a fixed 48 kHz with 10 ms blocks and about 30 ms of buffer (around 50-70 ms end to end). Capture prefers float32 (falls back to s16le); playback is s16le at the sink's channel count. Drift between USB clocks is corrected with cubic resampling (inaudible). PulseAudio/PipeWire resample any headset that runs at 44.1 kHz. When the helper stops, the game moves its audio back to the default output.

**Audio quality (Commander → ICS → AUDIO QUALITY):** LOW / NORMAL / HIGH / HI-FI. This changes the radio band, compressor makeup, soft-clip drive and static level. Default is **HIGH** (wider band ~200–5200 Hz, light compression). HI-FI is nearly clean (80–12 kHz, almost no drive). The old "telephone" sound was NORMAL/LOW with a hard tanh drive of 1.6 and +9 dB makeup. Godot's mix rate is 48 kHz (UI beeps used to be synthesised at 24 kHz).

## Mic silent / stations swapping devices

- **Commander → ICS:** under each station there's a **MIC IN** and an **AUDIO OUT** picker (None / System default / a specific device). The **MIC IN level** bar sits directly above the mic picker; the **OUT level** bar sits directly below the out picker. A device already picked by another station is skipped, never taken from it. Picks are saved and apply immediately. (The old headset pairing selector was removed — mic/out are enough.)
- Devices are matched by USB bus path, so two identical headsets (the Logitech pair) stay on their seats. Keep each one in the same USB port.
- The log shows what each station opened and its levels every 10 s: `grep -E "INPUT|OUTPUT|levels|MUTED|capture" ~/.local/share/filament-falcon/ics.log | tail -n 30`
- A source that's muted or suspended in the system mixer is woken up and unmuted automatically (logged).
- Still silent? Paste `pactl list short sources` (while the game is running) and the grep above.

## A station hears nothing (AUDIO OUT)

- Each ICS station card has an **OUT meter** + state under the mic meter: `▶ OUT playing` (green) means the helper is writing to that device right now; the bar is the level it sends (game audio, intercom, beeps). `OUT ERROR` (red) = the stream to that device keeps failing (the log has the reason).
- **IDENTIFY** on a station card plays a chime + "Pilot station" (espeak-ng) through **that station's AUDIO OUT stream**, whatever the mic is. SETUP has the same IDENTIFY shortcut.
- AUDIO OUT picks are saved as the node name **plus the USB bus path** (`…analog-stereo@bus=pci-…-usb-0:3.3.4:1.0`). Identical headsets (the two Logitechs) get node names that only differ by a `.2` counter, and that counter follows plug/boot order, so a name-only pick could point at the other headset after a reboot. A short port number (`@port=3`) is still understood, but it is not used when two controllers share that number. Picking the analog jack never opens the digital/iec958 jack on the same dongle (and the other way around). A 5.1 or 7.1 output is opened with that many channels; a forced stereo stream is what PipeWire rejects.
- When a card exposes several outputs (analog + digital/iec958), pick the profile you want in AUDIO OUT. The stream is opened with the sink's own channel count (mono, stereo, 5.1, 7.1), with the voice copied to every channel.
- A muted or suspended sink is woken up and unmuted (logged); a sink at < 5 % volume is logged as a warning.
- Log: `grep -E "route|OUTPUT|outputs|IDENTIFY|sink was" ~/.local/share/filament-falcon/ics.log | tail -n 40`. Every 10 s `outputs:` shows per station the peak dB sent, the stream state and the sink name.
