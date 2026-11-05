# Commander SOLAR page

True-scale solar-system visualizer on **Commander → SOLAR**. Offline by default (bundled Keplerian elements); optional NASA / Solar System Scope textures downloaded on the game PC.

## What you get
- Sun + 8 planets + 5 dwarf planets (Pluto, Ceres, Eris, Haumea, Makemake) and **~460 moons** from JPL SSD mean elements (Earth→Pluto; irregulars included). Bundled catalog ships the full set; re-run the fetch script on the game PC to refresh.
- Planet positions from JPL approximate Keplerian elements with century rates (`ssd.jpl.nasa.gov/planets/approx_pos.html`). Moons from [Planetary Satellite Mean Elements](https://ssd.jpl.nasa.gov/sats/elem/) (+ radii/GM from [phys_par](https://ssd.jpl.nasa.gov/sats/phys_par/) when published).
- **True scale** by default (planet discs are tiny at AU ranges). Toggle **EXAG. SIZE** (clearly labeled) to inflate radii for overview.
- Floating origin + log-scaled clip planes so you can fly from the Sun to a moon without precision loss.
- Time: scrubber ±50 years, **NOW**, UTC clock, rates from pause / real-time through 100 yr/s and reverse.
- Orbit lines (global / planets / moons), warp-to buttons, attach (inertial or rotating), WASD+QE move, RMB look, wheel zoom, AUTO/SLOW/MED/FAST/AU/s camera speed.
- Ship marker + predicted trajectory (Sun+planets on rails, RK4 n-body) with span 1 d / 7 d / 30 d / 1 y.

## Accuracy limits
| Class | Typical error | Notes |
|-------|---------------|-------|
| Planets (decades around J2000) | ~1e-3 AU | JPL approx elements; no perturbations |
| Earth's Moon | hundreds of km | Simple Keplerian, not DE440 |
| Moons (JPL SSD mean elements) | schematic vs Horizons | Mean precessing ellipses — not for precise ephemerides; good for the visualizer |
| Tiny irregulars without phys_par radius | radius ≈ 1.5 km placeholder | Orbital elements still from JPL; refresh phys_par when published |
| Ship path | sketch | Bodies on rails; no SRP / drag / burns |

Valid UI range: roughly J2000 ± 50 years (scrubber). Elements remain usable further out but drift.

## Textures (Yves's PC)
```
game/tools/fetch_solar_assets.sh
# or as part of:
game/tools/fetch_assets.sh
```
Writes under `~/.local/share/filament-falcon/assets/solar/` (Sun/planets/Moon 2K maps from [Solar System Scope](https://www.solarsystemscope.com/textures/), CC BY 4.0). `SOURCES.txt` lists credits. Drop NASA / USGS / JPL public-domain maps in the same folder using the same filenames (`earth_map.jpg`, `mars_normal.jpg`, …). Without textures the page uses procedural colors.

Moon catalog refresh (on the game PC; network, ~700 KB HTML cached under `~/.local/share/filament-falcon/cache/jpl/`):
```
python3 game/tools/build_moon_catalog.py
# also writes ~/.local/share/filament-falcon/assets/solar/moons_full.json (runtime overlay)
python3 game/tools/build_moon_catalog.py --update-catalog   # rewrite game/data/solar/catalog.json
python3 game/tools/test_build_moon_catalog.py               # offline parser self-test
```
Source is the HTML tables at `ssd.jpl.nasa.gov/sats/elem/` (there is **no** JSON `satelm.api`). Failures print HTTP status and the first response bytes. Offline / failure keeps the bundled catalog.

## Headless check
```
XDG_DATA_HOME=$(mktemp -d) godot --headless --path game -- --solar-test
```
Checks: catalog load, moon count ≥ 290 (bundled ~460 after JPL refresh), Earth ≈ 1 AU at J2000 and 2024-01-01, Moon distance, Jupiter distance, finite ship trajectory, SolarView smoke.

## Files
- `game/data/solar/catalog.json` — bodies + moons
- `game/scripts/solar/ephemeris.gd` — Kepler + propagate
- `game/scripts/ui/solar_view.gd` — SubViewport scene
- `game/shaders/solar/body.gdshader`, `ring.gdshader`
- `game/tools/fetch_solar_assets.sh`, `build_moon_catalog.py`
