# Commander SOLAR page

True-scale solar-system visualizer on **Commander → SOLAR**. Offline by default (bundled Keplerian elements); optional NASA / Solar System Scope textures downloaded on the game PC.

## What you get
- Sun + 8 planets + 5 dwarf planets and **~460 moons** (JPL SSD mean elements).
- **True scale** by default. **EXAG. SIZE** inflates planets, dwarfs, **and moons** (moon orbital radii scale so moons sit outside the exaggerated planet). **EXAG. SUN** is a **separate** toggle (default off), capped so the Sun never reaches Mercury’s orbit.
- **LABELS** / **MOON LABELS**: screen-space name tags with short leader lines, decluttered and distance-faded.
- **SKY** / **GALAXIES** / **CONSTELLATIONS**: Milky Way panorama (when fetched), bright-star field from a bundled Yale/Hipparcos subset (correct RA/Dec → ecliptic), optional constellation stick figures, nearby galaxies (M31, M33, LMC, SMC, …) at correct sky positions/sizes.
- Floating origin + scene-unit scaling + distant impostors; dynamic near/far clips.
- Hover fact card (ray pick). Warp/attach frames ~half screen from the lit side.
- **Orbit lines update with time**: planet polylines resample as JD changes; moon orbits are drawn relative to the parent’s **current** position so they travel with the planet. Bodies stay on their lines.
- **SHIP PATH** default **off** (the old orange/yellow trajectory + tall ticks looked like “yellow lines from Earth”).

## Filament Falcon
- **FALCON** in WARP TO: frames the live ship (~half screen) and turns on the **red** SHIP PATH trajectory.
- **BOOSTER** in WARP TO: frames a free / recovering stage (cyan path). Available after staging.
- **ATTACH** / **ATTACH ROT** follow the ship **or booster** as it moves (orbit/zoom with the mouse; WASD detaches).
- Real **ShipModel** (Raptor 3 engines, RCS, doors, gear, plasma) animated from `Game` state; attached **booster** under/aft while `booster_attached`; free booster uses `Models.booster()` (grid fins, legs, multi-Raptor cluster); **EVA astronaut** (+ simple tether) while `Eva.active`.
- When far away a faint marker keeps the vehicle findable; zoom/attach to see engines/fins.
- **Close zoom:** ATTACH → wheel in uses true `_dist` (no 1 km scale floor), min ~few metres. Close-vehicle mode hides planets/orbits/sky (same perf win for ship and booster).
- **Perf / audio:** path/orbit rebuilds throttled on FALCON/BOOSTER; SFX buffer 0.5 s + chunk refill after hitches.

## Camera
- **Free flight:** WASD/QE move, hold right mouse to look, wheel zoom.
- **Attached** (ATTACH / ATTACH ROT): left- or right-drag **orbits** around the body (yaw/pitch, clamped so it does not flip at the poles); **wheel** zooms on a log scale (min just above the surface, max far enough to see its moons). Orbit angles and distance are kept as the body moves. Smoothing eases the motion. **Shift+drag** or **middle-drag** pans (and detaches). **WASD/QE** detaches into free flight.

## Yellow lines (fixed)
**Root cause:** `_update_ship()` drew the predicted ship trajectory in orange (`Color(1.0, 0.55, 0.15)`) plus long vertical yellow tick marks (`Color(1.0, 0.8, 0.3)`) from the geocentric ship state near Earth, and `show_ship_path` defaulted to **true**.  
**Fix:** default off; short cyan ticks; enable only via **SHIP PATH**.

## Accuracy limits
| Class | Typical error | Notes |
|-------|---------------|-------|
| Planets (decades around J2000) | ~1e-3 AU | JPL approx elements |
| Earth's Moon | hundreds of km | Simple Keplerian |
| Moons (JPL SSD mean elements) | schematic vs Horizons | Visualizer quality |
| Sky stars / galaxies | catalog positions | Bundled subset; textures optional |
| Ship path | sketch | Bodies on rails |

## Assets (Yves’s PC)
```
game/tools/fetch_solar_assets.sh
# or: game/tools/fetch_assets.sh
```
Downloads into `~/.local/share/filament-falcon/assets/solar/` (skips non-image responses so HTML landing pages are never kept as `.jpg`):
- Planet/Sun/Moon maps (Solar System Scope CC BY 4.0); Io from NASA Science “Jupiter - Io (A)” (USGS/Voyager)
- `stars_milky_way.jpg` (SSS milky-way / starfield)
- `sky/*.jpg` galaxy stills (ESA/Hubble/ESO/Wikimedia — see `SOURCES.txt`)
- Optional JPL moon overlay via `build_moon_catalog.py`

Bundled (no download): `game/data/solar/sky_stars.json`, `sky_galaxies.json`, `facts.json`, `catalog.json`.

## Headless check
```
XDG_DATA_HOME=$(mktemp -d) godot --headless --path game -- --solar-test
XDG_DATA_HOME=$(mktemp -d) godot --headless --path game -- --ui-fit
```
`--solar-test` covers ephemeris, clips, half-screen warp, separate Sun exag + moon orbit exag, body-on-orbit across scrubbed times, parent-attached moon orbits, sky catalogs, ship-path default (red trajectory), attach orbit/zoom + WASD detach, FALCON + BOOSTER warp/attach/close-zoom + ShipModel/booster.

Booster RTLS / Mechazilla catch: `--booster-recovery-test` (lean FSM → caught near pad).

## Files
- `game/data/solar/catalog.json`, `facts.json`, `sky_stars.json`, `sky_galaxies.json`
- `game/scripts/solar/ephemeris.gd`, `game/scripts/ui/solar_view.gd`
- `game/shaders/solar/body.gdshader`, `ring.gdshader`
- `game/tools/fetch_solar_assets.sh`, `build_moon_catalog.py`

## Rendering precision regression
SOLAR is constructed while the Commander tab may still be hidden. The old startup
clips (near 0.1, far 10,000,000) produced a **zero far-plane normal** in Godot's
float32 projection, even with sun shadows disabled. Godot's light culler cannot
intersect that plane to form frustum corners (`create_frustum_points:682`).
Startup now uses the same bounded clips as active SOLAR; far/near is capped at
1,000,000 and the viewport renders only when visible. Close ship/booster metre
scaling and local engine lights remain; world shadows and cockpit projections
are not disabled or changed. `--solar-test` checks all eight actual projection
plane intersections, including hidden initialization, planet/vehicle zooms and
twin OTW frusta. A headless test proves the matrix defect, not a GPU reproduction.

## Galaxy images and offline fallback
Galaxies retain bundled RA/Dec, angular size and position angle even without photos.
Missing/unreadable/HTML-as-JPEG files now produce soft transparent elliptical glows,
not the old uniform 85%-opaque pale rectangular quads. Valid galaxy photos use a
galaxy-only shader: preserve alpha, softly mask black photographic backgrounds and
feather quad borders. Planet textures and the Milky Way panorama are not black-keyed.
Bright stars remain intentional tiny 3-pixel points (not large galaxy rectangles).

No download is needed to remove the squares. The launcher does not fetch large sky
assets automatically. Optional photos/panorama can be requested explicitly from the
repository root with `bash game/tools/fetch_solar_assets.sh`, then relaunch. This
existing script downloads the broader optional SOLAR texture set, not just galaxies;
its four galaxy mappings are M31, M33, LMC and SMC. Other catalog galaxies keep the
schematic glow; failed downloads also keep it. No source URLs were fetched by this
fix. `--solar-test` covers missing/corrupt/valid synthetic fixtures; with an actual
renderer it also checks transparent corners, edge fading, black-background keying
and preserved image alpha in viewport pixels.

## Exhaust anchoring
Ship and booster plume/haze meshes use baked unit vertices from local Y=0 (nozzle)
to Y=-1 (tail), rotated to body +Z. Increasing length scales vertices away from the
nozzle, never forward through the hull. Previously the ship translated a centred
cylinder by only 0.5 m, then scaled that mesh around its centre—full throttle drove
half the exhaust and refractive haze forward into the ship. The shader also received
the wrong along-plume coordinates. Both effects now share nozzle-origin geometry;
haze opacity fades toward the tail. World and SOLAR use the same models, not a
SOLAR-only exhaust visibility workaround. `--solar-test` checks actual vertices at
low/full thrust, atmosphere/vacuum, rotation and scene scaling.

### Nozzle-sized exhaust
Ship exhaust now uses six individual open jets (three sea-level and three vacuum),
and the booster uses its nineteen modelled engine exits. Each root stays centred
on its actual bell lip at the bell radius, independent of throttle/vacuum; only
the downstream envelope spreads and lengthens. The capped cluster-wide disk and
always-on hot plate are gone. Heat haze follows the same small roots with a soft
start. Shared meshes/materials keep this procedural (no particles or downloads).
Engine-off and attached upper-stage engines remain dark. Verify in SOLAR → FALCON
→ ATTACH, close zoom, then vary throttle; stage and follow BOOSTER to compare.
