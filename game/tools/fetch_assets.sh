#!/usr/bin/env bash
# Download real Earth/Moon textures + build the Fredericton OSM detail region into
# ~/.local/share/filament-falcon/assets (outside the repo). Safe to re-run: finished files
# are skipped, partial ones resume, each file has fallback URLs (next one on 404 / timeout).
# Offline / failures: the game falls back to its procedural planet and Moon.
# Usage (from anywhere: repo root, game/ or game/tools/):
#   tools/fetch_assets.sh [--months=all|7] [--hd-months=7|all] [--no-hd] [--region=NAME] [--bbox=S,W,N,E] [--no-region]
# HD Earth (default on, ~80 MB once): 21600 px Blue Marble -> 16k, 8k clouds + night, GEBCO DEM
# -> 8k normal map + land mask. The game block-compresses them on first use and caches the
# result in ~/.local/share/filament-falcon/cache/tex (fast loads afterwards).
# Needs curl; python3-numpy + python3-pil for the TIF/GEBCO conversion; pyosmium (pip install osmium) for the city.
GAME_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)" || { echo "fetch_assets: cannot find the game folder" >&2; exit 1; }
cd "$GAME_DIR" || exit 1
A="${XDG_DATA_HOME:-$HOME/.local/share}/filament-falcon/assets"
mkdir -p "$A" || { echo "fetch_assets: cannot create $A" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "fetch_assets: curl is missing (sudo apt install curl)" >&2; exit 1; }
HAVE_PY=1
python3 -c "import numpy, PIL" 2>/dev/null || { HAVE_PY=0; echo "note: python3-numpy / python3-pil missing: Moon + elevation conversion, HD Earth and the OSM region are skipped (sudo apt install python3-numpy python3-pil python3-pip osmium-tool; then: pip install --user --break-system-packages osmium)"; }
MONTHS=all; HD_MONTHS=7; DO_HD=1; REGION=fredericton; BBOX=""; DO_REGION=1
for a in "$@"; do case "$a" in
  --months=*) MONTHS="${a#*=}" ;; --region=*) REGION="${a#*=}" ;;
  --hd-months=*) HD_MONTHS="${a#*=}" ;; --no-hd) DO_HD=0 ;;
  --bbox=*) BBOX="${a#*=}" ;; --no-region) DO_REGION=0 ;;
  -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
  *) echo "fetch_assets: unknown option $a (see --help)" >&2; exit 2 ;; esac; done
N=https://eoimages.gsfc.nasa.gov/images/imagerecords
S=https://svs.gsfc.nasa.gov/vis/a000000/a004700/a004720     # NASA SVS CGI Moon Kit (svs.gsfc.nasa.gov/4720)
BM=https://assets.science.nasa.gov/content/dam/science/esd/eo/images/bmng/bmng-topography-bathymetry   # NASA Blue Marble NG (topo+bathy)
MN=(january february march april may june july august september october november december)
FAIL=0
get() {  # dest url [fallback urls...]: first URL that works wins (all public domain NASA data)
  local dest="$1"; shift
  [ -s "$A/$dest" ] && return 0
  echo "  $dest"
  for u in "$@"; do
    if curl -fL --retry 2 --connect-timeout 20 -C - --progress-bar -o "$A/$dest.part" "$u" || \
       { rm -f "$A/$dest.part"; curl -fL --retry 1 --connect-timeout 20 --progress-bar -o "$A/$dest.part" "$u"; }; then
      mv "$A/$dest.part" "$A/$dest"; return 0
    fi
    rm -f "$A/$dest.part"
    echo "  ! $u failed, trying the next source..."
  done
  echo "  ! $dest: no source worked (re-run later)"; FAIL=1; return 1
}
echo "Fetching Earth/Moon textures into $A (~60 MB + ~80 MB HD, first run only)..."
IDS=(73580 73605 73630 73655 73701 73726 74092 74117 74142 74167 74192 74218)
for m in $(seq 1 12); do
  [ "$MONTHS" != all ] && [ "$m" != "$MONTHS" ] && continue
  id=${IDS[$((m-1))]}; mm=$(printf %02d "$m")
  get "earth_day_$mm.jpg" "$BM/${MN[$((m-1))]}/world.topo.bathy.2004$mm.3x5400x2700.jpg" "$N/$((id/1000*1000))/$id/world.topo.bathy.2004$mm.3x5400x2700.jpg" "$N/$((id/1000*1000))/$id/world.2004$mm.3x5400x2700.jpg"
done
get earth_night.jpg "$N/144000/144898/BlackMarble_2016_3km.jpg"
get earth_clouds.jpg "$N/57000/57747/cloud_combined_2048.jpg"
[ "$HAVE_PY" = 1 ] && get gebco_raw.png "$N/73000/73934/gebco_08_rev_elev_21600x10800.png"
if [ "$DO_HD" = 1 ] && [ "$HAVE_PY" = 1 ]; then
  mkdir -p "$A/src"
  for m in $(seq 1 12); do
    [ "$HD_MONTHS" != all ] && [ "$m" != "$HD_MONTHS" ] && continue
    id=${IDS[$((m-1))]}; mm=$(printf %02d "$m"); base="$N/$((id/1000*1000))/$id"
    [ -s "$A/earth_day_${mm}_hd.jpg" ] || get "src/earth_day_${mm}_21600.jpg" "$BM/${MN[$((m-1))]}/world.topo.bathy.2004$mm.3x21600x10800.jpg" "$base/world.topo.bathy.2004$mm.3x21600x10800.jpg" "$base/world.2004$mm.3x21600x10800.jpg"
  done
  [ -s "$A/earth_clouds_hd.png" ] || get src/cloud_combined_8192.tif "$N/57000/57747/cloud_combined_8192.tif"
fi
# Moon: LROC colour (13 MB 4k TIF -> 3.3 MB 2k TIF -> 0.5 MB 2k JPG -> 1k JPG) and LOLA
# heights (2 MB uint16 TIF -> 4 MB float TIF -> 0.1 MB 8-bit JPG). The JPGs need no Pillow.
if [ ! -s "$A/moon_color.jpg" ]; then
  if [ "$HAVE_PY" = 1 ]; then
    get moon_color_src "$S/lroc_color_poles_4k.tif" "$S/lroc_color_poles_2k.tif" "$S/lroc_color_2k.jpg" "$S/lroc_color_poles_1k.jpg"
  else
    get moon_color.jpg "$S/lroc_color_2k.jpg" "$S/lroc_color_poles_1k.jpg"
  fi
fi
if [ "$HAVE_PY" = 1 ] && [ ! -s "$A/moon_height.png" ]; then
  get moon_ldem_src "$S/ldem_4_uint.tif" "$S/ldem_4.tif" "$S/ldem_3_8bit.jpg"
fi
curl -fsm 15 "https://celestrak.org/NORAD/elements/gp.php?CATNR=25544&FORMAT=TLE" -o "$A/iss.tle.part" && \
  grep -q "^2 25544" "$A/iss.tle.part" && mv "$A/iss.tle.part" "$A/iss.tle" && echo "  iss.tle (REAL ISS mission)"
rm -f "$A/iss.tle.part"
if [ "$HAVE_PY" = 1 ]; then
python3 - "$A" <<'P' || { echo "  ! conversion failed (see above)"; FAIL=1; }
import os, sys
from PIL import Image
import numpy as np
Image.MAX_IMAGE_PIXELS = None
A = sys.argv[1]
def conv(src, dst, fn):
    s, d = os.path.join(A, src), os.path.join(A, dst)
    if os.path.exists(s) and not os.path.exists(d):
        fn(Image.open(s)).save(d)
        print("  ->", dst)
def height16(im, size):
    # any height image (uint16 / float TIF, 8-bit JPG / PNG) -> normalised 16-bit PNG
    a = np.asarray(im.convert("F") if im.mode not in ("F", "I;16", "I") else im, dtype=np.float32)
    if a.ndim == 3:
        a = a.mean(axis=2)
    a = (a - a.min()) / max(float(a.max() - a.min()), 1e-6)
    a = np.asarray(Image.fromarray(a, "F").resize(size, Image.BILINEAR))
    return Image.fromarray((np.clip(a, 0, 1) * 65535).astype(np.uint16))
conv("gebco_raw.png", "earth_height.png", lambda im: im.convert("L").resize((4096, 2048), Image.BILINEAR))
# ---- HD Earth (16k day, 8k night / clouds, DEM normal map + land mask) ----
import glob, re
for src in sorted(glob.glob(os.path.join(A, "src", "earth_day_*_21600.jpg"))):
    mm = re.search(r"earth_day_(\d\d)_", src).group(1)
    conv(os.path.join("src", os.path.basename(src)), "earth_day_%s_hd.jpg" % mm, lambda im: im.convert("RGB").resize((16384, 8192), Image.LANCZOS))
    d = os.path.join(A, "earth_day_%s_hd.jpg" % mm)
    if os.path.exists(d):
        os.remove(src)          # the 16k copy is what the game uses
conv("earth_night.jpg", "earth_night_hd.jpg", lambda im: im.convert("RGB").resize((8192, 4096), Image.LANCZOS))
conv(os.path.join("src", "cloud_combined_8192.tif"), "earth_clouds_hd.png", lambda im: im.convert("L").resize((8192, 4096), Image.LANCZOS))
if os.path.exists(os.path.join(A, "earth_clouds_hd.png")) and os.path.exists(os.path.join(A, "src", "cloud_combined_8192.tif")):
    os.remove(os.path.join(A, "src", "cloud_combined_8192.tif"))
def bake_normal_mask():
    n_path, m_path, g = os.path.join(A, "earth_normal.png"), os.path.join(A, "earth_mask.png"), os.path.join(A, "gebco_raw.png")
    ver_p = m_path + ".ver"          # bump MASK_VER when the land/water rule changes (re-bakes the mask)
    MASK_VER = "2"
    mask_ok = os.path.exists(m_path) and os.path.exists(ver_p) and open(ver_p).read().strip() == MASK_VER
    if not os.path.exists(g) or (os.path.exists(n_path) and mask_ok):
        return
    W, H = 8192, 4096
    elev = np.asarray(Image.open(g).convert("L").resize((W, H), Image.BOX), dtype=np.float32) * (6400.0 / 255.0)   # metres
    # land/water mask (v2). v1 was "land = above sea level OR not ocean-blue", which made every lake
    # above sea level (Great Lakes, Lake Winnipeg, ...) and every turquoise shallow (Bahamas, reefs)
    # LAND, so the planet shader painted them green. Now: water = water-coloured in the day image
    # (dark blue, navy or turquoise: blue above red and close to / above green, not bright, so ice,
    # snow and cloud stay land) OR at / below sea level and not bright (open ocean, sea ice excluded).
    days = sorted(glob.glob(os.path.join(A, "earth_day_*_hd.jpg"))) or sorted(glob.glob(os.path.join(A, "earth_day_*.jpg")))
    water = (elev <= 0.5)
    if days:
        c = np.asarray(Image.open(days[0]).convert("RGB").resize((W, H), Image.BOX), dtype=np.float32) / 255.0
        r, gg, b = c[..., 0], c[..., 1], c[..., 2]
        bright = c.max(axis=2) > 0.6
        col = (b > r + 0.01) & (b >= gg * 0.85) & ~bright
        water = (water & ~bright) | col
    land = ~water
    m = Image.fromarray((land * 255).astype(np.uint8)).filter(__import__("PIL.ImageFilter", fromlist=["x"]).GaussianBlur(1.2))
    m.save(m_path)
    open(ver_p, "w").write(MASK_VER)
    print("  -> earth_mask.png (v%s)" % MASK_VER)
    if os.path.exists(n_path):
        return
    # normals in (east, north, up), relief exaggerated x6 so mountain ranges read from orbit
    R, k = 6371000.0, 6.0
    lat = (0.5 - (np.arange(H) + 0.5) / H) * np.pi
    dx = (2 * np.pi * R / W) * np.maximum(np.cos(lat), 0.05)[:, None]
    dy = np.pi * R / H
    gx = (np.roll(elev, -1, axis=1) - np.roll(elev, 1, axis=1)) / (2 * dx)
    gy = np.zeros_like(elev)
    gy[1:-1] = (elev[:-2] - elev[2:]) / (2 * dy)          # row 0 = north
    nx, ny, nz = -gx * k, -gy * k, np.ones_like(elev)
    ln = np.sqrt(nx * nx + ny * ny + nz * nz)
    rgb = np.stack([nx / ln, ny / ln, nz / ln], axis=2) * 0.5 + 0.5
    Image.fromarray((np.clip(rgb, 0, 1) * 255 + 0.5).astype(np.uint8), "RGB").save(n_path)
    print("  -> earth_normal.png")
bake_normal_mask()
conv("moon_color_src", "moon_color.jpg", lambda im: (lambda c: c.resize((min(c.width, 4096), min(c.width, 4096) // 2), Image.BILINEAR))(
    Image.fromarray((np.asarray(im, dtype=np.float32) / 257.0).astype(np.uint8)).convert("RGB") if im.mode.startswith("I;16") or im.mode == "RGB;16" else im.convert("RGB")))
conv("moon_ldem_src", "moon_height.png", lambda im: height16(im, (1440, 720)))
P
fi
if [ "$DO_REGION" = 1 ] && [ "$HAVE_PY" = 1 ]; then
  # OSM city from the Geofabrik New Brunswick .pbf (~65 MB once, re-checked after 30 days;
  # cached in ~/.local/share/filament-falcon/osm). Up-to-date regions are not rebuilt.
  python3 -c "import osmium" 2>/dev/null || echo "  note: pyosmium missing, using the slower Overpass API (sudo apt install osmium-tool; pip install --user --break-system-packages osmium)"
  echo "OSM detail region '$REGION'..."
  python3 tools/build_region.py --region "$REGION" ${BBOX:+--bbox "$BBOX"} || { echo "  ! region build failed"; FAIL=1; }
fi
if [ "$HAVE_PY" = 1 ]; then
  # nav map GROUND close-up overlays (roads / water / towns) from the cached region extracts:
  # seconds per region, up-to-date ones skipped
  python3 tools/nav_overlay.py || echo "  ! nav overlay failed (the nav map works without it)"
  # AREAS map roads / rivers / lakes / town names from every cached Geofabrik extract (needs pyosmium)
  python3 tools/map_layer.py || echo "  ! map layer skipped (pip install osmium; the AREAS map works without it)"
fi
# SOLAR page textures + optional moon-catalog refresh (large; skips existing files)
if [ -x tools/fetch_solar_assets.sh ]; then
  echo "SOLAR textures (Solar System Scope / NASA maps)..."
  tools/fetch_solar_assets.sh || echo "  ! solar assets skipped (re-run tools/fetch_solar_assets.sh on the game PC)"
fi
[ "$FAIL" = 0 ] && touch "$A/.fetched"
du -sh "$A" 2>/dev/null
echo "Done$( [ "$FAIL" = 1 ] && echo " (some items failed; re-run tools/fetch_assets.sh when online)")."
exit 0
