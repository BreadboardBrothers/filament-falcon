# New install: `./setup.sh`

One script sets up a fresh cockpit PC (Linux Mint 21/22, AMD RX 6800 XT, Godot 4.7.2 Forward+/Vulkan).
It installs everything the game, the VR spacewalk and the cockpit panels need, then runs a "doctor"
check and tells you what is left to do.

```bash
git clone https://github.com/breadboardbrothers/filament-falcon.git
cd filament-falcon
./setup.sh --dry-run     # optional: print every command, change nothing
./setup.sh               # shows the plan, asks once, then installs (asks for your sudo password)
./setup.sh --check       # any time later: what's OK / missing
```

It is safe to re-run. Anything already installed is skipped. Nothing is deleted. If there is already a
different `godot` link or udev rule, the script reports it and leaves it alone.

## Flags

| Flag | What it does |
|---|---|
| `--yes`, `-y` | No questions (`apt-get -y`, `flatpak -y`) |
| `--dry-run`, `-n` | Print what it would run; install, change and download nothing |
| `--check` | Only the doctor report. Exit code 0 means nothing is missing (warnings don't count) |
| `--no-assets` | Skip the NASA Earth/Moon textures and the OSM region download |
| `--no-hd` | Assets without the HD Earth (~80 MB less) |
| `--region=NAME` | OSM detail region (default `fredericton`; `python3 game/tools/build_region.py --list`) |
| `--no-vr` | Skip WiVRn, adb, avahi and the Quest udev rules |
| `--no-hardware` | Skip the ESP32 panel udev rule and the `dialout` group |
| `--no-apt` / `--no-pip` | Skip the apt packages / pyosmium |
| `--no-godot` | Don't download Godot (bring your own: `GODOT=/path` or `godot` on PATH) |
| `--godot-dir=DIR` | Where Godot goes (default `~/Apps/godot`) |

## What it installs, and where

| What | Where | Why |
|---|---|---|
| apt: python3-numpy/-pil/-serial, osmium-tool, espeak-ng, alsa-utils, pulseaudio-utils, xinput, x11-xserver-utils, mesa-vulkan-drivers, vulkan-tools, the X11/Vulkan/audio libraries Godot loads, curl, unzip, git, desktop-file-utils | system | Region builder, LED bridge, voice callouts, intercom (`pactl/parec/pacat`), touch mapping, GPU check |
| apt (VR): flatpak, adb, android-sdk-platform-tools-common, avahi-daemon | system | WiVRn, the Quest over USB, discovery |
| apt (panels): evtest, joystick | system | Testing the ESP32 joysticks |
| pipewire-pulse | system | Only if PipeWire is present without PulseAudio |
| pyosmium (private venv in `~/.local/share/filament-falcon/pyenv`; no system pip changes) | home | Faster OSM region builds |
| Godot 4.7.2 stable (official GitHub release, **SHA-512 checked**; not installed if the check fails) | `~/Apps/godot/`, linked as `~/.local/bin/godot` | The game (`run.sh` uses `godot` on PATH, or `GODOT=`) |
| WiVRn (`flatpak --user`, from Flathub) | home | Quest 3 streaming / OpenXR runtime |
| The VR launcher entry (`install_vr_launcher.sh`) | `~/.local/share/applications` | Start the spacewalk from inside the headset |
| Game assets (`game/tools/fetch_assets.sh`, ~150 MB + SOLAR maps) | `~/.local/share/filament-falcon/assets` | NASA Earth/Moon textures, OSM Fredericton, SOLAR planet maps |

It also runs a one-time headless Godot import of the project (the same step `run.sh` does on first launch).

**sudo is only used for:**

- `apt-get` (system packages);
- copying `firmware/udev/99-filament-falcon.rules` to `/etc/udev/rules.d/`;
- `usermod -aG dialout` / `-aG plugdev` (serial port and adb without root);
- `systemctl enable --now avahi-daemon`;
- a `/usr/local/bin/godot` link, only if `~/.local/bin` is not on your PATH.

Each sudo command prints why it needs root before it runs. The script refuses to run as root itself.

## What you still do by hand

1. **Log out and back in** (or reboot) after the first run. New group memberships (dialout, plugdev) and
   `~/.local/bin` on PATH only apply to new sessions. Then run `./setup.sh --check`.
2. **Firewall** (only if `sudo ufw status` says active). The script prints these commands but does not run them:
   `sudo ufw allow 5353/udp && sudo ufw allow 9757`.
3. **Quest 3 developer mode.** In the Meta Horizon phone app: Devices → your Quest → Headset settings →
   Developer mode ON. Reboot the headset, plug it in with a USB-C data cable, accept **Allow USB debugging**
   (tick "Always allow"). `adb devices` must show `device`, not `unauthorized`.
4. **WiVRn on the headset and pairing.** Install the WiVRn app from the Meta Store, or use the sideload wizard in
   the dashboard. Start the dashboard (`flatpak run io.github.wivrn.wivrn`) → Start → **Connect by USB**.
   In the headset app, enable the microphone (intercom) and hand tracking.
   Details: [VR_SETUP.md](VR_SETUP.md#setup-on-linux-mint-22-step-by-step), steps 2–6.
5. Optional: a [piper](https://github.com/rhasspy/piper) voice (set `audio/piper_model` in the settings).
   Optional: PlatformIO, only if you build the panel firmware yourself (see `firmware/`).
6. Play: `cd game && ./run.sh --cockpit` (or `./run.sh --dev` on one screen).
   Display/touch mapping: [README.md](README.md).

## The doctor (`./setup.sh --check`)

The doctor checks these and reports each one as OK, WARN or MISSING, followed by numbered next steps:

- Godot 4.7.2 and whether `godot` is on PATH;
- the Vulkan GPU (expects AMD/RADV) and the PulseAudio/PipeWire server;
- espeak-ng;
- the Python modules numpy, PIL, serial and osmium;
- xinput and xrandr (with a warning on a Wayland session);
- WiVRn, `adb devices` and plugdev;
- the udev rule, and whether you need to log out and in;
- the assets and OSM region;
- free disk space (warns under 5 GB).

## Automatic launcher dependency check

Run `cd game && ./run.sh` as your **normal user**. Each start checks Godot **4.7.2**,
Python 3, native engine/X11 libraries and the dependencies for enabled helpers.
Missing system packages are installed with apt on Mint/Ubuntu/Debian only (sudo's
normal terminal password prompt; no upgrade or graphics-driver changes). Existing
packages are not reinstalled. Installation failures stop the launch and are rechecked.
The official pinned Godot ZIP is installed under `~/Apps/godot` using the existing
setup installer: SHA-512 verification is mandatory, extraction is staged before rename.
An existing compatible `GODOT=/path/to/engine` is respected, including spaces.

- Intercom (unless `--no-ics` or saved disabled): numpy + `pactl`, `parec`, `pacat`.
  Requires a working PulseAudio/PipeWire-Pulse service and configured audio devices;
  the launcher does not replace your audio server.
- Voice (unless `--no-voice` / saved disabled): espeak/espeak-ng. Piper and its model
  are optional, manually configured alternatives, not automatically downloaded.
- LED bridge (unless `--no-led` / saved disabled): pyserial. Hardware permissions /
  udev rules remain the explicit `setup.sh` hardware step.
- X11 display/touch helpers: xrandr + xinput when an X11 display is present and mapping
  or touch isolation is enabled. Wayland mapping is not supported by these helpers.
- `--geo-tools`: numpy, Pillow, pyosmium via distro packages. osmium-tool is an optional
  accelerator; cached map/terrain data and all large imagery are optional.
- `--fetch-assets`: **explicitly** request the existing Earth/Moon/OSM asset fetcher
  (also checks geo dependencies). Asset downloads are no longer automatic on launch;
  existing assets continue working. `--no-fetch` still disables all launcher fetches.
- Real VR needs a separately configured WiVRn/OpenXR runtime (`VR_SETUP.md`); requesting
  `--eva-vr` without it fails clearly. No VR software is installed by the launcher.

`./run.sh --check-deps` checks only, exits nonzero when anything is missing, and does
not launch, download or install. `--no-install` (or `FALCON_NO_INSTALL=1`) launches
only if dependencies already exist. Tests/headless invocations disable installation
and helper dependencies. Noninteractive runs never prompt sudo: missing system
packages give an actionable error instead. No `pip --break-system-packages` is used;
the standalone setup's optional pip flow uses a private venv.

Offline healthy installations start normally; missing downloads/packages require a
network connection. Unsupported distros must install the reported tools themselves.
Check mock coverage without touching apt: `bash game/tools/test_runtime_deps.sh`.
