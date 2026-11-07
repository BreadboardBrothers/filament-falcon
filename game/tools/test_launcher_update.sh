#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
source "$ROOT/game/tools/launcher_update.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/cwd with spaces"; cd "$T/cwd with spaces"
exec() { printf '%s\n' "$@" > "$T/exec"; }
timeout() { shift; "$@"; }
git() {
  case "$*" in
    'rev-parse --is-inside-work-tree') [ "$SCENARIO" != archive ];;
    'status --porcelain') [ "$SCENARIO" != dirty ] || echo ' M local file';;
    'rev-parse --abbrev-ref @{upstream}') [ "$SCENARIO" != unset ] || return 1; echo origin/main;;
    'rev-parse HEAD') if [ -f "$T/pulled" ] && [[ "$SCENARIO" = ff || "$SCENARIO" = dirty ]]; then echo new; else echo old; fi;;
    *pull*)
      [[ "$*" == *"pull --ff-only --no-rebase" ]] || return 96
      [ -f "$T/local-work" ] || return 97
      [ "${GIT_TERMINAL_PROMPT:-}" = 0 ] || return 99
      echo pull >> "$T/calls"
      case "$SCENARIO" in offline|diverged|conflict) return 1;; esac
      touch "$T/pulled";;
    *) echo "unexpected git $*" >&2; return 98;;
  esac
}
for SCENARIO in archive dirty unset offline diverged conflict unchanged ff; do
  rm -f "$T/pulled" "$T/exec" "$T/calls"
  unset FALCON_UPDATED_PID
  echo preserved > "$T/local-work"
  falcon_launcher_update '--mission=two words' --no-fetch > "$T/log"
  [ "$(cat "$T/local-work")" = preserved ]
  if [ "$SCENARIO" = conflict ]; then grep -q "no work discarded" "$T/log"; fi
  case "$SCENARIO" in
    archive|unset) [ ! -e "$T/calls" ];;
    offline|diverged|conflict|unchanged) [ -e "$T/calls" ]; [ ! -e "$T/exec" ];;
    ff|dirty)
      grep -q -- '--mission=two words' "$T/exec"
      grep -q 'cwd with spaces/run.sh' "$T/exec"
      [ "$FALCON_UPDATED_PID" = "$$" ]
      falcon_launcher_update
      [ "$(wc -l < "$T/calls")" = 1 ];;
  esac
done
for flag in --no-update --offline --check-deps --solar-test; do
  unset FALCON_UPDATED_PID
  rm -f "$T/calls"
  falcon_launcher_update "$flag"
  [ ! -e "$T/calls" ]
done
unset FALCON_UPDATED_PID
SCENARIO=unchanged
rm -f "$T/calls"
falcon_launcher_update --headless --no-install
[ -e "$T/calls" ]
echo 'LAUNCHER UPDATE TEST: PASS'
