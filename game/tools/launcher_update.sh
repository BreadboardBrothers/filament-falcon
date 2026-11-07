#!/usr/bin/env bash
# Sourced early by run.sh. Never discards local work; an update failure is nonfatal.
falcon_launcher_update() {
  local arg before after upstream
  [ "${FALCON_UPDATED_PID:-}" != "$$" ] || return 0
  for arg in "$@"; do
    case "$arg" in --no-update|--offline|--check-deps|--*-test|--ui-fit|--screenshots=*) return 0;; esac
  done
  if ! command -v git >/dev/null || ! command -v timeout >/dev/null; then
    echo 'Update skipped: git/timeout unavailable; using installed version.'; return 0
  fi
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo 'Update skipped: no Git checkout (archive install).'; return 0
  fi
  upstream=$(git rev-parse --abbrev-ref '@{upstream}' 2>/dev/null) || {
    echo 'Update skipped: no configured upstream (or detached HEAD).'; return 0;
  }
  before=$(git rev-parse HEAD) || return 0
  # Don't prompt for credentials, and don't wait indefinitely on a broken network.
  if ! GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never GIT_ASKPASS=/bin/false SSH_ASKPASS=/bin/false \
    GIT_SSH_COMMAND='ssh -oBatchMode=yes -oConnectTimeout=5' \
    timeout 20 git -c credential.interactive=false pull --ff-only --no-rebase; then
    echo "Update unavailable (offline/auth/divergence or local conflicts; no work discarded); using installed version. Upstream: $upstream"
    return 0
  fi
  after=$(git rev-parse HEAD) || return 0
  if [ "$before" != "$after" ]; then
    echo 'Updated. Restarting launcher once with original arguments.'
    export FALCON_UPDATED_PID=$$
    exec bash "$PWD/run.sh" "$@"
  fi
}
