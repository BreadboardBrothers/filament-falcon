#!/usr/bin/env bash
# One-time offer of built-in area packs on a normal launch (currently Starbase TX).
# Sourced by run.sh; never blocks the game. Downloads run on THIS PC only, in the
# existing area-manager background runner. --offline / --no-install / --check-deps
# skip the offer and do not record it, so a later normal launch can still add it.
# After a successful offer, a marker is kept so deleting the area later will not
# queue it again.

falcon_area_data_dir() {
  printf '%s\n' "${XDG_DATA_HOME:-$HOME/.local/share}/filament-falcon"
}

falcon_auto_preset_marked() {
  local marker="$1" id="$2"
  python3 - "$marker" "$id" <<'PY'
import json, sys
path, aid = sys.argv[1], sys.argv[2]
try:
    doc = json.load(open(path))
except Exception:
    sys.exit(1)
sys.exit(0 if isinstance(doc, dict) and doc.get(aid) else 1)
PY
}

falcon_mark_auto_preset() {
  local marker="$1" id="$2"
  python3 - "$marker" "$id" <<'PY'
import json, os, sys, time
path, aid = sys.argv[1], sys.argv[2]
os.makedirs(os.path.dirname(path), exist_ok=True)
try:
    doc = json.load(open(path))
    if not isinstance(doc, dict):
        doc = {}
except Exception:
    doc = {}
doc[aid] = {"offered": True, "time": time.time()}
part = path + ".part"
with open(part, "w") as f:
    json.dump(doc, f, indent=1)
    f.write("\n")
os.replace(part, path)
PY
}

falcon_ensure_default_areas() {
  # Launcher sets DEPS_MODE=no-install for --offline, --no-install, tests and headless.
  case "${DEPS_MODE:-auto}" in
    no-install|check) return 0 ;;
  esac
  [ "${FALCON_NO_INSTALL:-0}" != 1 ] || return 0
  command -v python3 >/dev/null 2>&1 || return 0

  local here data areas marker tool id
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  data="$(falcon_area_data_dir)"
  areas="$data/areas"
  marker="$areas/.auto_presets.json"
  tool="${FALCON_AREA_MANAGER:-$here/area_manager.py}"
  id=starbase

  mkdir -p "$areas" || return 0
  if [ -f "$marker" ] && falcon_auto_preset_marked "$marker" "$id"; then
    return 0
  fi
  # Already on this PC (user added it themselves): record the offer, do not re-queue.
  if [ -f "$areas/$id/area.json" ]; then
    falcon_mark_auto_preset "$marker" "$id" || true
    return 0
  fi
  [ -f "$tool" ] || return 0
  # Queue only (no download in this process). The runner, started in the background,
  # builds the pack on this PC and must not delay launch (it may wait a few seconds
  # to confirm it started).
  if python3 "$tool" add "$id"; then
    falcon_mark_auto_preset "$marker" "$id" || true
    echo "Queuing Starbase TX terrain pack in the background (Commander → AREAS shows progress)."
    python3 "$tool" run >/dev/null 2>&1 &
  fi
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  falcon_ensure_default_areas
fi
