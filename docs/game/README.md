# The Filament Falcon: game (v0.1)

A two-seat (Pilot + Ops) spaceship cockpit game for Godot 4. Everything (planet, Moon, stars, ship,
station, sounds) is generated procedurally at start-up, so the repo stays small and has no
downloaded assets (see [CREDITS.md](CREDITS.md)).

![docking at the station](screenshots/07_docking_ops.jpg)

More in [screenshots/](screenshots/): launch pad, ascent, station, docking, Moon, asteroid field, reentry plasma, runway,
the celebration screen, the kids' console pages (`18_`–`22_`), the Commander screen (`23_`–`27_`), the
three-screen fallback with the Commander as a console tab (`28_`), the on-screen virtual panels for unplugged
boards (`29_` console PANELS page, `30_` CHECKLIST with the overhead panels, `31_` Commander PANEL) and the
intercom pages (`32_` Commander ICS, `33_` SETUP with headsets) and the VR spacewalk (`34_`/`35_` the astronaut
waving and knocking at the LEFT window, `36_` console EVA page with suit telemetry and the helmet cam, `37_`
Commander EVA page, `38_` the astronaut's view of the ship over Earth, `39_` the EVA drone camera). They are rendered by `tests/run_screenshots.sh`
with the software Vulkan driver at the Ultra preset (`QUALITY=ultra`), so they look softer than on the real GPU.

### Graphics notes

- **Window views stay clean.** Only a small, semi-transparent HUD is drawn on the windows: speed/altitude/vertical
  speed bottom-left, throttle and fuel bars, flight-path markers, a faint horizon line with a gap in the middle,
  and short cues (countdown, sink rate, AoA, g, hull). The full instruments (attitude ball, speed and altitude
  tapes, orbit, Ap/Pe, assist, gear, flaps, engine) are on the kids' console, and a telemetry summary is on the
  Commander screen.
- **Exposure** is scripted, not automatic, so bots and screenshots are repeatable: the bright daytime sky
  stops down (about 0.78), space sits at about 0.92, and night inside the atmosphere opens up. ACES tonemapping.
- **Everything is procedural**, including the "textures": planet (continents, oceans with sun glint and
  Fresnel, cloud deck with cloud shadows and clear weather over the pad and runway, atmosphere scattering
  and limb), terrain (farm plots, roads, forest, rock; craters on the Moon), and the PBR panel shader used on
  the ship and station (panel lines, rivets, roughness variation, grime, MLI foil). Normal maps are
  "derivative bumps" computed in the shader from the same height functions.
- **Station** flies a fixed attitude to the local vertical with its docking port facing straight up, so the
  Falcon docks from above with Earth in the background. Its solar arrays turn to follow the sun.
- **Launch pad**: lattice service tower with crew and umbilical arms, flame trench, lightning masts, water
  tower, propellant spheres, floodlights, and a smoke/steam cloud while the engines fire near the pad.
  Engine plumes add a screen-space heat shimmer.

## 1. Install Godot (Linux Mint)

> **Shortcut:** `./setup.sh` in the repo root does all of this (plus VR, panels and assets) and checks the result.
> See [SETUP.md](SETUP.md). The manual steps are below.

1. Download **Godot 4.7.x stable, standard (not .NET), Linux x86_64** from <https://godotengine.org/download/linux/>.
2. Unzip it somewhere *outside* the repo, e.g. `~/Apps/godot/`, and make it executable:
   ```bash
   chmod +x ~/Apps/godot/Godot_v4.7.2-stable_linux.x86_64
   sudo ln -s ~/Apps/godot/Godot_v4.7.2-stable_linux.x86_64 /usr/local/bin/godot
   ```
3. GPU driver: the RX 6800 XT uses Mesa RADV out of the box on Mint. Check with
   `vulkaninfo --summary` (package `vulkan-tools`) that the AMD GPU appears.
4. Optional extras:
   - `sudo apt install espeak-ng` gives spoken callouts. Without it you get text banners plus tones.
     A [piper](https://github.com/rhasspy/piper) voice also works: set `audio/piper_model` in the settings file.
   - `sudo apt install python3-serial` is needed for the LED panel bridge.
   - `sudo apt install python3-numpy pulseaudio-utils` is needed for the 3-headset intercom (see
     [section 6](#6-intercom-ics-three-usb-headsets)). Linux Mint 22 runs PipeWire, which already includes the
     PulseAudio server (`pipewire-pulse`); `pulseaudio-utils` only adds the `pactl`/`parec`/`pacat` tools.

## 2. Run it

**Easiest:** `./run.sh --cockpit` (or `./run.sh --dev`) from the `game/` folder. On a fresh clone it imports the project first, which fixes the "Identifier CelestialBody not declared" parse errors you otherwise get on the very first launch. If you use `godot` directly, run `godot --headless --path . --import` once first.

`run.sh` also maps the touchscreen to the kids' console monitor before each launch (see
[Touch mapping](#touch-mapping-the-td2220)) and starts the intercom helper (see [Intercom](#6-intercom-ics-three-usb-headsets)).
Extra `run.sh` options: `--landscape-console` (turn the console monitor to landscape first),
`--no-display-setup` (skip the touch mapping), `--no-touch-isolate` (let touches move the mouse pointer again, see
[Touch vs. mouse](#touch-vs-mouse-focus)), `--no-ics` (no intercom) and `--eva-vr` (start the VR spacewalk
client for the Quest 3 instead of the cockpit, in a second terminal; add `--eva-flat` to try it without a
headset; see [section 7](#7-vr-spacewalks-meta-quest-3)).

```bash
cd game
godot --path .                 # auto: cockpit mode if >= 3 screens, else dev mode
godot --path . -- --dev        # all four views tiled in one window (laptop / development)
godot --path . -- --cockpit    # force one fullscreen window per screen
godot --path . -- --quality=ultra --mission=docking
```

The first start imports the project, which takes a few seconds. Opening `game/project.godot` in the
editor and pressing F5 also works.

Keys:
- **Shift+Esc** quits.
- **Shift+End** toggles the dev/cockpit layout.
- **Esc** shows/hides the Commander tab on the console (only on a three-screen rig, see below).

Every cockpit control also has a keyboard key (see below and the CONTROLS page).

Useful command-line options (after `--`):

| Option | Effect |
|---|---|
| `--dev` / `--cockpit` | Force the window layout. |
| `--quality=low\|medium\|high\|ultra` | Graphics preset. Also on the Commander SETUP page. |
| `--mission=<id>` | Start mission: launch, docking, lunar, asteroids, reentry or sandbox. |
| `--no-voice` / `--no-led` / `--no-ics` | Turn off speech / the LED bridge / the intercom. |
| `--virtual-panels` | Always show the on-screen panels, even with the boards plugged in. |
| `--ics-mock` | Intercom helper with fake headsets and voices (no audio devices touched). |
| `--shared-dir=/path/to/shared` | Use a different `shared/` folder (input_map.json, led_protocol.md). |
| `--eva-client` (with `--xr-mode on` before `--`) | Run as the VR spacewalk client (what `run.sh --eva-vr` does). `--eva-port=` changes UDP 47820. |
| `--eva-near=0.2` | Near clip plane of the window views during a spacewalk (lets a glove on the glass render). |

Settings are stored in `~/.local/share/filament-falcon/falcon_settings.cfg`. The Commander SETUP page shows the
exact path. Delete the file to get the defaults back.

## 3. The four screens

| Role | What it shows | Hardware on Yves's rig | xrandr output |
|---|---|---|---|
| **LEFT WINDOW** | out-the-window view + minimal HUD | Sceptre C275B-144R, 27" curved, 1920x1080 @ up to 144 Hz | DisplayPort-2 |
| **RIGHT WINDOW** | out-the-window view + minimal HUD | Sceptre C275W-1920RN, 27" curved, 1920x1080 @ 75 Hz | DisplayPort-1 |
| **KIDS' CONSOLE** | the crew's instruments and controls (touch) | ViewSonic TD2220, 22" optical touch, 1920x1080 @ 60 Hz | DisplayPort-0 |
| **COMMANDER** | mission control for the grown-up (mouse + keyboard) | 31.5" 1920x1080 monitor | HDMI-A-0 |

All views render at native 1920x1080 (the console also works in portrait, 1080x1920).

### What is on which screen

**Kids' console** (touch, big buttons; only things the crew acts on or watches):
- **FLIGHT** (the main page). Pilot half: attitude ball (ADI) with pitch ladder, roll scale and heading, speed
  and altitude tapes, climb rate, g, throttle and fuel bars, ENGINE ARM, IGNITION, GEAR, AIRBRAKE, FLAPS
  UP/HALF/DOWN, ASSIST OFF/STAB/PROGRADE/HOLD. Ops half: mode RCS/ARM/SCANNER, a live camera that follows the
  mode (docking camera in RCS, arm camera in ARM), target readout with NAV TARGET, SCANNER PING, TRIGGER,
  CARGO DOORS, DOCK CLAMP and the five power switches.
- **NAV**: orbit map with a lit Earth/Moon globe (day, night lights, clouds, atmosphere) and a GROUND close-up when low (roads, water and towns from OSM; see [REAL_EARTH.md](REAL_EARTH.md#nav-map-globe-and-ground-close-up)), "highest/lowest point", STEER TO buttons for the Pilot, NAV TARGET for Ops.
- **SYSTEMS**: power distribution (all switches, power use, reactor), ship health bars, the fault list with
  what to do, SEAL LEAK, FIRE SUPPRESS, JUMP ARM/ENGAGE.
- **CAMERAS**: docking, arm and chase cameras.
- **CHECKLIST**: the overhead start-up switches in order, with DONE / NEXT / OUT OF ORDER. While Falcon
  Command is unplugged the three overhead panels are drawn above the list.
- **PANELS** (the tab only appears while the Pilot or Ops board is unplugged, or SETUP forces it): that
  seat's real panels on screen (see [Virtual panels](#virtual-panels-boards-unplugged)) and a touch joystick.
- A task strip at the top always shows each kid's current job (blue = Pilot, orange = Ops) and flashes
  MASTER CAUTION. Each kid has a big **TALK** pad there (intercom push-to-talk; it lights when that mic is on
  air). Every touch control mirrors a hardware control. When a board is plugged in, its switches
  win and the touch buttons only show their state.

**Commander screen** (mouse and keyboard; nothing here needs touch):
- **Status row** (always visible): PILOT / OPS / CMD board plugged in (✔) or VIRTUAL, crew position
  (POD UP / MOVING / DOWN-LOCKED, SEATS UPRIGHT / MOVING / RECLINED) and the intercom state.
- **MISSION CONTROL**: mission select, START / PAUSE / RESUME / FLY AGAIN, RESTART, SKIP STEP, harness check,
  END FREE FLIGHT, failure injection, live score; orbit map with zoom, telemetry, time WARP and VIEW (cockpit or
  chase); crew status with both kids' current tasks and step, ship health, faults, MASTER CAUTION RESET; crew
  position; intercom TALK and ALL-CALL (hold), MUTE PILOT / MUTE OPS.
- **BRIEFING**: the full briefing, both jobs, all objectives, the Commander tip, READ BRIEFING ALOUD.
- **TRAINING**: difficulty (EASY: +30 % fuel and RCS, half damage; HARD: −15 % fuel, 1.5× damage), skip the
  overhead checklist for little crews, checklist ALL ON / ALL OFF, assist override, voice callouts, failures.
- **CONTROLS**: live test of every switch, axis and button, devices, LED test, input-map template export.
- **PANEL**: the two Falcon Command panels (CMD_A, CMD_B) on screen: operable with the mouse while the board is
  unplugged, a live mirror when it is plugged in. Also a big ALL-CALL / PA pad and SENSE TEST switches (pretend
  the crew-position contacts close, to try the pod display and callouts without the hardware). **SHIP SERVICE +
  DEBUG**: REFUEL FULL / +25 % (main propellant, an attached booster, RCS, cabin O2 + suit O2, reactor power;
  logged as a Commander action) and the **debug slew** (below).
- **Debug slew / free camera** (mission PAUSED; PANEL page buttons or **Ctrl+F**): **SHIP** moves and turns the
  Falcon itself and RESUME continues from there, velocity **ZEROED** (matched to the nearest body: parks / hovers)
  or **KEPT** (V or the button). **FREE CAM** flies the camera only (the ship stays; the camera snaps back on resume).
  Speeds 0.1 / 1 / 10 / 100 / 1000 / 10000 / 100000 / 1000000 m/s (up to 1,000 km/s: cross the real-size Earth or fly to the Moon) and 1 / 5 / 20 / 90 °/s, shown on the PANEL page. Keys while it is
  on (the slew owns the keyboard): W/S fwd/back, A/D left/right, Q/E down/up, ↑↓ pitch, ←→ yaw, Z/X roll, +/− (or
  keypad) speed, [ ] turn speed, Tab ship/cam, V velocity, Esc off, Pause/F9 resume. The kids' sticks work too
  (Pilot stick turns, Ops stick moves), and so do the hold pads on the PANEL page. Works anywhere: orbit, station,
  Moon, any detail region (no collision: slew down to the ground yourself).
- **AREAS**: the real-size Earth's area manager. Pick a preset, LAT / LON + radius, or drag a box on the map, see
  the download sizes, then QUEUE DOWNLOAD + GENERATE (DEM, Sentinel-2 imagery, the Geofabrik extract, the 3D OSM
  build). Jobs run in the background on this PC; the list shows progress and disk use, with CANCEL / REBUILD /
  DELETE. The runner line shows whether the background job runner is running, what it is downloading (MB) and why
  a job waits; it starts by itself when jobs are queued, and **RUN / RETRY NOW** retries by hand (log tail at the bottom).
  Same thing from a terminal: `python3 tools/area_manager.py status` / `run --wait`. See [REAL_EARTH.md](REAL_EARTH.md).
  With an OSM map layer built (BUILD MAP LAYER on the map, or `tools/map_layer.py`) the map shows roads, rivers,
  lakes and city / town / village names by zoom ([REAL_EARTH.md](REAL_EARTH.md#areas-map-layer-toolsmap_layerpy-runs-on-the-game-pc)).
- **SOLAR**: true-scale solar-system visualizer (Keplerian ephemeris, moons, orbit lines, time scrub / rates, warp + attach with mouse orbit/zoom while attached, ship trajectory). Textures via `tools/fetch_solar_assets.sh`. See `SOLAR.md`.

- **ICS**: the intercom: per seat **MIC IN** / **AUDIO OUT** pickers (None / System default / free devices; one device per station), live **MIC IN level** bar above the mic picker and **OUT level** bar below the out picker, IDENTIFY through that station's AUDIO OUT, RESCAN, VOX/PTT, VOX level / attack /
  hang, mic gain, intercom and game volume, sidetone per seat; radio effect, static, squelch tail, click + roger,
  room speakers, callout volume, ALL-CALL duck, and **AUDIO QUALITY** (LOW / NORMAL / HIGH / HI-FI) for the
  radio band and compression (see [AUDIO_TROUBLESHOOTING.md](AUDIO_TROUBLESHOOTING.md)). (Legacy headset pairing was removed — mic/out already configure audio.)
- **SETUP**: screen roles, layout mode, quality, FPS cap, vsync, fullscreen, LED link, window geometry, QUIT;
  intercom IDENTIFY shortcuts (full MIC IN / AUDIO OUT on ICS); ALWAYS SHOW virtual panels; crew-position options (callouts, travel time, UP sense fitted).

### Which screen gets which role

At start-up the game reads `xrandr --listmonitors` (output names and physical sizes) and assigns roles in
this order:

1. `display/<role>_output` in the settings file, an output name such as `DisplayPort-0`, if that output exists.
2. `display/<role>_screen`, a Godot screen number, if it is 0 or more.
3. Automatic:
   - the console is the screen closest to 22", else a portrait screen, else the lowest one;
   - the Commander is the biggest remaining screen, but only if there is still one left for each window;
   - the windows are the remaining screens, left to right.

The defaults are `console_output="DisplayPort-0"`, with everything else automatic. On Yves's rig that gives
LEFT = DisplayPort-2, RIGHT = DisplayPort-1, CONSOLE = DisplayPort-0 and COMMANDER = HDMI-A-0.
The start-up log prints the result (`display: cockpit layout on 4 screens …`).

To change it, open **Commander → SETUP → SCREENS**:
- **◀ ▶** cycles each role through AUTO, screen 0, 1, 2, … (stored by output name).
- **IDENTIFY / IDENTIFY ALL** flashes the role name on its monitor.
- **APPLY WINDOW LAYOUT** moves the windows.

You can also edit the settings file while the game is closed:

```ini
[display]
mode="auto"                 ; auto | cockpit | dev
left_output="DisplayPort-2"
right_output="DisplayPort-1"
console_output="DisplayPort-0"
commander_output="HDMI-A-0"
```

**Three screens only** (no Commander monitor): the game still runs in cockpit mode. The Commander UI becomes
a **⚙ COMMANDER** tab on the kids' console, and **Esc** jumps to it and back. **Dev mode** (`--dev`, or fewer
than 3 screens) tiles all four views in one window: the windows on top, the console and Commander underneath.

**Console rotation:** the game detects a portrait console (1080x1920) and lays the console out top-to-bottom
(Pilot above Ops). **Landscape is recommended**: it is what the UI is designed for, and the TD2220's touch
mapping is simplest when it is not rotated. To turn it to landscape, use `./run.sh --landscape-console`,
`tools/setup_displays.sh --landscape`, or Cinnamon's *Display* settings (rotation "Normal").

### Forward window geometry

The two forward windows share one eye point and use **off-axis (asymmetric) frusta** built from the real
monitor geometry, so together they act as one continuous windscreen and the bezel gap behaves like a
window post. Measure your rig and enter the numbers on **Commander → SETUP** (or in the settings file):

| Setting | Default | Meaning |
|---|---|---|
| `monitor_width_m` / `monitor_height_m` | 0.597 / 0.336 | Visible panel size of a 27" 16:9 monitor. |
| `monitor_gap_m` | 0.06 | Gap between the two panels' picture edges. |
| `eye_distance_m` | 0.62 | Eyes to monitor plane. |
| `eye_height_m` | 0.0 | Eyes above (+) or below (−) the monitor centre. |
| `toe_in_deg` | 0 | Angle each monitor is turned toward the centre. |
| `view_scale` | 1.15 | >1 widens the field of view a bit (more dramatic, less "true"). |
| `chase_bezel_bias` | 0.55 | Chase view only: slide the rocket off the bezel seam (0 = dead centre / hidden in the gap; 0.55 ≈ mid-right 27" panel; negative = left panel). Cockpit frusta unchanged. |
| `chase_bezel_clear_m` | 0.08 | Extra metres past `gap/2` before bias starts counting into the panel. |
| `chase_distance_m` | 0 | Chase camera distance; 0 = auto (34 m ship / 75 m with booster). |

The panels are slightly curved, but the frustum assumes flat panels. At 27" the error is small. If straight
lines bend at the inner edges, add a few degrees of toe-in.

**Chase view on twin windows:** cockpit mode keeps the bezel as a window post (optical centre in the gap).
Chase mode reuses those off-axis frusta, so a centred rocket would sit in the seam. The game yaws the
shared chase eye by `chase_bezel_bias` / `chase_bezel_clear_m` so ship + booster clear the bezel on the
paired monitors. Single-monitor / solo screenshot chase stays centred. Console **CHASE CAMERA** feed
uses the same `chase_xform` (no bezel yaw). Tune on **Commander → SETUP**.

### Screen placement (X11 / Cinnamon)

```bash
xrandr --listmonitors              # output names, sizes in mm and positions
# Example: Commander monitor left, the two windows side by side, console (landscape) under the windows
xrandr --output HDMI-A-0 --mode 1920x1080 --pos 0x0 \
       --output DisplayPort-2 --mode 1920x1080 --rate 75 --pos 1920x0 \
       --output DisplayPort-1 --mode 1920x1080 --rate 75 --pos 3840x0 \
       --output DisplayPort-0 --mode 1920x1080 --rotate normal --primary --pos 2880x1080
```

The positions only matter to the desktop: the game puts each role on its output by name. Save the arrangement
in Cinnamon's *Display* settings so it survives a reboot.

### Refresh rates (144 Hz + 75 Hz + 60 Hz + 60 Hz)

One render loop feeds all four windows. If every window waited for its own vsync (FIFO), the loop
would block on whichever screen is slowest and frame pacing would jitter. The defaults are:

- **Frame cap 75 FPS** (`display/max_fps`). The RX 6800 XT holds this easily at ultra on two 3D views plus
  two UI screens. The console and Commander render only 2D, apart from small camera feeds.
- **MAILBOX vsync on every window** (`display/vsync = mailbox`). There is no tearing, and presenting never blocks on another screen.
- **Recommendation:** run the 144 Hz Sceptre at **75 Hz** (the `xrandr --rate 75` above), so both forward
  windows refresh at the same rate as the frame cap. This gives perfectly even motion across the windscreen
  seam. If you prefer 144 Hz on that panel, set the cap to 144 on SETUP. The 75 Hz panel will then drop
  frames evenly, and the 6800 XT has the headroom.
- The touchscreen and the Commander monitor run at 60 Hz. They only show UI, so the cap does not matter there.

Both settings can be changed live on **Commander → SETUP** (60/75/120/144 FPS; VSYNC MAILBOX/FIFO/OFF).

### Touch mapping (the TD2220)

The console UI is laid out for 22" 1080p (about 100 px per inch). Buttons are 76–100 px (19–25 mm) tall,
and text is 22–34 px, readable from the seats. The optical touch panel is a USB HID touch device. By default X
spreads its touches over the whole desktop, which is why taps landed on the wrong monitor. X must map it to the
console output only.

`game/tools/setup_displays.sh` does this, and **`run.sh` calls it before every launch**. It:
- finds the touch device in `xinput list`: names containing *NextWindow*, *ViewSonic* or *touch*, but not touchpads;
- takes the console output from the game's settings (`console_output`), else from the last run's
  `~/.local/share/filament-falcon/displays.env`, else `DisplayPort-0`;
- runs `xinput map-to-output <device> <output>`;
- does nothing, quietly, if there is no X display, no `xinput` (`sudo apt install xinput`), no touch device, or
  the output is not connected.

```bash
game/tools/setup_displays.sh --list            # show outputs + touch devices, change nothing
game/tools/setup_displays.sh                   # map touch -> console output
game/tools/setup_displays.sh --landscape       # also rotate the console output to landscape first
game/tools/setup_displays.sh --output DisplayPort-0 --device "NextWindow"   # override detection
```

**Make it permanent** (the mapping is lost at logout, reboot or when the USB cable is replugged):

- *Cinnamon:* **Menu → Startup Applications → + → Custom command**.
  - Name: `Falcon touch mapping`
  - Command: `/home/yves/filament-falcon/game/tools/setup_displays.sh` (add `--landscape` if wanted)
  - Startup delay: `5` seconds
- *Or* create `~/.config/autostart/falcon-touch.desktop`:

  ```ini
  [Desktop Entry]
  Type=Application
  Name=Falcon touch mapping
  Exec=/home/yves/filament-falcon/game/tools/setup_displays.sh --quiet
  X-GNOME-Autostart-Delay=5
  ```

  Adjust the path to wherever the repo is cloned.

If the touch cable gets replugged during a session, run the script again (or just restart via `run.sh`). Use
the default X11 Cinnamon session; on Wayland the compositor's own touch-mapping setting is needed instead.

### Touch vs. mouse focus

Out of the box, X treats the touchscreen as a second mouse: a tap moves *the* cursor to the kids' panel
and the window manager gives that window keyboard focus, so Dad's cursor jumps away and Commander shortcuts
(and Alt+F4) stop working until he clicks back. While the game runs, **`run.sh` keeps the touchscreen apart
from the mouse** (`game/tools/touch_isolate.sh`):

- *Multi-touch device* (the TD2220 normally is one; `xinput list --long <id>` shows "Touch mode: direct"):
  it is **floated** (`xinput float`). X no longer moves the cursor or sends clicks for it. Godot still reads
  its XI2 touch events and turns them into taps and drags on the console window (multi-touch TALK pads too).
- *Plain absolute pointer* (no touch class): it gets its **own master pointer** "Falcon Touch"
  (`xinput create-master`). Dad's cursor stays put, and a second cursor follows the finger on the panel.
- When the Commander has its own screen, the game also marks the console window as never taking keyboard
  focus (Godot's click-to-focus off, plus ICCCM `WM_HINTS` input=False via `tools/x11_no_input_hint.py`
  so Cinnamon doesn't focus it either). The keyboard stays on the Commander window. When the Commander is
  embedded in the console (no Commander monitor), the console keeps normal focus.
- On exit (normal quit, Alt+F4, crash or kill) a small watcher puts the device back on the
  Virtual core pointer and removes the extra master. The next start also cleans up anything left over
  (state: `~/.local/share/filament-falcon/touch_isolate.state`, log: `touch_isolate.log` next to it).
- It does nothing on Wayland, without `xinput`, or with no touchscreen. The touchscreen keeps working on the
  desktop when the game isn't running.
- **The mouse cursor never stays hidden.** The game never hides or captures the mouse (`mouse_mode` is
  re-asserted VISIBLE after touches and every second). The cursor that vanished after a tap was Cinnamon's
  doing: its window manager (muffin, like GNOME's mutter) hides the cursor screen-wide when the last-used
  device is a touchscreen and shows it again only when the *core* pointer switches back to a mouse. With
  the touchscreen on its own "Falcon Touch" master (which the first version picked by mistake for real
  touchscreens: it looked for "direct touch" while xinput prints "Touch mode: direct"), that switch never
  happens, so the cursor stayed gone. Now real touchscreens are floated (no hide at all), and as a safety
  net the game runs `tools/x11_show_cursor.py` after touches (≤ 1/s): it nudges the core pointer 1 px and
  back via XTEST, which the window manager counts as mouse use and shows the cursor. Also: don't run
  `unclutter` (touch_isolate.log warns if it is).

```bash
FALCON_TOUCH_ISOLATE=0 ./run.sh --cockpit       # off (or: ./run.sh --no-touch-isolate)
FALCON_TOUCH_ISOLATE=master ./run.sh --cockpit  # force the second-master method (default: auto)
FALCON_CURSOR_NUDGE=0 ./run.sh --cockpit        # no cursor nudge after touches
game/tools/touch_isolate.sh status              # what is isolated right now
game/tools/touch_isolate.sh stop                # put the touchscreen back by hand
```

If touch stops working in the game with the default (`float`), try `FALCON_TOUCH_ISOLATE=master` and say
which one works.

### Later: projector dome (3× HY300)

The out-the-window rendering is generic, so this is planned for but not built yet:
- `display/views` lists the outputs (default `left,right`). Each output gets its own SubViewport, camera, HUD and OS window.
- `DisplayManager.screen_rect_for(name)` describes each output as a physical rectangle in eye space, and
  `off_axis()` turns any rectangle into an asymmetric frustum. Three projectors would just add three
  rectangles (one per projector's slice of the dome).
- `display/<name>_warp` can point at a `canvas_item` shader that is applied to that output's final image.
  A dome would use it to pre-distort each projector image (mesh/UV warp and edge blending). It is empty by default.

## 4. Controls, joysticks and the shared contract

- Mapping comes from `../shared/input_map.json`, the contract with the firmware.
  If that file is missing or broken, built-in defaults are used. The CONTROLS page shows which source is active.
- Boards are matched by name substring ("Falcon Pilot", "Falcon Ops", "Falcon Command"). On Linux the
  name is like "Filament Falcon Falcon Pilot". They can also be matched by USB VID `0x1209` and PID
  `0x0003` (Pilot), `0x0004` (Ops) or `0x0005` (Command).
- Rotary encoders (assist mode, ops mode, mission select) send next/prev/push presses. The game keeps
  track of the selected position. The dimmer is an axis, FLAPS is a 3-position toggle, and NAV TGT is a single push.
- When a board is connected, its switches win. The touchscreen switch buttons are disabled for those
  controls, so the physical switch is always the truth.
- **CONTROLS page** (Commander screen): live state of every action, the device list, an "export template" button and an LED test.
- Push-to-talk buttons: Pilot board bit 11 (HID button 14, `ptt_pilot`), Ops board bit 13 (HID 16, `ptt_ops`), the
  Commander's INTERCOM button (HID 7, `ptt_commander`) and a new ALL-CALL button on Falcon Command bit 7 (HID 13,
  `all_call`). The kids' PTT and the ALL-CALL buttons are 16 mm momentaries that are not on the v0.1 panel
  drawings yet (spare 74HC165 inputs; mount them where the kids can reach, e.g. beside the stick).
  Re-flash all three boards after pulling (`pio run -e falcon_pilot -t upload`, same for `falcon_ops`,
  `falcon_command`); old firmware still works, it just has no PTT buttons.

### Virtual panels (boards unplugged)

When a board is not plugged in, its controls appear on screen, drawn from the same CAD layouts as the real
panels (`cad/tools/layouts.py` → `game/tools/gen_virtual_panels.py` → `game/config/virtual_panels.json`):
same switches, same places, same printed legends, with finger-sized touch areas.

| Board missing | Where its controls appear |
|---|---|
| Falcon Pilot | console **PANELS** tab: PILOT DASH A + B, the side console (drag the THROTTLE, tap the GEAR lever) and a touch stick (circle = pitch/roll, bar = yaw, TRIGGER) |
| Falcon Ops | console **PANELS** tab: OPS DASH A + B, the hyperspace console and a touch stick (circle = RCS left/right + up/down, bar = fwd/back, TRIGGER) |
| Falcon Command | console **CHECKLIST**: the three overhead panels; Commander **PANEL** page: CMD_A + CMD_B (mouse) |

How they work: toggles flip on a tap; **guarded switches (ENG ARM, JUMP ARM, EJECT) take two taps**: the
first lifts the red cover, the second flips the switch, and the cover drops back after 4 s. Push buttons are
held while your finger is on them. Encoder knobs: tap left/right of the knob to turn, the knob itself to
push; the mode legends light up. Several fingers work at once (both kids can use the screen together).
The MOTION key, CREW POS switch and STOP on CMD_B are drawn grey: they are hardwired to the actuators and only
exist on the real panel. Plugging a board in hides its virtual panels immediately (hot-plug); unplugging
shows them again. SETUP → ALWAYS SHOW (or `--virtual-panels`) keeps them on screen with the boards plugged in
(the real switches still win). The keyboard keys below keep working either way.

### Crew position (cradle recline + pod)

The seat cradle and the kids' pod are moved by the hardwired circuit in
[docs/electronics, diagram 04](../electronics/README.md): key, hold-to-run CREW POS switch, release lever,
limit switches, E-stop. **The game never moves anything.** Falcon Command only reads three isolated contacts:

| Contact | Pin / HID button | Game shows |
|---|---|---|
| CRADLE RECLINED | GPIO39, button 15 (`cradle_reclined`) | SEATS RECLINED; when it opens: SEATS MOVING for the travel time, then UPRIGHT |
| POD DOWN + LOCKED | GPIO40, button 26 (`pod_down_locked`) | POD DOWN-LOCKED; when it opens: POD MOVING for the travel time |
| POD UP + LOCKED (optional) | GPIO41, button 27 (`pod_up_locked`) | POD UP; open while reclined and not down = POD MOVING |

The interlock means the pod is always UP while the seats are not reclined. Without the optional UP contact the
game cannot tell "pod up" from "pod on its way" while reclined, so it shows `UP / MOVING` after the travel time
(SETUP: travel time, default 40 s; UP sense auto / yes / no). Callouts go out over the intercom MISSION CONTROL
channel: "Seats reclined. Stand by, pod coming down. Heads back, hands in.", "Pod down and locked.", "Pod going
up.", "Seats coming up. Hands in." The FLT / BRD lamps on CMD_B show POD DOWN-LOCKED (green), MOVING (amber,
blinking) and BOARDING POSITION (green). Keyboard test without the board: **Home** = cradle reclined,
**Delete** = pod down + locked.

Keyboard fallback (every action has one):

| Pilot | Key | Ops | Key | Commander / overhead | Key |
|---|---|---|---|---|---|
| Pitch | W/S | RCS left/right | J/L | Master power | F12 |
| Roll | Q/E | RCS down/up | K/I | Battery … Ign arm | F1–F6 |
| Yaw | A/D | RCS back/fwd | N/H | Cabin lights / beacon / strobe | F7 / F8 / F10 |
| Throttle | Shift/Ctrl | Trigger | Enter | Start / pause | F9 / Pause |
| Trigger (laser) | F | Reactor / life / shields / comms / sensors | 5–9 | Mission ◀ ▶ / select | PgUp / PgDn / Insert |
| Engine arm / ignition | T / Space | Fire suppression | R | Caution reset | Backspace |
| Boost / airbrake | Tab / B | Scanner ping | P | Fail: fire / leak / power / sensor | Ctrl+1…4 |
| Flaps up / down | , / . | Cargo doors / dock clamp | O / U | Sense: cradle reclined / pod down | Home / Delete |
| Gear / view | G / V | Nav target | M | Eject (covered) | F11 |
| Assist OFF/STAB/PRO/HOLD | 1–4 | Mode RCS / ARM / SCANNER | Z / X / C | Intercom talk (hold) | ` |
| Assist knob ◀ ▶ | − / = | Jump arm / engage | [ / ] | ALL-CALL (hold) | ' |
| Push to talk (hold) | \ | Push to talk (hold) | / | Debug slew on/off (paused) | Ctrl+F |

## 5. LED panel (serial) and udev

Godot has no serial API, so the game starts the bundled helper `game/tools/falcon_led_bridge.py`
automatically. The game sends protocol lines over UDP to `127.0.0.1:47800`, and the helper writes them to the
Command board. If python3 or pyserial is missing, or no board is plugged in, the game carries on without LEDs.
The Commander SETUP page shows the bridge status.

- Port lookup:
  1. `/dev/falcon-command` (udev rule from the firmware branch, `firmware/udev/`)
  2. `/dev/serial/by-id/*Falcon_Command*`
  3. any port with VID:PID `1209:0005`
- Install the udev rule from the firmware folder (`sudo cp …rules /etc/udev/rules.d/ && sudo udevadm control --reload && sudo udevadm trigger`).
  Also add yourself to `dialout` (`sudo usermod -aG dialout $USER`, then log out and in) so no sudo is needed.
- Opening the port asserts DTR, which the board takes to mean "game connected". Closing it returns the strip to its idle glow.
  The board stays silent unless `ACK ON` is sent. The bridge logs any `ERR`/`EVT` lines to stderr.
- Test without the game: `python3 game/tools/falcon_led_bridge.py --dry-run`.

## 6. Intercom (ICS): three USB headsets

Pilot, Ops and Commander each wear a USB headset. Every mic is heard in the other two headsets (with an
optional quiet sidetone in your own), the game sound (engine, alarms) and the voice callouts reach all three,
and each seat has its own game and intercom volume. A radio effect (300–3400 Hz band-pass, light compression,
optional static, a squelch tail and a mic click / roger beep) makes it sound like a real spacecraft loop; it
can be switched off on Commander → ICS.

**How it runs.** Godot can only open one audio device, so the intercom is a small helper,
`game/tools/falcon_ics.py` (Python + numpy). `run.sh` starts it; the game starts it itself if it is not
running, and they talk over localhost UDP (game → helper port 47810, helper → game 47811), like the LED bridge.
It uses the PulseAudio protocol (`pactl`, `parec`, `pacat`), which works with PulseAudio and with PipeWire
(`pipewire-pulse`, the default on Mint 22); the ICS page shows which server it found. It creates two virtual
outputs: `falcon_game` (the game switches its own output to it while the helper runs, and back to the normal
output if the helper stops) and `falcon_mc` (MISSION CONTROL: the voice callouts). If ROOM SPEAKERS is on, both
are also played on the default output. Audio runs in 5 ms blocks; mic → other headsets is about 30–40 ms.
If python3, numpy or the Pulse tools are missing, or no headset is plugged in, the intercom stays off and the
game plays sound as before; the reason is on the ICS page and in the log.

**Talking.** Each seat is **VOX** (voice-operated: the mic opens when you talk louder than the threshold, the
white tick on the meter, and stays open for the hang time) or **PTT** (push-to-talk). Kids default to VOX, the
Commander to PTT. PTT inputs: the PTT button on each board, the keys `\` (Pilot), `/` (Ops), `` ` `` (Commander),
the TALK pads on the kids' console and on MISSION CONTROL. Holding TALK also opens a VOX mic. The Commander
also has:
- **ALL-CALL / PA** (hold the ALL-CALL button, the `'` key or the ALL-CALL pad): talk to both kids louder, with
  a chime, while the game sound and their mics are ducked.
- **MUTE PILOT / MUTE OPS** (MISSION CONTROL or ICS page).
- The **MISSION CONTROL** channel carries the game's voice callouts (e.g. "pod coming down").

**4th seat: SPACEWALKER (Meta Quest 3).** While the Quest is connected through WiVRn, PipeWire has a **WiVRn**
speaker and (mic enabled in the headset app) a **WiVRn(microphone)** source. The helper picks them up as
"Meta Quest 3 (WiVRn audio)" and puts them on the SPACEWALKER seat by itself (a seat you set by hand wins).
The spacewalker hears everyone and the game sound, and everyone hears them through a **suit radio**: a
narrower 400–2600 Hz band, more static and NASA-style Quindar tones (2525 Hz when they start talking, 2475 Hz
when they stop). Their push-to-talk is the left X button on the Touch controller (or VOX). If the WiVRn devices
are not there (older WiVRn, mic off), the seat stays empty and the reason is on the ICS page; a 4th USB
headset can be picked for SPACEWALKER instead. MUTE EVA appears on MISSION CONTROL during a spacewalk.

**Setup (once).**
1. `sudo apt install python3-numpy pulseaudio-utils` (on plain PulseAudio systems the server is already there;
   on PipeWire make sure `pipewire-pulse` is installed, which it is on Mint 22).
2. Plug in the three headsets, start the game, open Commander → **ICS**.
3. For each seat pick **MIC IN** and **AUDIO OUT** (None / System default / a free device). A device already
   used by another seat is skipped, never stolen. Picks are saved by node + USB bus path so re-plugging keeps
   them. Press **IDENTIFY** to play a tone through that seat's AUDIO OUT only.
4. Talk into each mic and set the VOX level so the meter crosses the white tick when talking but not when
   breathing; or switch that seat to PTT.

**Troubleshooting.**

| Problem | Try |
|---|---|
| ICS says "missing pactl, parec, pacat" | `sudo apt install pulseaudio-utils` |
| ICS says "numpy missing" | `sudo apt install python3-numpy` |
| ICS says "no PulseAudio/PipeWire server" | `pactl info` must work in your session; on PipeWire: `sudo apt install pipewire-pulse`, then log out and in |
| A headset is not in the list | `python3 game/tools/falcon_ics.py --list` (lists every USB headset and the current assignment); press RESCAN |
| Which headset is which? | `python3 game/tools/falcon_ics.py --ident pilot` (or a device name) |
| Echo / feedback | sidetone OFF, ROOM SPEAKERS OFF if the speakers are loud, or use PTT |
| Choppy audio, "dropouts" counting up | close other audio apps; check the log; headsets on separate USB ports |
| Too much delay | `python3 game/tools/falcon_ics.py --latency-test pilot` measures the loop (needs that headset's mic near its speaker) |
| No game sound after a crash | the game switches back to the normal output by itself; else pick the output in the sound settings |
| Checking the setup without the game | `python3 game/tools/falcon_ics.py --setup-only` creates the virtual outputs, reports and exits |

Logs: `~/.local/share/filament-falcon/ics.log` (the helper writes there when started by `run.sh` or the game).
The helper exits when the game exits, and removes its virtual outputs. `--mock` runs it with fake headsets and
synthetic voices, which is what the tests use.

## 7. VR spacewalks (Meta Quest 3)

A fourth player wears a **Meta Quest 3** (USB cable, **WiVRn** on the PC) and goes outside: handrails,
a SAFER jetpack, a tether, tools and samples, with Earth, the Moon and the sun around them. The crew sees the
spacewalker in real time in the LEFT/RIGHT window views and every camera feed (docking, arm, the EVA drone);
the astronaut can wave, point, knock on the cockpit window or put a glove on the glass. Ops can catch a
drifting spacewalker with the robotic arm while the Pilot holds attitude.

![the spacewalker knocking on the left window](screenshots/35_eva_window_knock_close.jpg)

- **Full guide (install, USB, OpenXR runtime, audio, performance, safety, troubleshooting):**
  [VR_SETUP.md](VR_SETUP.md). More VR ideas: [VR_IDEAS.md](VR_IDEAS.md).
- **No headset?** Everything works on screen: Commander → **EVA** → driver ON SCREEN → START EVA, then click
  the helmet cam and fly with the keyboard/mouse or a gamepad. The game never needs an OpenXR runtime; the
  VR status is on Commander → SETUP and EVA.
- **Architecture:** the headset runs in a **separate process** of the same project
  (`./run.sh --eva-vr`, or LAUNCH VR CLIENT on Commander → EVA), which streams the astronaut's pose to the
  cockpit over UDP 47820 at ~90 Hz; the cockpit interpolates it (45 ms buffer). The cockpit itself never
  loads OpenXR, so its four windows stay smooth and a headset problem cannot crash the flight.
- **Spacewalks:** WINDOW VISIT, ANTENNA SWAP (station), ROCK SAMPLE + BEACON (asteroids), MOONWALK (1/6 g),
  CANADARM RESCUE (Ops + Pilot + spacewalker). With EVA IN MISSIONS on, missions add one by themselves.
- **Console:** an **EVA** tab appears during a spacewalk: HELMET CAM, EVA DRONE, suit telemetry (O2, battery,
  CO2, suit temperature, heart rate, jet gas, tether) and the task list.
- **Intercom:** the Quest's speaker and mic (WiVRn's virtual devices) are the 4th seat, **SPACEWALKER**, with
  a "suit radio" sound (narrower band, more static, Quindar beeps); see section 6.
- **Safety:** the spacewalker stands in a clear 2 × 2 m area **outside** the cockpit frame, Guardian on, a
  grown-up watching.

## 8. Crew guide (for kids!)

**Three jobs:**
- **PILOT** (left seat) flies the Falcon with the big stick and throttle. You point the ship, fire the
  engine, land it, and fire the mining laser.
- **OPS** (right seat) runs the ship. You handle power, shields, the RCS stick that slides the ship sideways,
  the robot arm and tractor beam, the scanner, the jump drive, and fixing things when they break.
- **COMMANDER** (a grown-up, or whoever is not flying) sits at the Commander screen: picks the mission,
  checks the harnesses, presses START, watches both kids' tasks on MISSION CONTROL, and can make things go
  wrong on purpose (engine fire, cabin leak, power fault, sensor glitch) to see if the crew can fix it.

**Before every mission:**
1. Turn the MASTER POWER key.
2. Flip the overhead switches **in order, left to right**: BATTERY, FUEL PUMPS, AVIONICS, APU, GUIDANCE,
   IGNITION ARM. Each one lights green when it is done in the right order (CHECKLIST page).
3. Both crew sit down and say "harness on!". The commander checks, clicks HARNESSES on MISSION CONTROL, then presses START.

**Flight assist (the knob):**
- **STAB** stops the ship from spinning.
- **PROGRADE** points the nose along the NAV vector.
- **HOLD** locks the nose where it is.
- **OFF** is real space: nothing slows you down!

The physics is real. The assists make it easy.

**Missions:**

| # | Mission | What happens | Pilot hero moment | Ops hero moment |
|---|---|---|---|---|
| 1 | **First Light** (launch) | Countdown, lift-off, fly to orbit and drop off a satellite. | Lighting the engine at T−5 and steering into orbit. | Staging the booster (auto boostback → Mechazilla catch) and releasing the satellite with the arm. |
| 2 | **Space Hug** (docking) | Glide into the space station slower than a snail. | Keeping the nose dead-on with HOLD. | Creeping in with the RCS stick on the docking camera, then DOCK CLAMP! |
| 3 | **Eagle Eye** (lunar) | Skim the Moon, find the beacon and land like a feather. | Slowing down and hovering to a soft touchdown. | Finding the beacon with the scanner and sliding the ship over it. |
| 4 | **Rock Hoppers** (asteroids) | Rescue a lost pod, mine three crystals, jump home. | Dodging rocks and lasering crystal rocks. | Tractor-beaming the pod and crystals aboard, then the JUMP! |
| 5 | **Homecoming** (reentry) | Blaze through the fiery air and glide onto the runway. | Holding the nose up, then flying the green boxes down to the runway. | Shields, beating the radio blackout, finding the runway. |
| 6 | **Free Flight** (sandbox) | No rules: visit every place with the jump drive. | Try ASSIST OFF! | Play with the arm, scanner and jump drive. |

Each mission shows a briefing with a job for each seat. The strip at the top of the kids' console always
shows each seat's current job, and the Commander's BRIEFING page lists every step with a ▶. At the end you
get a score, up to three stars and a celebration.

Tips:
- Go slow near things. The scoring loves gentle contact.
- If the MASTER CAUTION flashes, Ops looks at SYSTEMS. The fault list says what to do.
- The console's NAV page shows your orbit. On the Commander's MISSION CONTROL, **WARP** speeds time up while coasting. It drops back to ×1 when an engine fires or you get low.
  In the air it is limited to ×4.
- Homecoming is the longest mission: about 11 minutes, or about 4½ minutes using WARP ×4 during the high glide.

**Talking on the intercom:** in VOX mode just talk, your TALK pad lights up when the others can hear you. In
PTT mode hold your PTT button (or the TALK pad) while you talk, and let go to listen. Say "over" when you are done!

## 9. Tests (for developers)

```bash
cd game
godot --headless --path . --import                                        # import; must show no errors
godot --headless --path . --audio-driver Dummy -- --smoke-test           # every mission start→finish + every failure fixed by crew actions,
                                                                          # + screen-role resolver (4- and 3-screen rigs) and every console/Commander page,
                                                                          # + virtual panels (hot-plug, guarded 2-tap, held buttons, encoder),
                                                                          # + pod/seat state machine, + intercom end-to-end with the --mock helper
                                                                          # + EVA: cockpit without OpenXR, flat spacewalks (window, rescue, antenna)
                                                                          #   and the VR client process (no runtime → autopilot) streaming the pose,
                                                                          #   + the client parked on the Moon keeps the landing site steady (no jitter)
godot --headless --path . --audio-driver Dummy -- --smoke-test --only=eva        # just the EVA part (--eva-only=window,rescue,antenna,sample)
godot --headless --path . --audio-driver Dummy -- --eva-frame-test              # EVA physics frames: burn/turn don't drag a free-floater, handrail
                                                                          #   follows the hull, release inherits w x r, windows = VR position, origin shift
godot --headless --path . --audio-driver Dummy -- --eva-tether-test             # EVA tether: reel-in, hand over hand, burn GO/NO-GO, towing/snap, Moon liftoff
godot --headless --path . --xr-mode on -- --eva-client --eva-selftest            # the VR client starts cleanly with no OpenXR runtime
XDG_DATA_HOME=/tmp/ff godot --headless --path . -- --asset-test               # every shader compiles + HD texture cache round-trip
godot --headless --path . -- --region-test --region-dir=DIR                    # region chunks: sync build + threaded streaming
python3 tools/area_manager.py estimate fredericton --offline                   # area manager (no downloads)
XDG_DATA_HOME=$(mktemp -d) godot --headless --path . -- --area-runner-test   # AREAS runner: auto-start, stale-job recovery, start failure shown
XDG_DATA_HOME=$(mktemp -d) godot --headless --path . -- --nav-map-test       # nav map globe + GROUND close-up, overlays, procedural fallback
XDG_DATA_HOME=$(mktemp -d) godot --headless --path . -- --map-layer-test     # AREAS map roads / rivers / lakes / names by zoom, fallback button
python3 tools/test_map_layer.py                                          # map_layer.py on a tiny generated .osm.pbf (needs pyosmium)
python3 tools/test_falcon_ics.py                                         # intercom: DSP (band-pass, compressor), VOX, mixing/routing,
                                                                          # drift rings, device grouping (PulseAudio + PipeWire), replug matching,
                                                                          # the SPACEWALKER seat (WiVRn detection, suit radio, Quindar tones)
python3 tools/gen_virtual_panels.py --check                              # virtual panel layout matches cad/tools/layouts.py
godot --headless --path . --audio-driver Dummy -- --flight-test          # bots actually FLY every mission with cockpit controls
godot --headless --path . --audio-driver Dummy -- --flight-test --only=reentry --trace
GODOT=godot tests/run_screenshots.sh                                      # screenshots via xvfb + lavapipe → docs/game/screenshots/
```

The smoke and flight tests exit with a non-zero code on failure. The flight test bots use only the same
inputs the crew have (switches, sticks, throttle, buttons). Each mission is completed with real physics,
with no teleporting.

Debug flags: `--persp` uses a plain 70° camera instead of the off-axis frustum. `--far=`/`--near=` override the
clip planes. Keep far/near ≤ 1e6, because float32 frustum culling breaks beyond that. Distant bodies are drawn
in "scaled space" so their size on screen stays correct.
