#!/usr/bin/env bash
# Sourced by run.sh after parsing arguments; no package changes in check/no-install modes.
# Reuse setup.sh's pinned engine download/checksum implementation, not its broad workstation plan.
falcon_runtime_deps() {
  local root="$PWD/.." candidate="${GODOT:-godot}" missing=() packages=() cmd pkg
  local engine_ok=0
  if command -v "$candidate" >/dev/null 2>&1 && [[ "$("$candidate" --version 2>/dev/null)" == 4.7.2.stable* ]]; then
    engine_ok=1
  elif [ -x "$HOME/Apps/godot/Godot_v4.7.2-stable_linux.x86_64" ]; then
    candidate="$HOME/Apps/godot/Godot_v4.7.2-stable_linux.x86_64"
    [[ "$("$candidate" --version 2>/dev/null)" == 4.7.2.stable* ]] && engine_ok=1
  fi
  local specs=("python3:python3")
  [ "$DO_VOICE" != 1 ] || command -v espeak >/dev/null 2>&1 || specs+=("espeak-ng:espeak-ng")
  if [ "$DO_ICS" = 1 ]; then specs+=("pactl:pulseaudio-utils" "parec:pulseaudio-utils" "pacat:pulseaudio-utils"); fi
  if { [ "$DO_SETUP" = 1 ] || [ "${FALCON_TOUCH_ISOLATE:-1}" != 0 ]; } && [ -n "${DISPLAY:-}" ] && [ "${XDG_SESSION_TYPE:-x11}" != wayland ]; then specs+=("xrandr:x11-xserver-utils" "xinput:xinput"); fi
  if [ "$engine_ok" = 0 ]; then specs+=("curl:curl" "unzip:unzip" "sha512sum:coreutils"); fi
  if [ "$DO_FETCH" = 1 ]; then specs+=("curl:curl"); fi
  for cmd in "${specs[@]}"; do
    pkg="${cmd#*:}"; cmd="${cmd%%:*}"
    if ! command -v "$cmd" >/dev/null 2>&1; then missing+=("$cmd"); packages+=("$pkg"); fi
  done
  # Native libraries used by the standard engine and X11 ctypes helpers, not drivers.
  # Package checks also cover libraries missing on a minimal fresh Mint installation.
  if command -v dpkg-query >/dev/null 2>&1; then
    for pkg in ca-certificates libvulkan1 libgl1 libx11-6 libxtst6 libxcursor1 libxinerama1 libxrandr2 libxi6 libxext6 libxfixes3 libfontconfig1 libudev1 libdbus-1-3 libpulse0; do
      if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'; then
        missing+=("$pkg"); packages+=("$pkg")
      fi
    done
  fi
  if command -v dpkg-query >/dev/null 2>&1; then
    if ! { dpkg-query -W -f='${Status}' libasound2 2>/dev/null; dpkg-query -W -f='${Status}' libasound2t64 2>/dev/null; } | grep -q 'install ok installed'; then
      pkg=libasound2
      if command -v apt-cache >/dev/null && apt-cache show libasound2t64 >/dev/null 2>&1; then pkg=libasound2t64; fi
      missing+=("ALSA runtime library"); packages+=("$pkg")
    fi
  fi
  local modules=()
  [ "$DO_LED" != 1 ] || modules+=("serial:python3-serial")
  [ "$DO_ICS" = 1 ] && modules+=("numpy:python3-numpy")
  [ "$DO_GEO" = 1 ] && modules+=("numpy:python3-numpy" "PIL:python3-pil" "osmium:python3-pyosmium")
  for cmd in "${modules[@]}"; do
    pkg="${cmd#*:}"; cmd="${cmd%%:*}"
    if ! python3 -c "import $cmd" >/dev/null 2>&1; then missing+=("Python $cmd"); packages+=("$pkg"); fi
  done
  if [ "$engine_ok" = 0 ]; then missing+=("Godot 4.7.2"); fi
  if [ "${#missing[@]}" != 0 ]; then
    printf 'Falcon missing: %s\n' "${missing[*]}" >&2
    if [ "$DEPS_MODE" != auto ]; then
      echo 'Dependency check failed. Run ./run.sh interactively to install, or supply GODOT=/path/to/4.7.2.' >&2
      return 1
    fi
    if [ "${#packages[@]}" != 0 ]; then
      local ID='' ID_LIKE=''
      [ ! -r /etc/os-release ] || . /etc/os-release
      case " $ID $ID_LIKE " in *debian*|*ubuntu*|*linuxmint*) ;; *) echo 'Automatic apt install requires Mint/Ubuntu/Debian. Install the listed dependencies manually.' >&2; return 1;; esac
      if ! [ -t 0 ] || ! command -v sudo >/dev/null; then
        echo 'Missing system packages; open a terminal with sudo access and run again. No unattended sudo prompts.' >&2
        return 1
      fi
      echo "Installing only missing runtime packages: ${packages[*]} (sudo may ask for your password)."
      sudo apt-get update && sudo apt-get install -y --no-install-recommends "${packages[@]}" || {
        echo 'apt failed (check network, repositories and sudo access); game not launched.' >&2; return 1;
      }
    fi
    if [ "$engine_ok" = 0 ]; then
      # The reusable installer defines variables: isolate them in a subshell.
      ( export FALCON_RUNTIME_SOURCE=1; set --; source "$root/setup.sh"; do_godot; [ "${#FAILS[@]}" = 0 ] ) || {
        echo 'Engine install failed; check network/checksum errors above.' >&2; return 1;
      }
      candidate="$HOME/Apps/godot/Godot_v4.7.2-stable_linux.x86_64"
    fi
    DEPS_MODE=no-install GODOT="$candidate" falcon_runtime_deps || return 1
  fi
  if [ "$EVA_VR" = 1 ] && [ "$XR_MODE" = on ]; then
    if ! command -v flatpak >/dev/null 2>&1 || ! flatpak info io.github.wivrn.wivrn >/dev/null 2>&1; then
      echo 'VR requested: WiVRn/runtime must be configured separately; see docs/game/VR_SETUP.md or use --eva-flat.' >&2
      return 1
    fi
  fi
  GODOT="$candidate"
  export GODOT
  [ "$DEPS_MODE" != check ] || echo 'Required runtime dependencies OK (no changes made).'
}
