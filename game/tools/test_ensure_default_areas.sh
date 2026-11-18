#!/usr/bin/env bash
# No network, no real area downloads: area_manager.py is mocked.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
source "$ROOT/game/tools/ensure_default_areas.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
bash -n "$ROOT/game/tools/ensure_default_areas.sh"
bash -n "$ROOT/game/run.sh"

mkdir -p "$T/cwd with spaces" "$T/share"
export HOME="$T/home"
export XDG_DATA_HOME="$T/share"
mkdir -p "$HOME"

cat > "$T/fake_area_manager.py" <<'PY'
#!/usr/bin/env python3
"""Record calls and write a queued area.json. Never download."""
import json, os, sys, time
T = os.environ["TEST_DIR"]
data = os.path.join(os.environ.get("XDG_DATA_HOME", os.path.expanduser("~/.local/share")), "filament-falcon")
cmd = sys.argv[1] if len(sys.argv) > 1 else ""
log = "calls" if cmd == "add" else "run-calls"
open(os.path.join(T, log), "a").write(" ".join(sys.argv[1:]) + "\n")
if cmd == "add":
    aid = sys.argv[2]
    d = os.path.join(data, "areas", aid)
    os.makedirs(d, exist_ok=True)
    json.dump({"id": aid, "name": "Starbase TX", "bbox": [25.94, -97.28, 26.18, -97.00]},
              open(os.path.join(d, "area.json"), "w"), indent=1)
    os.makedirs(os.path.join(data, "areas", "queue"), exist_ok=True)
    json.dump({"id": aid}, open(os.path.join(data, "areas", "queue", "1_%s.json" % aid), "w"))
    print("queued", aid)
elif cmd == "run":
    # Deliberately slow: the helper must return without waiting for this.
    open(os.path.join(T, "run-started"), "w").write("1")
    time.sleep(float(os.environ.get("FAKE_RUN_SLEEP", "0")))
    open(os.path.join(T, "run-finished"), "w").write("1")
sys.exit(0)
PY
chmod +x "$T/fake_area_manager.py"
export FALCON_AREA_MANAGER="$T/fake_area_manager.py"
export TEST_DIR="$T"
export FAKE_RUN_SLEEP=4
unset FALCON_NO_INSTALL || true
DEPS_MODE=auto

# 1) First normal launch queues once and does not wait for the runner.
rm -f "$T/calls" "$T/run-calls" "$T/run-started" "$T/run-finished"
start=$(date +%s)
falcon_ensure_default_areas >"$T/log"
elapsed=$(( $(date +%s) - start ))
[ "$elapsed" -lt 3 ] || { echo "FAIL blocked launch (${elapsed}s)"; exit 1; }
grep -q "Queuing Starbase TX terrain pack" "$T/log"
grep -q '^add starbase$' "$T/calls"
[ -f "$T/share/filament-falcon/areas/starbase/area.json" ]
[ -f "$T/share/filament-falcon/areas/.auto_presets.json" ]
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["starbase"]["offered"]' "$T/share/filament-falcon/areas/.auto_presets.json"
# runner was started in the background (may take a moment to appear)
for i in $(seq 1 20); do
  [ -f "$T/run-started" ] && grep -q '^run$' "$T/run-calls" && break
  sleep 0.1
done
grep -q '^run$' "$T/run-calls" || { echo 'FAIL runner was not started'; exit 1; }
[ -f "$T/run-started" ]
[ ! -f "$T/run-finished" ]  # still sleeping; we did not wait

# Remaining cases should not race a leftover background runner writing "calls".
export FAKE_RUN_SLEEP=0
# Wait for (or give up on) the slow first run so its late "run" line cannot sneak in.
for i in $(seq 1 50); do
  [ -f "$T/run-finished" ] && break
  sleep 0.1
done
rm -f "$T/calls" "$T/run-calls" "$T/run-started" "$T/run-finished"

# 2) Second launch must not add or spawn again.
falcon_ensure_default_areas >"$T/log2"
[ ! -e "$T/calls" ]
[ ! -e "$T/run-calls" ]
grep -qv "Queuing" "$T/log2" || [ ! -s "$T/log2" ]

# 3) Deleting the area later must not re-add it (marker remains).
rm -rf "$T/share/filament-falcon/areas/starbase"
falcon_ensure_default_areas >"$T/log3"
[ ! -e "$T/calls" ]
[ ! -e "$T/run-calls" ]
[ ! -d "$T/share/filament-falcon/areas/starbase" ]

# 4) --offline / --no-install / check-deps skip and do not write a marker
#    on a fresh data dir, so a later normal launch can still offer.
fresh="$T/share2"
rm -rf "$fresh"
export XDG_DATA_HOME="$fresh"
mkdir -p "$fresh"
rm -f "$T/calls"
for mode in no-install check; do
  DEPS_MODE=$mode
  falcon_ensure_default_areas >"$T/log-skip"
  [ ! -e "$T/calls" ]
  [ ! -f "$fresh/filament-falcon/areas/.auto_presets.json" ]
done
FALCON_NO_INSTALL=1 DEPS_MODE=auto
falcon_ensure_default_areas >"$T/log-skip2"
[ ! -e "$T/calls" ]
[ ! -f "$fresh/filament-falcon/areas/.auto_presets.json" ]
unset FALCON_NO_INSTALL
DEPS_MODE=auto
# later normal launch on that same fresh dir still offers
falcon_ensure_default_areas >"$T/log-after-skip"
grep -q '^add starbase$' "$T/calls"
[ -f "$fresh/filament-falcon/areas/.auto_presets.json" ]

# 5) Already-present area: mark offered, do not queue again.
export XDG_DATA_HOME="$T/share3"
mkdir -p "$XDG_DATA_HOME/filament-falcon/areas/starbase"
echo '{"id":"starbase","name":"Starbase TX"}' > "$XDG_DATA_HOME/filament-falcon/areas/starbase/area.json"
rm -f "$T/calls"
falcon_ensure_default_areas >"$T/log-existing"
[ ! -e "$T/calls" ]
[ ! -e "$T/run-calls" ]
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["starbase"]["offered"]' "$XDG_DATA_HOME/filament-falcon/areas/.auto_presets.json"

# 6) Paths with spaces in HOME / XDG_DATA_HOME still work.
export XDG_DATA_HOME="$T/path with spaces/share"
mkdir -p "$XDG_DATA_HOME"
rm -f "$T/calls"
DEPS_MODE=auto
falcon_ensure_default_areas >"$T/log-spaces"
grep -q '^add starbase$' "$T/calls"
[ -f "$XDG_DATA_HOME/filament-falcon/areas/starbase/area.json" ]
[ -f "$XDG_DATA_HOME/filament-falcon/areas/.auto_presets.json" ]

echo 'ENSURE DEFAULT AREAS TEST: PASS'
