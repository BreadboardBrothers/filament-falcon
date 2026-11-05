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
  "io|io_map.jpg|https://astrogeology.usgs.gov/search/map/Io/Voyager/Io_Voyager_global_mosaic_512|USGS (placeholder URL — see SOURCES)"
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
  if curl -fL --connect-timeout 20 --max-time 180 -o "$dest.part" "$url"; then
    mv "$dest.part" "$dest"
    echo "$file  $credit  $url" >> "$OUT/SOURCES.txt"
    ok=$((ok+1))
  else
    rm -f "$dest.part"
    log "! failed $file — place a map at $dest by hand"
    echo "MISSING $file  ($credit)  $url" >> "$OUT/SOURCES.txt"
    miss=$((miss+1))
  fi
done

# Optional: refresh full moon catalog from JPL when network allows
if command -v python3 >/dev/null; then
  python3 "$HERE/build_moon_catalog.py" --out "$DATA/assets/solar/moons_full.json" || log "moon catalog refresh skipped"
fi

log "done: $ok ok, $miss missing → $OUT"
du -sh "$OUT" 2>/dev/null || true
