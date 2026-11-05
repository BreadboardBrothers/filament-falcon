<div class="cover">
<div class="kicker">THE FILAMENT FALCON</div>
<h1 class="title">Updates &amp; Quick Start</h1>
<p class="sub">What changed since mid-October 2026, and how to get from a fresh PC to a crew in orbit.</p>
<p class="meta">Game v0.1 · Godot 4.7.2 · Linux Mint 22 · November 5, 2026</p>
</div>

# Part 1 · What's new since mid-October

<table class="log">
<tr><th>Date</th><th>Update</th><th>Commit</th></tr>
<tr><td>Oct 24</td><td>Real-size Earth and Moon, the area manager and the AREAS page, procgen and water fixes</td><td>48fd6eb</td></tr>
<tr><td>Oct 25</td><td>Area fixes: format error, map ids, safe delete, &gt; 120 km clamp or split</td><td>6bbab06</td></tr>
<tr><td>Oct 25</td><td>Touchscreen isolation and the vanishing-cursor fix</td><td>67dc3f4, 1bbccc7</td></tr>
<tr><td>Oct 25</td><td>Hand tracking: glove orientation and finger curls</td><td>f07597b</td></tr>
<tr><td>Oct 25</td><td>EVA physics: the spacewalker is its own inertial body</td><td>ffa5347</td></tr>
<tr><td>Oct 25</td><td>Tether pull-back, REEL IN, and flying with someone outside</td><td>7e8a09e</td></tr>
<tr><td>Oct 26</td><td><code>setup.sh</code>: one-shot install and doctor</td><td>226a8c1</td></tr>
<tr><td>Oct 27</td><td>AREAS job runner really starts (the "QUEUED 0 %" fix)</td><td>785e754</td></tr>
<tr><td>Oct 27</td><td>Nav map: lit Earth/Moon globes and a GROUND close-up</td><td>9f8a222</td></tr>
<tr><td>Oct 27</td><td>AREAS map: roads, rivers, lakes and place names</td><td>44fc758</td></tr>
<tr><td>Nov 5</td><td>ICS audio quality: 48 kHz, float capture, cubic resample, SoftLimiter, LOW/NORMAL/HIGH/HI-FI</td><td>cdde1f6</td></tr>
<tr><td>Nov 5</td><td>Commander SOLAR page: true-scale system, moons, time scrub, ship path</td><td>(this release)</td></tr>
</table>

## Real-size Earth and Moon
- The universe is now real size: a 6,371 km Earth with real gravity and a 1,737 km Moon at 384,400 km. Every mission and robot flight test is retuned for it. Launch goes to a 200 × 150 km orbit at about 7.6 km/s.
- No jitter at any scale. Positions are kept in double precision with a floating origin (the ship is always at 0). The planet is a cube-sphere quadtree that goes down to about 2.4 m cells. Its chunks are built on worker threads.
- The ground uses the best data available: a built OSM detail region, then an area pack (~20 m DEM, water and imagery), then the global NASA set, then noise. The physics and the meshes share one height function, so what you see is what you land on.
- Debug slew goes up to 1,000 km/s, so you can cross the planet or fly to the Moon. Time warp goes up to ×10,000.

## Area manager, AREAS page and the runner fix
- **Commander → AREAS** lets you pick any place on Earth: a preset, LAT / LON + radius, or a box dragged on the map. It shows the download sizes, then queues DEM, Sentinel-2 imagery, the Geofabrik OSM extract and the 3D build. The same tool works from a terminal (`tools/area_manager.py`).
- It always uses the smallest Geofabrik extract that covers the area, never the planet file. An area over a border uses each province's extract (for example, the Bay of Fundy uses NB and NS). Extracts are reused for 30 days.
- Areas larger than 120 km a side can be clamped, or split into tiles.
- **Runner fix:** jobs used to sit at "QUEUED 0 %" because the background runner kept handing over to a copy of itself and never started. Now it really starts. It holds a `flock` lock and recovers jobs stalled by a dead runner. The page shows RUNNER RUNNING / NOT RUNNING / FAILED TO START with the reason, and **RUN / RETRY NOW** retries by hand. `status` explains why each job is waiting.

## Procgen and water fixes
- Water is blue again everywhere. Close up, a reflective water shader draws a flat surface at the real lake or river level. From orbit, the planet shader forces water to deep blue with a sun glint.
- Region builds are now v3:
  - Lakes keep their islands.
  - Rivers are drawn at their width.
  - Water beds are carved and the banks raised.
- Other fixes:
  - DEM sampling was half a pixel off.
  - Buildings sat on their centre and floated on slopes. They now sit on their lowest corner.
  - Roads now follow the ground.
  - Trees are no longer placed on water.
  - The region frame was 0.6 % off and rotated.
- A crash in the terrain workers (SIGSEGV in `EarthTerrain.sample`) is fixed.

## Touchscreen isolation
- A tap on the kids' console used to steal Dad's mouse pointer and keyboard focus. While the game runs, `run.sh` now *floats* the touchscreen, so it no longer moves the cursor and Godot still gets the multi-touch. The console window never takes keyboard focus.
- The cursor no longer vanishes after a tap. That was Cinnamon hiding it, and the game now nudges it back.
- Everything is restored on exit or crash. To turn it off: `./run.sh --no-touch-isolate`.

## EVA physics
- The spacewalker is a real inertial body. On letting go of a rail, the arm or the frame, they keep the hull's velocity at that point plus their push-off.
- The tether and hull bumps react to the motion of the turning, accelerating ship.
- The cockpit windows, camera feeds and VR head all agree on where the astronaut is, also with the free camera.

## Tether pull-back and takeoff
- **Hand over hand:** grip the line and pull it to your chest. You keep the momentum when you let go.
- **REEL IN:** hold a thumbstick click, or the crew presses REEL IN on the Commander or console EVA page. It reels at a SLOW, MED or FAST speed and stops at the hatch.
- **Tension:** a warning at 1,500 N, and the line snaps at 4,500 N. The tension is shown on the wrist, the Commander page and the console.
- **Flying while someone is outside:** nothing is locked out. IGNITION asks the Commander for **BURN GO / NO-GO**. Someone holding a rail rides along with the ship. A tethered spacewalker is towed, and someone standing on the Moon is left behind. The walk ends at 150 m, in an atmosphere or on mission failure.

## Hand-tracking fix
- With hand tracking (controllers put down), the gloves pointed their fingers out of the back of the hand and curled toward the wrist. The glove frame and the finger curls are now worked out from the joint *positions*, so both hands curl correctly. `--hand-test` checks this.
- VR also quits in order now, ending the OpenXR session first, which fixes a crash on exit.

## setup.sh
- One script sets up a fresh cockpit PC:
  - apt packages and pyosmium;
  - Godot 4.7.2 (SHA-512 checked);
  - WiVRn, adb and the udev rules;
  - the game assets and a first project import.
- It is safe to re-run, and `--dry-run` shows every command first.
- `./setup.sh --check` is a "doctor" that reports OK / WARN / MISSING with numbered next steps.

## Nav map Earth/Moon upgrade
- The console NAV map and the Commander ORBIT MAP draw a lit globe made from the real textures, with no extra memory:
  - **Earth:** a day/night terminator, city lights, clouds, an ocean glint and an atmosphere glow.
  - **Moon:** LROC colour, LOLA relief shading and Lommel–Seeliger lighting.
- Areas and the home region are marked on the globe.
- Below about 0.35 Earth radii, a **GROUND** close-up appears. It shows the ground under the ship, the ground track, the heading, the area imagery, and an OSM overlay with water, roads, buildings and towns (`tools/nav_overlay.py`).

## OSM map overlay on the AREAS page
- The AREAS map now draws:
  - lakes and rivers;
  - roads, major first, with primary, secondary and tertiary roads appearing as you zoom in;
  - place names, from city to town, village and hamlet as you zoom in, with no overlapping labels.
- The data comes from `tools/map_layer.py`, which turns the cached Geofabrik extracts into small `maps/*.ffml` files. The map loads them in the background and draws only what is in view.
- Without a layer the map works as before and offers **BUILD MAP LAYER**. The AREAS runner also refreshes the layer after every OSM download.


## ICS audio quality
- The intercom helper now runs at **48 kHz**, 10 ms blocks, float32 capture (s16le fallback), cubic drift resampling, a soft limiter, and gentler VOX / radio defaults.
- **Commander → ICS → AUDIO QUALITY**: LOW / NORMAL / HIGH / HI-FI. Default **HIGH**. Godot mix rate is 48 kHz. Details: `docs/game/AUDIO_TROUBLESHOOTING.md`.

## Commander SOLAR page
- **Commander → SOLAR** shows the solar system at **true scale** (optional labeled **EXAG. SIZE**), with real Keplerian orbits, a UTC scrubber, orbit toggles, warp / attach, time rates from pause to 100 yr/s, WASD+mouse camera, and a predicted ship path.
- Bundled catalog: Sun, planets, dwarfs, **293 moons**. Offline by default. Textures: `game/tools/fetch_solar_assets.sh` (also via `fetch_assets.sh`) on the game PC. See `docs/game/SOLAR.md`.
- Headless: `godot --headless --path game -- --solar-test`.

# Part 2 · Quick start

<div class="note">All commands run from the repo folder (e.g. <code>~/filament-falcon</code>). Downloads and generated data go to <code>~/.local/share/filament-falcon/</code>, never into the repo.</div>

## 1 · Install everything: `setup.sh`
```
git clone https://github.com/breadboardbrothers/filament-falcon.git
cd filament-falcon
./setup.sh --dry-run      # optional: show the plan, change nothing
./setup.sh                # asks once, then installs (sudo password)
```
**Log out and back in** after the first run (new groups, `~/.local/bin` on PATH), then run `./setup.sh --check` until nothing is MISSING. Useful flags: `--no-assets`, `--no-hd`, `--no-vr`, `--no-hardware`, `--region=NAME`.

## 2 · Earth and Moon textures: `fetch_assets.sh`
`setup.sh` already runs this. Re-run it any time; finished files are skipped:
```
game/tools/fetch_assets.sh              # NASA Earth/Moon (HD) + the Fredericton region
game/tools/fetch_assets.sh --no-hd      # ~80 MB less
```
It also builds the nav-map overlays, the AREAS map layer, and (when online) the SOLAR planet textures. Without assets the game uses its procedural planet / colored spheres.

## 3 · Building regions (3D cities)
The easiest way is the **AREAS** page (section 6). From a terminal:
```
cd game
python3 tools/build_region.py --list                 # NB presets: fredericton, moncton, saint-john, …
python3 tools/build_region.py --region moncton
python3 tools/area_manager.py add --id home --center 45.96,-66.64 --radius 5 --run
```
A built region loads by itself when you fly within 30 km of it below 60 km. Regions from before v3 need a rebuild (AREAS → REBUILD).

## 4 · Start the game: `run.sh`
```
cd game
./run.sh --cockpit        # one fullscreen window per screen (the rig)
./run.sh --dev            # all four views in one window (laptop)
```
`run.sh` imports the project on first launch, maps the touchscreen to the console and isolates it, and starts the intercom helper. **Shift+Esc** quits; **Shift+End** toggles dev/cockpit; **Esc** shows the Commander tab when there is no Commander monitor.

## 5 · Commander screen tour
<table class="tour">
<tr><th>Page</th><th>What it's for</th></tr>
<tr><td>Status row</td><td>Boards plugged in or VIRTUAL, the crew position and the intercom state. Always visible.</td></tr>
<tr><td>MISSION CONTROL</td><td>Pick a mission, then START / PAUSE / FLY AGAIN. Also failure injection, the orbit map, WARP, VIEW, the crew's tasks, faults, MASTER CAUTION RESET, and TALK / ALL-CALL.</td></tr>
<tr><td>MISSIONS</td><td>Every mission, EVA and destination by category, with diagrams and the Captain's Log.</td></tr>
<tr><td>BRIEFING</td><td>The full briefing and objectives, and READ BRIEFING ALOUD.</td></tr>
<tr><td>TRAINING</td><td>Difficulty, skip the checklist for little crews, assist override, callouts and failures.</td></tr>
<tr><td>CONTROLS</td><td>A live test of every switch and axis, the LED test, and the input-map export.</td></tr>
<tr><td>PANEL</td><td>The Falcon Command panels on screen, REFUEL, and the debug slew / free camera (Ctrl+F while paused).</td></tr>
<tr><td>ICS</td><td>The intercom: the headset for each seat, IDENTIFY, meters, VOX/PTT, volumes and the radio effect.</td></tr>
<tr><td>EVA</td><td>Spacewalks: LAUNCH VR CLIENT, START EVA, REEL IN, BURN GO / NO-GO, and comfort options.</td></tr>
<tr><td>AREAS</td><td>Download and generate real places (next section).</td></tr>
<tr><td>SOLAR</td><td>True-scale solar system, moons, time scrub, warp, ship path. See § SOLAR above / <code>docs/game/SOLAR.md</code>.</td></tr>
<tr><td>SETUP</td><td>Screen roles, quality, FPS, vsync, LED link, headsets, virtual panels and QUIT.</td></tr>
</table>

## 6 · The AREAS page
1. **Pick** an area: a preset, LAT / LON + RADIUS → SET, or the map (wheel = zoom, right-drag = pan, left-drag = box, click = 10 km box). Check the estimate: tiles, MB and the OSM extract.
2. **Over 120 km?** Choose CLAMP TO 120 km or SPLIT INTO TILES.
3. **Queue:** tick the steps (DEM, IMAGERY, OSM EXTRACT, 3D BUILD), then **QUEUE DOWNLOAD + GENERATE**.
4. **Run:** the runner starts by itself and keeps going if the game quits. The runner line shows the job, step, MB and progress. **RUN / RETRY NOW** starts it by hand. The terrain reloads when a job finishes.
5. **Map layer:** press **BUILD MAP LAYER** (top right of the map) once an extract is downloaded, to get roads, rivers and names.

**Manual workaround** if the page shows RUNNER NOT RUNNING / FAILED TO START, or downloads never move:
```
pkill -f "area_manager.py run"              # leftovers from the old version
cd game
python3 tools/area_manager.py status        # why each job waits, missing modules, log tail
python3 tools/area_manager.py run --wait    # work the queue in this terminal (Ctrl+C = pause)
python3 tools/map_layer.py                  # the AREAS map layer, by hand
```
Log: `~/.local/share/filament-falcon/areas/runner.log` (`tail -f` it).

## 7 · VR spacewalk (Meta Quest 3)
**Once:**
1. Turn on developer mode in the Meta Horizon app.
2. Connect the USB-C data cable and accept *Allow USB debugging*. `adb devices` must say `device`.
3. Install the WiVRn app on the headset.
4. In its settings, enable the microphone and hand tracking.

**Each time:**
1. Start the cockpit with `./run.sh --cockpit`, and put the Quest on.
2. Open Commander → **EVA** and pick a spacewalk.
3. Press **LAUNCH VR CLIENT**. WiVRn and `adb reverse` start by itself. The status line should read *VR client connected · … · 90 Hz*.
4. Press **START EVA**.

On the Touch controllers:
- grip = grab, trigger = use, left stick = jetpack, left X = push-to-talk;
- thumbstick click (hold) = REEL IN, Menu (hold 1 s) = recenter.

No headset? Choose the driver **ON SCREEN** and fly with WASD.

Safety: a clear 2 × 2 m area outside the cockpit, Guardian on, and a grown-up watching.

## 8 · Intercom (ICS)
1. Plug in the three USB headsets and open Commander → **ICS**.
2. For each seat, press ◀ ▶ until the right headset shows, then **IDENTIFY**: a tone plays in that headset only. Choices are saved by name, serial and USB port.
3. Set the VOX level so the meter crosses the white tick when talking, or switch that seat to PTT. Push-to-talk keys: `\` Pilot, `/` Ops, `` ` `` Commander, `'` ALL-CALL.
4. Set **AUDIO QUALITY** (LOW / NORMAL / HIGH / HI-FI; default HIGH) if the radio effect is too harsh or too clean.
5. When the Quest is connected, it becomes the 4th seat, **SPACEWALKER**, with a suit-radio sound and Quindar beeps.

## 9 · Touchscreen
- `run.sh` maps the touch panel to the console output and isolates it from the mouse on every start.
- To make the mapping permanent at login, add `game/tools/setup_displays.sh` to Startup Applications (5 s delay).
- Check it with `game/tools/setup_displays.sh --list` and `game/tools/touch_isolate.sh status`.
- If touch stops working in the game, try `FALCON_TOUCH_ISOLATE=master ./run.sh --cockpit`.

## 10 · Troubleshooting
<table>
<tr><th>Problem</th><th>Try</th></tr>
<tr><td>Parse errors on first launch ("CelestialBody not declared")</td><td>Start with <code>./run.sh</code>, or run <code>godot --headless --path . --import</code> once</td></tr>
<tr><td>Something missing after install</td><td><code>./setup.sh --check</code>, then follow the numbered steps</td></tr>
<tr><td>Procedural planet instead of NASA Earth</td><td><code>game/tools/fetch_assets.sh</code></td></tr>
<tr><td>Area stuck at QUEUED 0 %</td><td>RUN / RETRY NOW, or the manual workaround in section 6</td></tr>
<tr><td>"missing python module(s)" on AREAS</td><td><code>sudo apt install python3-numpy python3-pil</code>; <code>pip install --user --break-system-packages osmium</code></td></tr>
<tr><td>No roads / names on the AREAS map</td><td>BUILD MAP LAYER, or <code>python3 game/tools/map_layer.py</code> (needs pyosmium)</td></tr>
<tr><td>Green water / old-looking city</td><td>Rebuild the region (AREAS → REBUILD); re-run <code>fetch_assets.sh</code> for mask v2</td></tr>
<tr><td>Taps land on the wrong monitor</td><td><code>game/tools/setup_displays.sh</code></td></tr>
<tr><td>Mouse cursor gone / jumps to the console</td><td>Start through <code>run.sh</code>; don't run <code>unclutter</code>; <code>touch_isolate.sh stop</code> restores it</td></tr>
<tr><td>Intercom off or silent</td><td>Read the reason on the ICS page; <code>sudo apt install python3-numpy pulseaudio-utils</code>; <code>python3 game/tools/falcon_ics.py --list</code></td></tr>
<tr><td>Intercom sounds muffled / telephone-like</td><td>Commander → ICS → AUDIO QUALITY → HIGH or HI-FI; see <code>AUDIO_TROUBLESHOOTING.md</code></td></tr>
<tr><td>SOLAR spheres, no planet maps</td><td><code>game/tools/fetch_solar_assets.sh</code> on the game PC</td></tr>
<tr><td>Echo in the headsets</td><td>Turn sidetone and ROOM SPEAKERS off, or use PTT</td></tr>
<tr><td>"No OpenXR runtime" / VR opens a flat window</td><td>Start the WiVRn server and connect by USB, then LAUNCH VR CLIENT again</td></tr>
<tr><td><code>adb devices</code> says unauthorized</td><td>Accept USB debugging in the headset; <code>adb kill-server; adb devices</code></td></tr>
<tr><td>Gloves look wrong with hand tracking</td><td><code>git pull</code> (fixed on Oct 25); <code>~/.local/share/filament-falcon/eva_vr.log</code></td></tr>
</table>
<p class="foot">Full details: <code>docs/game/README.md</code>, <code>SETUP.md</code>, <code>REAL_EARTH.md</code>, <code>VR_SETUP.md</code>.</p>
