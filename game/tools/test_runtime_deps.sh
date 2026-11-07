#!/usr/bin/env bash
# No network, real apt, sudo or installations: all dependency probes are mocked.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/path with spaces"
cat > "$T/path with spaces/engine" <<'MOCK'
#!/bin/sh
echo 4.7.2.stable.official.mock
MOCK
chmod +x "$T/path with spaces/engine"
export GODOT="$T/path with spaces/engine"
source "$ROOT/game/tools/runtime_deps.sh"
DO_ICS=1 DO_VOICE=1 DO_LED=1 DO_GEO=0 DO_SETUP=1 DO_FETCH=0 EVA_VR=0 XR_MODE=on DEPS_MODE=check
export DISPLAY=:99
python3() { return 0; }
dpkg-query() { echo 'install ok installed'; }
xinput() { :; }; xrandr() { :; }; pactl() { :; }; parec() { :; }; pacat() { :; }; espeak() { :; }
sudo() { echo 'ERROR: sudo must not run' >&2; exit 99; }
falcon_runtime_deps
# A missing import must fail check and no-install, without invoking sudo/network.
python3() { return 1; }
if falcon_runtime_deps >"$T/log" 2>&1; then echo 'FAIL missing import accepted'; exit 1; fi
grep -q 'Python numpy' "$T/log"
DEPS_MODE=no-install
if falcon_runtime_deps >"$T/log" 2>&1; then exit 1; fi
# Disabled features don't require their modules.
DO_ICS=0 DO_LED=0 DO_VOICE=0
falcon_runtime_deps
# Automatic mode cannot hang asking sudo in a noninteractive invocation.
DO_ICS=1 DEPS_MODE=auto
if falcon_runtime_deps </dev/null >"$T/log" 2>&1; then exit 1; fi
grep -q 'No unattended sudo prompts' "$T/log"
# Wrong engine version never passes check-only.
DO_ICS=0 DEPS_MODE=check
GODOT=false HOME="$T/empty home"
if falcon_runtime_deps >"$T/log" 2>&1; then exit 1; fi
grep -q 'Godot 4.7.2' "$T/log"
# Reused installer must refuse downloads without checksums.
(
 export FALCON_RUNTIME_SOURCE=1
 set --
 source "$ROOT/setup.sh"
 GODOT_DIR="$T/install"; GODOT_BIN="$GODOT_DIR/$GODOT_FILE"
 curl() {
   case "$*" in *SHA512-SUMS*) return 1;; *) return 0;; esac
 }
 do_godot || true
 [ "${#FAILS[@]}" -gt 0 ]
 [ ! -e "$GODOT_BIN" ]
)
echo 'RUNTIME DEPENDENCY TEST: PASS'
