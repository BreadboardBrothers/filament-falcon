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
- **ATTACH** / **ATTACH ROT** follow the ship as it moves (orbit/zoom with the mouse; WASD detaches).
- Real **ShipModel** (engines, RCS, doors, gear, plasma) animated from `Game` state; **booster** shown under/aft while `booster_attached`; **EVA astronaut** (+ simple tether) while `Eva.active`.
- When far away a faint red marker keeps the ship findable; zoom/attach to see the real model.

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
`--solar-test` covers ephemeris, clips, half-screen warp, separate Sun exag + moon orbit exag, body-on-orbit across scrubbed times, parent-attached moon orbits, sky catalogs, ship-path default (red trajectory), attach orbit/zoom + WASD detach, FALCON warp/attach + ShipModel/booster.

## Files
- `game/data/solar/catalog.json`, `facts.json`, `sky_stars.json`, `sky_galaxies.json`
- `game/scripts/solar/ephemeris.gd`, `game/scripts/ui/solar_view.gd`
- `game/shaders/solar/body.gdshader`, `ring.gdshader`
- `game/tools/fetch_solar_assets.sh`, `build_moon_catalog.py`
