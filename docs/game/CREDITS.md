# Credits: The Filament Falcon game

- **Engine:** [Godot Engine](https://godotengine.org) 4.7 (MIT). It is not bundled in this repo.
- **Art:** none downloaded. The planet, clouds, city lights, Moon, terrain, star field, Milky Way, ship,
  station, asteroids and runway are all generated procedurally at run time from code and shaders in `game/`.
- **Audio:** none downloaded. Engine rumble, RCS puffs, alarms, clunks, the laser and tones are synthesized in
  `game/scripts/autoload/sfx.gd`.
- **Voice:** uses the player's system `espeak-ng` (GPL-3.0) or a user-installed piper voice at run time. Nothing is bundled.
- **Font:** Godot's built-in default font.

Total size of third-party assets in the repo: **0 bytes**.

## Solar textures & ephemerides
- Planetary maps: [Solar System Scope](https://www.solarsystemscope.com/textures/) (CC BY 4.0); NASA / USGS / JPL public-domain maps may replace them in `assets/solar/`.
- Planet elements: [JPL Approximate Positions of the Planets](https://ssd.jpl.nasa.gov/planets/approx_pos.html).
- Moon elements: JPL SSD satellite mean elements (`ssd.jpl.nasa.gov`), with schematic placeholders for tiny irregulars until refreshed by `tools/build_moon_catalog.py`.
