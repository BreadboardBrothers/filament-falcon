# Real-size Earth, Moon, area packs and OSM detail regions

The universe is real size: a 6,371 km Earth (real GM), a 1,737 km Moon at 384,400 km. All missions,
orbits and the robot flight tests are tuned to it (launch to a 200 × 150 km orbit at about 7.6 km/s,
station and crew orbits at 300–420 km, reentry and splashdown targets placed along the real ground track).

## How the big world renders without jitter

- **Floating origin, doubles everywhere.** The simulation keeps positions as `BigVec` (double precision). Every frame the ship is the origin and every body or entity is placed relative to it (`rel_d`), so nothing on screen is ever far from 0.
- **Planet LOD** (`scripts/world/planet_lod.gd`): a chunked cube-sphere quadtree (6 faces, tan-warped, 32×32 cells per chunk, skirts hide cracks). A chunk splits when the camera is closer than 2× its edge; chunks beyond the horizon are culled. Earth goes to level 15 (~2.4 m cells; 14 at the lowest quality), the Moon to 13. Chunk vertices are built on worker threads (`EarthTerrain.sample`, the same function the physics uses), the meshes are created on the main thread (≤ 12 a frame), and an LRU keeps 1,400.
- **Scaled space far away.** The camera far plane is 1,000 km. When a planet would not fit, it is drawn uniformly scaled toward the camera (`world.scaled_factor`), so it looks the same but sits inside the depth range. Godot's reverse-Z depth gives enough precision near the ground, so no log depth is needed. Surface objects (pads, runway, fields) only show while their planet is drawn at true size.
- **Shaders** get the camera position in planet space in km (air maths) and modulo 4 km (wave phase), so they never see huge numbers.
- **Debug slew** (mission paused, Ctrl+F) goes up to 1,000 km/s (0.1 m/s … 1e6 m/s, +/−), so you can cross the planet or fly to the Moon. Time warp goes up to ×10,000 (the step size adapts to the orbit).

## Ground data, best first (`scripts/geo/earth_terrain.gd`)

1. **A built OSM detail region** under the camera (3D buildings, roads, trees, water) — `tools/build_region.py`, normally run by the area manager.
2. **Area packs** from the area manager: ~20 m DEM, water mask and Sentinel-2 imagery for a box anywhere on Earth.
3. **The global set** from `tools/fetch_assets.sh`: GEBCO heights (~10 km), the land/water mask (~5 km) and Blue Marble imagery, plus noise detail.
4. Nothing installed: gentle noise hills (tests, offline).

Packs and regions blend into the next source over their last 0.5–1 km. The pad and the runway are flattened at their real 3 m elevation. What you see is what you land on: physics and the meshes use the same height function.

## Area manager

Pick areas, see what they cost, pre-download and pre-generate them **on this PC**. Everything goes under `~/.local/share/filament-falcon/`.

### Commander → AREAS page

- **Pick an area:** a preset (Fredericton and the other NB cities, KSC, Cocoa Beach, Halifax, Fundy), **LAT / LON + RADIUS km → SET**, or the map: mouse wheel zooms at the cursor, right-drag pans, left-drag draws a box, a click makes a 10 × 10 km box.
- The selection shows its size and an estimate: DEM and imagery tiles (how many are still to download, MB), which Geofabrik extract it needs (cached or MB to download) and the 3D region size.
- Tick the steps (DEM, IMAGERY, OSM EXTRACT, 3D BUILD) and press **QUEUE DOWNLOAD + GENERATE**. Jobs run one at a time in a background runner on this PC and keep going if the game quits.
- **The job runner line** (top of CACHED AREAS) says what the background runner is doing: **RUNNER RUNNING** with the job, step, progress, MB downloaded and how long ago it last reported, or **RUNNER NOT RUNNING** / **RUNNER FAILED TO START** with the reason and the log lines. When jobs are queued and no runner is running, the page starts one by itself. It retries every 8 s, or every 30 s after a failed start. Other Commander pages check every 60 s. **RUN / RETRY NOW** starts it by hand. Missing Python modules (numpy, Pillow, pyosmium) are listed in red. The last lines of `areas/runner.log` are shown at the bottom.
- **CACHED AREAS** lists every area with its state (queued / running + step / stalled / done / error / cancelled), progress, MB downloaded, disk use, `pack ✓` and `3D v3`. It has **VIEW** (frame it on the map), **CANCEL**, **REBUILD** and **DELETE** (click twice). Areas are drawn on the map in their state colour.
- **Map layer (roads, rivers, lakes, names):** once an OSM extract is on this PC, the map draws lakes, rivers and roads and labels places. Major roads (motorway / trunk) and the big rivers and lakes show from the world zoom; primary, secondary, then tertiary roads, smaller rivers and lakes appear as you zoom in. Names go city → town → village → hamlet as you zoom in, without overlaps. Without a layer the map works as before and shows **BUILD MAP LAYER** (top right), which runs `tools/map_layer.py` in the background (log: `areas/map_layer.log`); the map picks the result up by itself within a few seconds. The AREAS runner also refreshes the layer after every OSM step.
- When a job finishes, the terrain reloads by itself (**RELOAD TERRAIN** does it by hand). The planet picks up the new pack at once. A built region loads automatically when you fly within 30 km of it below 60 km altitude (`--region=NAME` / `--region-dir=DIR` pins one).

### CLI: `game/tools/area_manager.py`

```
python3 tools/area_manager.py presets
python3 tools/area_manager.py estimate fredericton                 # or --bbox=S,W,N,E / --center LAT,LON --radius KM
python3 tools/area_manager.py add fredericton --run                # queue all steps + start the runner
python3 tools/area_manager.py add --id home --center 45.96,-66.64 --radius 5 --steps dem,imagery --run
python3 tools/area_manager.py add --id cape --bbox=28.40,-80.78,28.66,-80.52 --run
python3 tools/area_manager.py add --id nb --bbox=45.0,-68.0,48.0,-64.0 --fit split --run   # > 120 km: tiles
python3 tools/area_manager.py status [--json]
python3 tools/area_manager.py run --wait                           # work the queue in this terminal
python3 tools/area_manager.py cancel home
python3 tools/area_manager.py delete home [--purge-tiles]
python3 tools/area_manager.py maplayer                             # AREAS map roads / rivers / names (background)
```

Use `--bbox=` with an `=` when the latitude is negative.

- **Size:** an area can be at most 120 km on a side. Bigger boxes are refused with the size and the tile count, unless you add `--fit clamp` (a 120 km box around the centre) or `--fit split` (a grid of ≤ 120 km areas `<id>_r<row>c<col>`, at most 64). The AREAS page has the same choice (OVER 120 km: CLAMP / SPLIT INTO TILES).
- **Ids:** any id in the registry works on the CLI, including ones the map made (`area_45_964_-66_643`; dots and other characters are normalised the same way by the game and the CLI).
- **`status`** explains every job that is not moving, for example "waiting: the background runner is NOT running", "waiting behind 'fundy' (#2 in the queue)", "blocked: missing python module(s): numpy (sudo apt install python3-numpy)" or "stalled: the runner stopped mid-job". It also prints the runner's job, step and MB downloaded, the dependencies and the last lines of `runner.log`.
- **`run`** starts the background runner detached (`run --wait`, logging to `areas/runner.log`), then checks for up to 4 s that it really started. If the runner dies at once, `run` prints the error and the log lines and exits with code 1. `--json` gives the same result for the game. Jobs that failed only because a module was missing are queued again once that module is installed.
- **Delete** is idempotent: deleting an area that is already gone prints "already deleted" and succeeds, queued jobs for it are dropped, and deleting a running area cancels it and removes it once the runner stops.

### Steps

| step | source | output |
|---|---|---|
| dem | AWS Terrain Tiles (terrarium z13, ~20 m) | `areas/<id>/dem.bin` (int16, 0.5 m, lat/lon grid, north row first) |
| imagery | EOX Sentinel-2 cloudless 2020 (z ≤ 13, ~10–20 m) | `areas/<id>/image.jpg` (lat/lon-linear) |
| osm | the **smallest Geofabrik regional extract** containing the area (from `index-v1.json`; never the planet file). An area across a border uses the provincial or state extracts that cover its land, not the whole country: a box over the middle of the Bay of Fundy uses New Brunswick + Nova Scotia (the Fundy NP preset is all New Brunswick), KSC and Cocoa Beach use Florida, Starbase TX uses Texas, and Halifax uses Nova Scotia. A copy already in `osm/` is reused if it is less than 30 days old. That includes the New Brunswick file `tools/fetch_assets.sh` leaves without a `.meta.json`. After 30 days it is re-checked with If-Modified-Since. | `osm/<region>-latest.osm.pbf`, shared, re-checked monthly |
| build | `build_region.py` on that extract (`--pbf-url` once per extract) | `assets/regions/<id>/` (3D detail) + the water mask `areas/<id>/water.bin` |

After the DEM step the pack is already usable; imagery and water refine it. Without the OSM build, the water mask is the sea (DEM ≤ 0).

### Files (`~/.local/share/filament-falcon/`)

- `areas/<id>/area.json, status.json, dem.bin, water.bin, image.jpg, build.log`: the pack and the job state. Also `areas/queue/` (a job's file is removed only after the job ends, so a killed runner loses nothing), `areas/runner.lock` (held with `flock` by the live runner; the kernel releases it when the runner dies, so it can never go stale), `areas/runner.pid`, `areas/runner.json` (current job, step, bytes and a heartbeat) and `areas/runner.log`. When a runner starts, jobs left "running" by a dead runner go back to the front of the queue.

### Downloads never move ("QUEUED 0%", runner idle)

Before this fix, the background runner added in 48fd6eb never started. `area_manager.py run`, which is what the game and `add --run` launched, started another `run` instead of `run --wait`. That one did the same, so short-lived processes kept handing over to each other and none of them worked the queue. Update the repo (`git pull`), then either open Commander → AREAS (the runner starts by itself) or run it in a terminal:

```
pkill -f "area_manager.py run"            # stop any leftover hand-over processes from the old version
cd ~/filament-falcon/game                  # wherever the repo is
python3 tools/area_manager.py status      # why each job is waiting, deps, runner log
python3 tools/area_manager.py run --wait  # work the queue in this terminal (Ctrl+C stops; the job resumes next time)
```

The progress is in `~/.local/share/filament-falcon/areas/runner.log` (`tail -f` it).
- `dem/terrarium/13/`, `imagery/s2cloudless/<z>/`: tile caches shared by all areas.
- `osm/*.osm.pbf` (+ `.meta.json`), `osm/geofabrik-index.json`, `osm/extract_<id>_<key>.json.gz`.
- `assets/regions/<id>/`: `manifest.json` (v3), `c_<ix>_<iz>.json` chunks and `dem.bin` (ground / water-surface heights for the physics).
- `assets/`: the NASA textures (`*_hd.*`, `earth_normal.png`, `earth_mask.png` + `.ver`). `cache/`: GPU-compressed textures and raw terrain caches.

**Licences:** the imagery is "Sentinel-2 cloudless – https://s2maps.eu by EOX IT Services GmbH (Contains modified Copernicus Sentinel data 2020)", CC BY-NC-SA 4.0, so it is for personal, non-commercial use only. Map data © OpenStreetMap contributors (ODbL), extracts by Geofabrik. Elevation: AWS Terrain Tiles (Mapzen; SRTM, GMTED, NED and others).

## Water (why it used to be green, and what draws it now)

**Region build (v3).**
- Lakes and riverbanks keep their multipolygon inner rings, so islands are dry and lakes inside forests are not forest.
- River and canal centre-lines are rasterised at their width. The sea is wherever the DEM is ≤ 0 m (a missing DEM tile counts as 0.5 m, never sea).
- Every water vertex gets a surface level. A lake takes one flat level from its shore DEM. A river takes the local shore level, so it can slope.
- The bed is carved 1.5 m under that level and the banks next to it are raised just above it.

**In game.**
- A flat water mesh per chunk at that level uses `shaders/water.gdshader`: a deep blue body, a Fresnel reflection of the sky colour (blue by day, dark at night), a sharp sun glint and small wind waves.
- The planet LOD mesh sits 2.5 m under the region so they don't fight.

**From altitude and orbit.**
- The planet shader forces water albedo to deep blue, with Fresnel, glint and waves.
- The LOD mesh carries per-vertex water from the packs or the mask.
- The global mask is v2, so lakes above sea level and turquoise shallows count as water (re-run `tools/fetch_assets.sh` to re-bake it).

**Rebuild needed.** Regions built before v3 are ignored with a warning: rebuild them (AREAS → REBUILD, `area_manager.py add <id> --run`, or `tools/fetch_assets.sh`).

## Other procgen fixes in this round

- DEM sampling was half a pixel off.
- Building bases now sit at their lowest corner instead of the centroid, so they no longer float on slopes. The roof ridge now runs along the longest wall.
- Roads and rails follow the ground every 15 m instead of only at their OSM nodes.
- Trees are no longer placed on water (forest holes and lakes are respected).
- The region frame now uses true east/north at the region centre with the builder's exact projection; it was about 0.6% off and rotated.
- Region height lookups are thread-safe (the LOD workers call them).

## Nav map globe and GROUND close-up

The console's NAV map ("WHERE ARE WE?") and the Commander's ORBIT MAP (`scripts/ui/nav_map.gd`) draw the planet as a lit globe instead of a flat disc. The globe uses the textures the 3D world already has loaded, so it adds no second copy in memory and switches to the HD set when it streams in:

- **Earth:** Blue Marble day colour, a real terminator from the sun direction, an orange twilight band, Black Marble city lights on the night side, clouds, an ocean sun glint (from `earth_mask.png` when the HD set is present), limb haze and an atmosphere glow ring.
- **Moon:** LROC colour, LOLA relief shading and Lommel-Seeliger lighting (the flat-looking full Moon).
- **Other bodies** are drawn as small lit globes, so the Moon's phase shows even when it is clamped to the map edge.
- **Ground sites on the globe's visible hemisphere:** the home region (Fredericton, or `--region`, in pink), the pad and every area the area manager knows. Area boxes are green when the area is ready and amber while it downloads.
- **GROUND close-up:** when the ship is below 0.35 body radii or on the ground, a north-up close-up appears in the bottom right. It shows the ground under the ship (±25 km on the ground, growing with altitude up to ±0.3 R), the projected ground track (the game Earth does not spin, so the track is the orbit itself), the ship's heading, area boxes and names, the home region, the pad and a lat/lon readout. Over an area, it adds the area's Sentinel-2 imagery (when the world has it loaded nearby) and the **OSM overlay**: water and coast, built-up areas, buildings, parks, rivers, rail, roads (which glow at night) and town names.
- **Cost:** each picture is a 2D `SubViewport` (`scripts/ui/nav_globe.gd`, `shaders/nav_globe.gdshader`, `shaders/nav_ground.gdshader`). The globe is at most 640 px, the other bodies up to 256 px and the close-up up to 384 px. They render with `UPDATE_ONCE` only when the picture changes, at most 4 Hz (and every 5 s for the sun), and the map rescales the last picture in between. With no assets downloaded, the shaders draw a procedural Earth and Moon.

**OSM overlay (`tools/nav_overlay.py`, runs on the game PC):** it rasterizes each built region's cached extract (`osm/extract_<id>_*.json.gz`) into `assets/overlays/<id>.png`, an RGBA image over the region box with at most 2048 px on its longest side. It adds the area pack's `water.bin` sea and coastline when there is one. It writes `assets/overlays/<id>.json`, which holds the bbox and the place=city/town/village/suburb names read from the cached `.osm.pbf` with pyosmium; osmium-tool cuts the box first when it is installed. The script takes seconds and skips overlays that are up to date. `tools/fetch_assets.sh` runs it after the region build, the AREAS builder runs it at the end of each area's build step, and deleting an area removes its overlay. To redo them all, run `python3 tools/nav_overlay.py --force`.

## AREAS map layer (`tools/map_layer.py`, runs on the game PC)

`python3 tools/map_layer.py [--pbf FILE ...] [--force]` reads every cached Geofabrik extract (`osm/*.osm.pbf`) with pyosmium (osmium-tool pre-filters the tags first when installed, much faster) and writes `maps/<extract>.ffml`, a compact binary layer (a few MB for a province; up-to-date files are skipped):

| layer | zoom tiers (0 = visible from far out) |
|---|---|
| roads | motorway / trunk 0, primary 1, secondary 2, tertiary 3 (no streets) |
| rivers | named length > 80 km 0, > 20 km 1, other rivers / canals 2 |
| lakes | > 100 km² 0, > 10 km² 1, > 1 km² 2, > 0.05 km² 3 (outer rings) |
| places | city, town, village, hamlet / suburb with population |

Each line is stored at up to three Douglas-Peucker levels (0.006°, 0.001°, 0.0001°), only those its tier can be seen at. The game (`scripts/ui/map_layer.gd`) loads the files lazily on a worker thread the first time the AREAS map is drawn, merges the segments into cached buckets per kind, tier, detail level and map cell (lakes as one triangle mesh per bucket), and per frame draws only the buckets in view at the current detail level: one `draw_multiline` / `draw_mesh` per bucket. Labels are capped at 160 and rejected when they overlap. It is run by `tools/fetch_assets.sh`, the AREAS runner (after the OSM step; it never fails a job) and BUILD MAP LAYER (`area_manager.py maplayer`).

## Packages and tests

- **Packages:** `sudo apt install curl python3-numpy python3-pil python3-pip osmium-tool; then: pip install --user --break-system-packages osmium`.
- **Tests:**
  - `godot --headless --path game -- --region-test --region-dir=DIR` (sync and threaded build);
  - `XDG_DATA_HOME=/tmp/x godot --headless --path game -- --asset-test` (shader compile and texture cache);
  - `-- --flight-test` (all missions on the real-size planet).
  - `XDG_DATA_HOME=$(mktemp -d) godot --headless --path game -- --nav-map-test` (nav globe, ground close-up, area and overlay scan, procedural fallback).
  - `XDG_DATA_HOME=$(mktemp -d) godot --headless --path game -- --map-layer-test` (AREAS map layer: fallback button, background load, tiers and names by zoom, culling).
  - `python3 tools/test_map_layer.py` (map_layer.py on a tiny generated .osm.pbf; needs pyosmium).
  - A tiny offline region: `python3 tools/build_region.py --name t --bbox=… --osm file.json --flat-dem --out DIR`.

## Still approximate

- KSC is rotated to sit under the game's pad. The procedural pad and runway may not match the imagery exactly.
- Roofs are simple gabled or hipped. Building heights use Atlantic Canada defaults when OSM has no tags. Bridges are flat.
- Pack imagery only covers areas you have generated. Elsewhere it is Blue Marble (~500 m per pixel at 16k).
- LOD performance and seams have only been checked headless (no GPU profiling yet).


The **Starbase TX** area preset (`game/tools/area_presets.json`, id `starbase`) covers Boca Chica, the pads, Highway 4 and the nearby Gulf beach. Build it on the game PC with Commander → AREAS or `python3 game/tools/area_manager.py add starbase --run`. Flight 15 uses this pack when present; it is not downloaded automatically by the agent or by headless tests.
