#!/usr/bin/env bash
# Launch The Filament Falcon. On a fresh clone, Godot must import the project once
# (builds the script class cache in .godot/) before the game can run.
# Before launching it maps the console touchscreen to the KIDS' CONSOLE monitor
# (tools/setup_displays.sh; skipped quietly when there is no touchscreen or xinput), then
# detaches it from the mouse pointer while the game runs (tools/touch_isolate.sh), so a tap on
# the kids' panel doesn't move the Commander's cursor or keyboard focus. It is put back on exit.
# Usage: ./run.sh [--cockpit|--dev] [--quality=ultra] [--mission=docking] ...
#        ./run.sh --landscape-console     also rotate the console monitor to landscape
#        ./run.sh --no-display-setup      skip the touch mapping
#        ./run.sh --no-touch-isolate      let the touchscreen move the mouse pointer and take
#                                         focus again (same as FALCON_TOUCH_ISOLATE=0)
#        ./run.sh --check-deps       report missing dependencies without installing/launching
#        ./run.sh --no-install       fail instead of installing missing dependencies
#        ./run.sh --fetch-assets     explicitly fetch optional Earth/Moon/OSM assets
#        ./run.sh --no-fetch          skip the first-run Earth/Moon/OSM download (tools/fetch_assets.sh)
#        ./run.sh --no-ics                no intercom helper (headsets off)
#        ./run.sh --eva-vr                the spacewalker's VR client (Meta Quest 3 via WiVRn);
#                                         start the cockpit first, then this (or LAUNCH VR CLIENT
#                                         on Commander -> EVA). See docs/game/VR_SETUP.md.
#        ./run.sh --eva-vr --eva-flat     same client on the desktop, no headset
# It also starts the intercom helper (tools/falcon_ics.py: 3 USB headsets, PTT/VOX, radio
# effect). It needs python3-numpy + pulseaudio-utils; if anything is missing it logs why to
# ~/.local/share/filament-falcon/ics.log. Runtime dependencies are checked before launch;
# missing enabled-feature dependencies are installed (sudo for apt, never for the game).
set -e
cd "$(dirname "$0")"
if [ "$(id -u)" = 0 ]; then echo "Run as your normal user, not sudo." >&2; exit 1; fi
# Update before sourcing any runtime helpers: if they changed, reload everything once.
source tools/launcher_update.sh
falcon_launcher_update "$@"
GODOT="${GODOT:-godot}"
SETUP_ARGS=()
GAME_ARGS=()
DO_SETUP=1
DO_ICS=1
DO_VOICE=1
DO_LED=1
DO_FETCH=0
DO_GEO=0
DEPS_MODE=auto
EVA_VR=0
XR_MODE=on
for a in "$@"; do
  case "$a" in
    --no-update) ;;
    --offline) DO_FETCH=0; DEPS_MODE=no-install ;;
    --landscape-console) SETUP_ARGS+=("--landscape") ;;
    --no-display-setup) DO_SETUP=0 ;;
    --no-touch-isolate) export FALCON_TOUCH_ISOLATE=0 ;;
    --no-ics) DO_ICS=0; GAME_ARGS+=("$a") ;;
    --no-voice) DO_VOICE=0; GAME_ARGS+=("$a") ;;
    --no-led) DO_LED=0; GAME_ARGS+=("$a") ;;
    --no-fetch) DO_FETCH=0 ;;
    --fetch-assets) DO_FETCH=1; DO_GEO=1 ;;
    --geo-tools) DO_GEO=1 ;;
    --check-deps) DEPS_MODE=check ;;
    --no-install) DEPS_MODE=no-install ;;
    --headless|--*test*|--screenshots=*) DEPS_MODE=no-install; DO_SETUP=0; DO_ICS=0; DO_VOICE=0; DO_LED=0; GAME_ARGS+=("$a") ;;
    --eva-vr) EVA_VR=1 ;;
    --eva-flat) XR_MODE=off ;;
    *) GAME_ARGS+=("$a") ;;
  esac
done
# Never launch the game as root (apt alone uses sudo).
if [ "$(id -u)" = 0 ]; then echo "Run as your normal user, not sudo." >&2; exit 1; fi
# Headless automation must never prompt/install implicitly.
[ "${FALCON_NO_INSTALL:-0}" != 1 ] || DEPS_MODE=no-install
# Respect saved feature disables too (Godot ConfigFile booleans are INI-compatible).
if command -v python3 >/dev/null 2>&1; then
  for feature in ics audio led; do
    if python3 - "$feature" "${XDG_DATA_HOME:-$HOME/.local/share}/filament-falcon/falcon_settings.cfg" <<'PYCFG'
import configparser, sys
c = configparser.ConfigParser(strict=False)
try:
    c.read(sys.argv[2])
    key = 'voice' if sys.argv[1] == 'audio' else 'enabled'
    sys.exit(0 if c.get(sys.argv[1], key, fallback='true').strip().lower() == 'false' else 1)
except configparser.Error:
    sys.exit(1)
PYCFG
    then
      case "$feature" in ics) DO_ICS=0;; audio) DO_VOICE=0;; led) DO_LED=0;; esac
    fi
  done
fi
source tools/runtime_deps.sh
falcon_runtime_deps || exit 1
[ "$DEPS_MODE" != check ] || exit 0
# Re-import on a fresh clone, or after a git pull changed any script/scene/shader (a stale
# class cache causes "Identifier ... not declared" parse errors and a broken game).
STAMP=.godot/.falcon_import_stamp
if [ ! -f .godot/global_script_class_cache.cfg ] || [ ! -f "$STAMP" ] || \
   [ -n "$(find . -path ./.godot -prune -o \( -name '*.gd' -o -name '*.tscn' -o -name '*.gdshader' -o -name 'project.godot' \) -newer "$STAMP" -print -quit)" ]; then
  echo "Importing project (first run or after an update, ~1 minute)..."
  "$GODOT" --headless --path . --import
  touch "$STAMP"
fi
ASSETS="${XDG_DATA_HOME:-$HOME/.local/share}/filament-falcon/assets"
if [ "$DO_FETCH" = 1 ] && [ ! -f "$ASSETS/.fetched" ] && [ ! -f "$ASSETS/.tried" ]; then
  # first run: real Earth/Moon textures + OSM region (~60 MB); failures never block launch
  mkdir -p "$ASSETS" && touch "$ASSETS/.tried"
  tools/fetch_assets.sh || true
fi
# OSM region: the New Brunswick .pbf is re-checked when older than 30 days (re-run fetch_assets)
OSM_META="$(ls "${XDG_DATA_HOME:-$HOME/.local/share}"/filament-falcon/osm/*.meta.json 2>/dev/null | head -1)"
if [ -n "$OSM_META" ] && [ -n "$(find "$OSM_META" -mtime +30 2>/dev/null)" ]; then
  echo "note: the OSM map is over 30 days old; tools/fetch_assets.sh refreshes it (only if Geofabrik has a newer one)"
fi
# REAL ISS mission: refresh the ISS orbit (TLE, ~150 bytes) twice a day in the background;
# the game falls back to the last file, then to built-in elements.
TLE="$ASSETS/iss.tle"
if [ "$DO_FETCH" = 1 ] && command -v curl >/dev/null 2>&1 && [ -z "$(find "$TLE" -mmin -720 2>/dev/null)" ]; then
  mkdir -p "$ASSETS"
  ( curl -fsm 15 "https://celestrak.org/NORAD/elements/gp.php?CATNR=25544&FORMAT=TLE" -o "$TLE.part" && \
    grep -q "^2 25544" "$TLE.part" && mv "$TLE.part" "$TLE" ) >/dev/null 2>&1 &
fi
if [ "$EVA_VR" = 1 ]; then
  # The cockpit instance owns the displays and the intercom; the VR client only renders the
  # headset view and streams the spacewalker's pose to it over localhost (UDP 47820).
  # Start WiVRn if it isn't running (stopped again on exit only if we started it).
  if [ "$XR_MODE" = on ] && [ -x tools/wivrn_up.sh ]; then
    RT=$(tools/wivrn_up.sh start | sed -n 's/^XR_RUNTIME_JSON=//p' | tail -1)
    [ -n "$RT" ] && [ -z "$XR_RUNTIME_JSON" ] && export XR_RUNTIME_JSON="$RT"
    trap 'tools/wivrn_up.sh stop' EXIT
    "$GODOT" --path . --xr-mode "$XR_MODE" -- --eva-client "${GAME_ARGS[@]}" || true
    exit 0
  fi
  exec "$GODOT" --path . --xr-mode "$XR_MODE" -- --eva-client "${GAME_ARGS[@]}"
fi
if [ "$DO_SETUP" = 1 ] && [ -x tools/setup_displays.sh ]; then
  tools/setup_displays.sh "${SETUP_ARGS[@]}" || true
fi
# Touch isolation; a watcher undoes it when the game exits (exec below keeps this pid), even
# after a crash. The next start also cleans up anything left over.
if [ -x tools/touch_isolate.sh ] && tools/touch_isolate.sh start; then
  TLOG="${XDG_DATA_HOME:-$HOME/.local/share}/filament-falcon/touch_isolate.log"
  if command -v setsid >/dev/null 2>&1; then
    nohup setsid tools/touch_isolate.sh watch $$ >"$TLOG" 2>&1 &
  else
    nohup tools/touch_isolate.sh watch $$ >"$TLOG" 2>&1 &
  fi
fi
if [ "$DO_ICS" = 1 ] && command -v python3 >/dev/null 2>&1; then
  LOGDIR="${XDG_DATA_HOME:-$HOME/.local/share}/filament-falcon"
  mkdir -p "$LOGDIR"
  # --parent-pid $$: exec below keeps this pid, so the helper exits when the game does.
  export FALCON_ICS=runsh
  nohup python3 tools/falcon_ics.py --parent-pid $$ --log "$LOGDIR/ics.log" >/dev/null 2>&1 &
fi
exec "$GODOT" --path . -- "${GAME_ARGS[@]}"
