#!/usr/bin/env bash
# Download NASA / USGS / Solar System Scope style planetary maps into
# ~/.local/share/filament-falcon/assets/solar/ for the Commander SOLAR page.
# Safe to re-run (skips files that already exist). Run on the game PC (large downloads).
# Sources and licences are printed and written to SOURCES.txt.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
DATA="${XDG_DATA_HOME:-$HOME/.local/share}/filament-falcon"
OUT="$DATA/assets/solar"
mkdir -p "$OUT"
log() { printf '[solar] %s\n' "$*"; }

# Download only if the response is a real image (never keep an HTML landing page as .jpg).
fetch_image() {
  local url="$1" dest="$2"
  local tmp="$dest.part"
  local hdr
  hdr=$(mktemp)
  if ! curl -fL --connect-timeout 20 --max-time 180 -A "Mozilla/5.0 FilamentFalconSolar/1.0" \
      -D "$hdr" -o "$tmp" "$url"; then
    rm -f "$tmp" "$hdr"
    return 1
  fi
  local ctype
  ctype=$(tr -d '\r' < "$hdr" | awk 'tolower($1)=="content-type:" {print tolower($2); exit}')
  rm -f "$hdr"
  case "$ctype" in
    image/jpeg*|image/jpg*|image/png*|image/webp*|image/tiff*|image/*) ;;
    *)
      # Some CDNs omit/lie; fall through to magic-byte check.
      ;;
  esac
  # Magic bytes: JPEG / PNG / WEBP / TIFF
  local mag
  mag=$(od -An -tx1 -N 12 "$tmp" 2>/dev/null | tr -d ' \n')
  case "$mag" in
    ffd8ff*|89504e47*|52494646*|49492a00*|4d4d002a*) ;;
    *)
      log "! not an image (ctype=${ctype:-?} magic=${mag:0:16}…) — skipped $dest"
      rm -f "$tmp"
      return 1
      ;;
  esac
  # Reject tiny stubs / error bodies
  local sz
  sz=$(wc -c < "$tmp" | tr -d ' ')
  if [[ "${sz:-0}" -lt 2048 ]]; then
    log "! too small (${sz} B) — skipped $dest"
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$dest"
  return 0
}


# Public domain / NASA imagery mirrors (URLs may move; failures are skipped with a note).
# Prefer maps already redistributed for educational use. See SOURCES.txt.
declare -a ITEMS=(
  # id|filename|url|credit
  "sun|sun_map.jpg|https://www.solarsystemscope.com/textures/download/2k_sun.jpg|Solar System Scope (CC BY 4.0)"
  "mercury|mercury_map.jpg|https://www.solarsystemscope.com/textures/download/2k_mercury.jpg|Solar System Scope (CC BY 4.0)"
  "venus|venus_map.jpg|https://www.solarsystemscope.com/textures/download/2k_venus_atmosphere.jpg|Solar System Scope (CC BY 4.0)"
  "earth|earth_map.jpg|https://www.solarsystemscope.com/textures/download/2k_earth_daymap.jpg|Solar System Scope (CC BY 4.0)"
  "earth_night|earth_night.jpg|https://www.solarsystemscope.com/textures/download/2k_earth_nightmap.jpg|Solar System Scope (CC BY 4.0)"
  "earth_clouds|earth_clouds.jpg|https://www.solarsystemscope.com/textures/download/2k_earth_clouds.jpg|Solar System Scope (CC BY 4.0)"
  "moon|moon_map.jpg|https://www.solarsystemscope.com/textures/download/2k_moon.jpg|Solar System Scope (CC BY 4.0)"
  "mars|mars_map.jpg|https://www.solarsystemscope.com/textures/download/2k_mars.jpg|Solar System Scope (CC BY 4.0)"
  "jupiter|jupiter_map.jpg|https://www.solarsystemscope.com/textures/download/2k_jupiter.jpg|Solar System Scope (CC BY 4.0)"
  "saturn|saturn_map.jpg|https://www.solarsystemscope.com/textures/download/2k_saturn.jpg|Solar System Scope (CC BY 4.0)"
  "uranus|uranus_map.jpg|https://www.solarsystemscope.com/textures/download/2k_uranus.jpg|Solar System Scope (CC BY 4.0)"
  "neptune|neptune_map.jpg|https://www.solarsystemscope.com/textures/download/2k_neptune.jpg|Solar System Scope (CC BY 4.0)"
  "io|io_map.jpg|https://assets.science.nasa.gov/content/dam/science/cds/3d/resources/image/jupiter---io-(a)/Jupiter%20-%20Io%20(A).jpg|NASA Science / USGS Voyager mosaic (Jupiter - Io (A); page https://science.nasa.gov/3d-resources/jupiter-io-a/)"
  "milkyway|stars_milky_way.jpg|https://www.solarsystemscope.com/textures/download/2k_stars_milky_way.jpg|Solar System Scope milky way / star field (CC BY 4.0)"
)

{
  echo "Filament Falcon solar textures"
  echo "Downloaded: $(date -u +%Y-%m-%dT%H:%MZ)"
  echo
  echo "Primary pack: Solar System Scope 2K maps — https://www.solarsystemscope.com/textures/"
  echo "Licence: CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/)."
  echo "NASA / USGS / JPL public-domain maps may be dropped into this folder using the same filenames"
  echo "(earth_map.jpg, mars_map.jpg, moon_map.jpg, …). Normal maps: mercury_normal.jpg, mars_normal.jpg, moon_normal.jpg."
  echo
} > "$OUT/SOURCES.txt"

ok=0; miss=0
for item in "${ITEMS[@]}"; do
  IFS='|' read -r id file url credit <<<"$item"
  dest="$OUT/$file"
  if [[ -f "$dest" && -s "$dest" ]]; then
    log "have $file"
    ok=$((ok+1))
    continue
  fi
  log "get $file"
  if fetch_image "$url" "$dest"; then
    echo "$file  $credit  $url" >> "$OUT/SOURCES.txt"
    ok=$((ok+1))
  else
    log "! failed $file — place a map at $dest by hand"
    echo "MISSING $file  ($credit)  $url" >> "$OUT/SOURCES.txt"
    miss=$((miss+1))
  fi
done


# Sky / galaxy textures (optional; SOLAR falls back to colored billboards + bundled star catalog)
SKY_OUT="$OUT/sky"
mkdir -p "$SKY_OUT"
declare -a SKY_ITEMS=(
  "m31|m31.jpg|https://upload.wikimedia.org/wikipedia/commons/thumb/9/98/Andromeda_Galaxy_%28with_h-alpha%29.jpg/1280px-Andromeda_Galaxy_%28with_h-alpha%29.jpg|Wikimedia Commons — Andromeda (credit on page)"
  "m33|m33.jpg|https://upload.wikimedia.org/wikipedia/commons/thumb/6/64/Triangulum_Galaxy.jpg/1024px-Triangulum_Galaxy.jpg|Wikimedia Commons — Triangulum"
  "lmc|lmc.jpg|https://upload.wikimedia.org/wikipedia/commons/thumb/4/49/LMC_Heic1311a.jpg/1280px-LMC_Heic1311a.jpg|ESA/Hubble — Large Magellanic Cloud"
  "smc|smc.jpg|https://upload.wikimedia.org/wikipedia/commons/thumb/6/67/The_Small_Magellanic_Cloud.jpg/1280px-The_Small_Magellanic_Cloud.jpg|ESO — Small Magellanic Cloud"
)
{
  echo
  echo "Sky textures (Milky Way + nearby galaxies)"
  echo "Milky Way panorama: Solar System Scope CC BY 4.0"
  echo "Galaxy stills: see per-file credits (ESA/Hubble/ESO/Wikimedia). Prefer NASA/ESA originals when replacing."
  echo "Bundled lightweight catalogs (no download needed): game/data/solar/sky_stars.json, sky_galaxies.json"
  echo
} >> "$OUT/SOURCES.txt"
for item in "${SKY_ITEMS[@]}"; do
  IFS='|' read -r id file url credit <<<"$item"
  dest="$SKY_OUT/$file"
  if [[ -f "$dest" && -s "$dest" ]]; then
    log "have sky/$file"
    ok=$((ok+1))
    continue
  fi
  log "get sky/$file"
  if fetch_image "$url" "$dest"; then
    echo "sky/$file  $credit  $url" >> "$OUT/SOURCES.txt"
    ok=$((ok+1))
  else
    log "! failed sky/$file — colored billboard fallback"
    echo "MISSING sky/$file  ($credit)  $url" >> "$OUT/SOURCES.txt"
    miss=$((miss+1))
  fi
done

# Optional: refresh full moon catalog from JPL SSD HTML tables (ssd.jpl.nasa.gov/sats/elem/)
if command -v python3 >/dev/null; then
  python3 "$HERE/build_moon_catalog.py" --out "$DATA/assets/solar/moons_full.json"     || log "moon catalog refresh skipped (bundled catalog kept)"
fi

log "done: $ok ok, $miss missing → $OUT"
du -sh "$OUT" 2>/dev/null || true
