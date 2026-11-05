#!/usr/bin/env bash
# The Filament Falcon: first-time setup for a new Linux Mint 21/22 PC (Ubuntu 22.04/24.04 base).
# Installs everything the game and its helpers need, then checks it all ("doctor").
# Safe to re-run: things already installed are skipped. Nothing is ever deleted or overwritten
# (an existing different `godot` link or udev rule is reported, not replaced).
#
#   ./setup.sh                 interactive: shows the plan, asks once, then installs
#   ./setup.sh --yes           no questions (apt -y, flatpak -y)
#   ./setup.sh --dry-run       print every command it would run, change nothing, download nothing
#   ./setup.sh --check         only the doctor report: what is OK / missing, and next steps
#                              (exit code 0 = nothing missing; warnings don't count)
#   ./setup.sh --no-assets     skip the NASA Earth/Moon textures + OSM Fredericton download
#   ./setup.sh --no-hd         assets without the HD Earth (~80 MB less)
#   ./setup.sh --region=NAME   OSM detail region (default fredericton; see game/tools/build_region.py --list)
#   ./setup.sh --no-vr         skip WiVRn (Flatpak), adb and the Quest udev rules
#   ./setup.sh --no-hardware   skip the ESP32 panel udev rule + dialout group
#   ./setup.sh --no-apt        skip apt (system packages) · --no-pip: skip pyosmium
#   ./setup.sh --no-godot      don't download Godot (use your own; set GODOT=/path or put `godot` on PATH)
#   ./setup.sh --godot-dir=DIR where Godot goes (default ~/Apps/godot)
#
# sudo is only used for: apt-get (system packages), copying the ESP32 udev rule to
# /etc/udev/rules.d, adding you to the dialout/plugdev groups, enabling avahi-daemon (WiVRn
# discovery) and, only if ~/.local/bin is not on your PATH, a /usr/local/bin/godot link.
# Godot, pip packages, WiVRn (Flatpak --user) and the game assets go into your home folder.
set -u
set -o pipefail

USER="${USER:-$(id -un)}"
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
GAME="$ROOT/game"
GODOT_VER="4.7.2"
GODOT_TAG="${GODOT_VER}-stable"
GODOT_FILE="Godot_v${GODOT_TAG}_linux.x86_64"
GODOT_URL="${FALCON_GODOT_URL:-https://github.com/godotengine/godot/releases/download/${GODOT_TAG}}"   # override: mirror / tests
GODOT_DIR="$HOME/Apps/godot"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}/filament-falcon"
VENV="$DATA/pyenv"
WIVRN=io.github.wivrn.wivrn
FLATHUB=https://dl.flathub.org/repo/flathub.flatpakrepo
UDEV_SRC="$ROOT/firmware/udev/99-filament-falcon.rules"
UDEV_DST=/etc/udev/rules.d/99-filament-falcon.rules

APT=1; PIP=1; YES=0; DRY=0; CHECK=0; ASSETS=1; HD=1; VR=1; HW=1; DO_GODOT=1; REGION=fredericton
for a in "$@"; do
  case "$a" in
    -y|--yes) YES=1 ;;
    -n|--dry-run) DRY=1 ;;
    --check) CHECK=1 ;;
    --no-assets) ASSETS=0 ;;
    --no-hd) HD=0 ;;
    --no-vr) VR=0 ;;
    --no-hardware) HW=0 ;;
    --no-godot) DO_GODOT=0 ;;
    --no-apt) APT=0 ;;
    --no-pip) PIP=0 ;;
    --godot-dir=*) GODOT_DIR="${a#*=}" ;;
    --region=*) REGION="${a#*=}" ;;
    -h|--help) sed -n '2,/^set -u/{/^#/s/^# \{0,1\}//p}' "$0"; exit 0 ;;
    *) echo "setup.sh: unknown option '$a' (see --help)" >&2; exit 2 ;;
  esac
done
GODOT_BIN="$GODOT_DIR/$GODOT_FILE"

# ---------------------------------------------------------------- output helpers
if [ -t 1 ]; then B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; N=$'\e[0m'; else B=""; G=""; Y=""; R=""; N=""; fi
say()  { printf '%s\n' "$*"; }
step() { printf '\n%s== %s%s\n' "$B" "$*" "$N"; }
ok()   { printf '  %sOK%s      %s\n' "$G" "$N" "$*"; }
warn() { printf '  %sWARN%s    %s\n' "$Y" "$N" "$*"; }
bad()  { printf '  %sMISSING%s %s\n' "$R" "$N" "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }
# run CMD...: execute (or just print in --dry-run)
run() {
  if [ "$DRY" = 1 ]; then printf '  [dry-run] %s\n' "$*"; return 0; fi
  printf '  $ %s\n' "$*"
  "$@"
}
# sudo_run "why" CMD...: say why root is needed, then run with sudo
SUDO_TOLD=""
sudo_run() {
  local why="$1"; shift
  if [ "$DRY" = 1 ]; then printf '  [dry-run] sudo %s    (%s)\n' "$*" "$why"; return 0; fi
  if [ "$SUDO_TOLD" != "$why" ]; then say "  sudo needed: $why"; SUDO_TOLD="$why"; fi
  printf '  $ sudo %s\n' "$*"
  sudo "$@"
}
FAILS=()
fail() { FAILS+=("$*"); printf '  %s! %s%s\n' "$R" "$*" "$N"; }

# ---------------------------------------------------------------- preflight
preflight() {
  if [ "$(id -u)" = 0 ]; then
    echo "Run setup.sh as your normal user (not with sudo): it installs into your home folder and asks for sudo only where needed." >&2
    exit 1
  fi
  [ "$(uname -s)" = Linux ] || { echo "setup.sh is for Linux (Mint 21/22)." >&2; exit 1; }
  [ "$(uname -m)" = x86_64 ] || warn "not an x86_64 machine: the Godot download is for x86_64"
  local id="" ver="" base=""
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    id="${ID:-}"; ver="${VERSION_ID:-}"; base="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
  fi
  say "${B}The Filament Falcon setup${N}  ($id $ver, base $base)  repo: $ROOT"
  case "$id" in linuxmint|ubuntu|pop|zorin|elementary) ;; *) warn "tested on Linux Mint 21/22 only; continuing (apt packages may differ)";; esac
  have apt-get || { echo "apt-get not found: this script needs a Debian/Ubuntu/Mint system." >&2; exit 1; }
}

# ---------------------------------------------------------------- apt
# A package "group" lists alternatives with '|' (first one apt knows wins), e.g. Mint 22 renamed
# libasound2 to libasound2t64 and adb to android-tools-adb's successor "adb".
APT_CORE=(curl ca-certificates git unzip python3 python3-numpy python3-pil python3-pip python3-venv
  osmium-tool python3-serial espeak-ng alsa-utils pulseaudio-utils xinput x11-xserver-utils
  desktop-file-utils mesa-vulkan-drivers vulkan-tools libvulkan1 libgl1 libx11-6 libxtst6 libxcursor1
  libxinerama1 libxrandr2 libxi6 libxext6 libxfixes3 libfontconfig1 libudev1 libdbus-1-3 libpulse0
  "libasound2t64|libasound2")
APT_VR=(flatpak "android-tools-adb|adb" android-sdk-platform-tools-common avahi-daemon)
APT_HW=(evtest joystick)

apt_known() { apt-cache show "$1" >/dev/null 2>&1; }
pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"; }
# resolve "a|b" -> installed one, else first known one, else ""
pkg_pick() {
  local alt p; IFS='|' read -r -a alt <<<"$1"
  for p in "${alt[@]}"; do pkg_installed "$p" && { echo "$p"; return; }; done
  for p in "${alt[@]}"; do apt_known "$p" && { echo "$p"; return; }; done
  echo ""
}
APT_MISSING=()
apt_scan() {
  local groups=("${APT_CORE[@]}") g p
  [ "$VR" = 1 ] && groups+=("${APT_VR[@]}")
  [ "$HW" = 1 ] && groups+=("${APT_HW[@]}")
  # Mint 22 / PipeWire: pactl needs the PulseAudio shim; only add it when PipeWire is the server
  if pkg_installed pipewire && ! pkg_installed pulseaudio; then groups+=(pipewire-pulse); fi
  APT_MISSING=()
  for g in "${groups[@]}"; do
    p="$(pkg_pick "$g")"
    if [ -z "$p" ]; then warn "no apt package for '$g' on this release (skipped)"; continue; fi
    pkg_installed "$p" || APT_MISSING+=("$p")
  done
}
do_apt() {
  step "System packages (apt)"
  apt_scan
  if [ "${#APT_MISSING[@]}" = 0 ]; then ok "all apt packages already installed"; return; fi
  say "  to install: ${APT_MISSING[*]}"
  local y=(); [ "$YES" = 1 ] && y=(-y)
  sudo_run "install system packages with apt-get" apt-get update || fail "apt-get update failed"
  sudo_run "install system packages with apt-get" apt-get install "${y[@]}" "${APT_MISSING[@]}" || fail "apt-get install failed (see above)"
}

# ---------------------------------------------------------------- python (pyosmium)
py_has() { python3 -c "import $1" >/dev/null 2>&1; }
do_python() {
  step "Python modules (numpy, Pillow, pyserial from apt; pyosmium from pip)"
  if py_has osmium; then ok "pyosmium already importable"; return; fi
  if [ "$DRY" = 1 ]; then
    run python3 -m pip install --user --break-system-packages osmium
    say "  (fallback if that fails: venv $VENV + a .pth link so the system python3 finds it)"
    return
  fi
  have python3 || { fail "python3 missing (apt step failed?)"; return; }
  local brk=()
  python3 -m pip install --help 2>/dev/null | grep -q -- --break-system-packages && brk=(--break-system-packages)
  if run python3 -m pip install --user "${brk[@]}" osmium && py_has osmium; then ok "pyosmium installed (pip --user)"; return; fi
  warn "pip --user failed; using a private venv instead: $VENV"
  if run python3 -m venv --system-site-packages "$VENV" && run "$VENV/bin/python" -m pip install osmium; then
    # make the system python3 (used by the game, run.sh and fetch_assets.sh) see the venv's packages
    local site usersite
    site="$("$VENV/bin/python" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')"
    usersite="$(python3 -m site --user-site)"
    run mkdir -p "$usersite"
    if [ "$DRY" = 0 ]; then printf '%s\n' "$site" > "$usersite/filament-falcon-pyenv.pth"; fi
    if py_has osmium; then ok "pyosmium installed (venv + $usersite/filament-falcon-pyenv.pth)"; else fail "pyosmium still not importable"; fi
  else
    fail "could not install pyosmium (the OSM region falls back to the slower Overpass API)"
  fi
}

# ---------------------------------------------------------------- Godot
godot_on_path() { have godot && [ "$(readlink -f "$(command -v godot)")" = "$(readlink -f "$GODOT_BIN")" ]; }
do_godot() {
  step "Godot $GODOT_VER (standard, Linux x86_64) -> $GODOT_DIR"
  if [ -x "$GODOT_BIN" ] && "$GODOT_BIN" --version 2>/dev/null | grep -q "^${GODOT_VER}\.stable"; then
    ok "$GODOT_BIN already installed"
  else
    local tmp=/tmp/falcon-godot-XXXX
    [ "$DRY" = 1 ] || tmp="$(mktemp -d)"
    run mkdir -p "$GODOT_DIR"
    run curl -fL --retry 3 --connect-timeout 20 -o "$tmp/$GODOT_FILE.zip" "$GODOT_URL/$GODOT_FILE.zip" || { fail "Godot download failed"; [ "$DRY" = 1 ] || rm -rf "$tmp"; return; }
    if run curl -fsSL --retry 3 -o "$tmp/SHA512-SUMS.txt" "$GODOT_URL/SHA512-SUMS.txt"; then
      if [ "$DRY" = 0 ]; then
        if (cd "$tmp" && grep " $GODOT_FILE.zip\$" SHA512-SUMS.txt | sha512sum -c --status -); then
          ok "SHA-512 checksum matches the official release"
        else
          fail "Godot checksum MISMATCH: not installing it (re-run; if it persists, download manually)"; [ "$DRY" = 1 ] || rm -rf "$tmp"; return
        fi
      fi
    else
      warn "could not fetch SHA512-SUMS.txt: installing without checksum verification"
    fi
    run unzip -o -q "$tmp/$GODOT_FILE.zip" -d "$GODOT_DIR" || { fail "unzip failed"; [ "$DRY" = 1 ] || rm -rf "$tmp"; return; }
    run chmod +x "$GODOT_BIN"
    [ "$DRY" = 1 ] || rm -rf "$tmp"
  fi
  # `godot` on PATH (run.sh and the VR launcher call `godot` unless $GODOT is set)
  if godot_on_path; then ok "godot on PATH -> $GODOT_BIN"; return; fi
  if have godot; then
    warn "another godot is on PATH ($(readlink -f "$(command -v godot)")): left alone. Use GODOT=$GODOT_BIN ./run.sh, or remove that link"
    return
  fi
  local lb="$HOME/.local/bin/godot"
  if [ -e "$lb" ] && [ "$(readlink -f "$lb")" != "$(readlink -f "$GODOT_BIN")" ]; then
    warn "$lb exists and points elsewhere: left alone"
  else
    run mkdir -p "$HOME/.local/bin"
    run ln -sfn "$GODOT_BIN" "$lb"
  fi
  case ":$PATH:" in
    *":$HOME/.local/bin:"*) if [ "$DRY" = 0 ]; then ok "linked $lb"; fi ;;
    *)
      if [ ! -e /usr/local/bin/godot ]; then
        sudo_run "link /usr/local/bin/godot (your ~/.local/bin is not on PATH yet)" ln -s "$GODOT_BIN" /usr/local/bin/godot || fail "could not link /usr/local/bin/godot"
      else
        warn "/usr/local/bin/godot exists: left alone (log out/in so ~/.local/bin joins PATH)"
      fi ;;
  esac
}
godot_import() {
  local g="$GODOT_BIN"; [ -x "$g" ] || g="$(command -v godot || true)"
  [ -n "$g" ] || return
  step "Godot project import (once, ~1 minute; run.sh would do it on first launch)"
  if [ -f "$GAME/.godot/global_script_class_cache.cfg" ] && [ -f "$GAME/.godot/.falcon_import_stamp" ]; then ok "already imported"; return; fi
  say "  \$ $g --headless --path $GAME --import   (output hidden)"
  if "$g" --headless --path "$GAME" --import >/dev/null 2>&1; then
    run touch "$GAME/.godot/.falcon_import_stamp"; ok "imported"
  else
    warn "import reported errors (run.sh retries on launch)"
  fi
}

# ---------------------------------------------------------------- VR (WiVRn, adb)
in_group_db() { getent group "$1" | cut -d: -f4 | tr ',' '\n' | grep -qx "$USER"; }
add_group() {  # group why
  getent group "$1" >/dev/null || { warn "group $1 does not exist"; return; }
  if in_group_db "$1"; then ok "you are in the $1 group"; return; fi
  if sudo_run "add you to the '$1' group ($2)" usermod -aG "$1" "$USER" && [ "$DRY" = 0 ]; then NEED_RELOGIN=1; fi
}
do_vr() {
  step "VR spacewalk: WiVRn (Flatpak, --user), adb + Quest udev rules, avahi"
  if ! have flatpak && [ "$DRY" = 0 ]; then fail "flatpak missing (apt step failed?)"; return; fi
  if flatpak info "$WIVRN" >/dev/null 2>&1; then
    ok "WiVRn installed ($(flatpak info "$WIVRN" 2>/dev/null | sed -n 's/^ *Version: //p'))"
  else
    local y=(); [ "$YES" = 1 ] && y=(-y)
    run flatpak remote-add --user --if-not-exists flathub "$FLATHUB" || fail "flathub remote failed"
    run flatpak install --user "${y[@]}" flathub "$WIVRN" || fail "WiVRn install failed"
  fi
  if have systemctl && ! systemctl is-active --quiet avahi-daemon 2>/dev/null; then
    sudo_run "start avahi-daemon (the Quest finds the PC by mDNS)" systemctl enable --now avahi-daemon || warn "could not start avahi-daemon"
  else
    ok "avahi-daemon running"
  fi
  add_group plugdev "adb access to the Quest over USB"
  if have ufw && sudo -n ufw status 2>/dev/null | grep -q "Status: active"; then
    warn "ufw firewall is on: allow WiVRn with: sudo ufw allow 5353/udp && sudo ufw allow 9757 (not changed automatically)"
  fi
  if [ -x "$GAME/tools/install_vr_launcher.sh" ] && { [ -x "$GODOT_BIN" ] || have godot; }; then
    local g="$GODOT_BIN"; [ -x "$g" ] || g="$(command -v godot)"
    if [ "$DRY" = 1 ]; then run env GODOT="$g" "$GAME/tools/install_vr_launcher.sh"
    else GODOT="$g" "$GAME/tools/install_vr_launcher.sh" >/dev/null && ok "Quest launcher entry installed (pick it in the WiVRn app)"; fi
  fi
}

# ---------------------------------------------------------------- ESP32 panels
do_hw() {
  step "Cockpit panels (ESP32-S3): udev rule + dialout group"
  if [ ! -f "$UDEV_SRC" ]; then warn "$UDEV_SRC not found"; return; fi
  if [ -f "$UDEV_DST" ] && cmp -s "$UDEV_SRC" "$UDEV_DST"; then
    ok "udev rule installed ($UDEV_DST)"
  elif [ -f "$UDEV_DST" ]; then
    warn "$UDEV_DST differs from the repo copy: left alone (compare: diff $UDEV_SRC $UDEV_DST)"
  else
    if sudo_run "install the panel udev rule (stable /dev/falcon-command, joystick access)" install -m 644 "$UDEV_SRC" "$UDEV_DST"; then
      sudo_run "reload udev rules" udevadm control --reload
      sudo_run "reload udev rules" udevadm trigger
    else
      fail "udev rule install failed"
    fi
  fi
  add_group dialout "serial access to the LED controller without the udev rule"
}

# ---------------------------------------------------------------- assets
do_assets() {
  step "Game assets: NASA Earth/Moon textures + OSM + SOLAR maps '$REGION' (into $DATA/assets)"
  local args=("--region=$REGION"); [ "$HD" = 0 ] && args+=(--no-hd)
  if [ "$DRY" = 1 ]; then run "$GAME/tools/fetch_assets.sh" "${args[@]}"; return; fi
  "$GAME/tools/fetch_assets.sh" "${args[@]}" || fail "asset download had problems (re-run: game/tools/fetch_assets.sh)"
}

# ---------------------------------------------------------------- doctor
NEED_RELOGIN=0
doctor() {
  step "Doctor: checking the install"
  local miss=0 w=0 nexts=() g="" v=""
  # Godot
  if [ -x "$GODOT_BIN" ]; then g="$GODOT_BIN"; elif have godot; then g="$(command -v godot)"; fi
  if [ -n "$g" ] && v="$("$g" --headless --version 2>/dev/null | tail -1)" && [ -n "$v" ]; then
    case "$v" in "${GODOT_VER}.stable"*) ok "Godot $v ($g)";; *) warn "Godot $v (the project targets $GODOT_VER)"; w=$((w+1));; esac
    if have godot; then ok "godot on PATH"; else warn "godot not on PATH yet: log out/in, or GODOT=$g ./run.sh"; w=$((w+1)); fi
  else bad "Godot $GODOT_VER (./setup.sh, or download from godotengine.org)"; miss=$((miss+1)); fi
  # GPU / Vulkan
  if have vulkaninfo; then
    local gpu; gpu="$(vulkaninfo --summary 2>/dev/null | sed -n 's/^[[:space:]]*deviceName[[:space:]]*= //p' | head -3 | paste -sd ';' -)"
    if [ -z "$gpu" ]; then bad "Vulkan device (vulkaninfo found none: check mesa-vulkan-drivers / a graphical session)"; miss=$((miss+1))
    elif printf '%s' "$gpu" | grep -qiE 'AMD|Radeon|RADV'; then ok "Vulkan GPU: $gpu"
    else warn "Vulkan GPU: $gpu (expected the AMD RX 6800 XT via RADV)"; w=$((w+1)); fi
  else bad "vulkaninfo (vulkan-tools)"; miss=$((miss+1)); fi
  # audio (intercom)
  if have pactl && pactl info >/dev/null 2>&1; then ok "audio server: $(pactl info 2>/dev/null | sed -n 's/^Server Name: //p')"
  elif have pactl; then warn "pactl can't reach a sound server (PipeWire: apt install pipewire-pulse, log out/in)"; w=$((w+1))
  else bad "pactl/parec/pacat (pulseaudio-utils): intercom off"; miss=$((miss+1)); fi
  if have espeak-ng; then ok "espeak-ng (voice callouts)"; else warn "espeak-ng missing: text banners instead of voice"; w=$((w+1)); fi
  # python
  local m
  for m in numpy PIL serial osmium; do
    if py_has "$m"; then ok "python3: import $m"
    elif [ "$m" = osmium ]; then warn "python3: no pyosmium (OSM region uses the slower Overpass API)"; w=$((w+1))
    else bad "python3: import $m"; miss=$((miss+1)); fi
  done
  if have osmium; then ok "osmium-tool"; else warn "osmium-tool missing (slower region builds)"; w=$((w+1)); fi
  # displays / touch
  if have xinput && have xrandr; then ok "xinput + xrandr (touch mapping)"; else bad "xinput / xrandr (x11-xserver-utils)"; miss=$((miss+1)); fi
  [ "${XDG_SESSION_TYPE:-x11}" = wayland ] && { warn "Wayland session: touch isolation and display mapping need X11 (Cinnamon is X11)"; w=$((w+1)); }
  # VR
  if [ "$VR" = 1 ]; then
    if have flatpak && flatpak info "$WIVRN" >/dev/null 2>&1; then ok "WiVRn (Flatpak)"; else bad "WiVRn (flatpak install --user flathub $WIVRN)"; miss=$((miss+1)); fi
    if have adb; then
      local devs; devs="$(adb devices 2>/dev/null | sed -n '2,$p' | grep -c 'device$' || true)"
      if [ "${devs:-0}" -gt 0 ]; then ok "adb sees $devs device(s) (Quest on USB)"
      else ok "adb installed (no headset on USB right now; fine over Wi-Fi)"; fi
      adb devices 2>/dev/null | grep -q unauthorized && { warn "Quest says unauthorized: put it on and accept 'Allow USB debugging'"; w=$((w+1)); }
    else bad "adb (android-tools-adb)"; miss=$((miss+1)); fi
    in_group_db plugdev || { warn "not in plugdev (adb without root)"; w=$((w+1)); }
  fi
  # panels
  if [ "$HW" = 1 ]; then
    if [ -f "$UDEV_DST" ]; then ok "panel udev rule"; else warn "panel udev rule not installed (only matters once the ESP32 boards exist)"; w=$((w+1)); fi
  fi
  # groups that need a new login
  local grp
  for grp in dialout plugdev; do
    if in_group_db "$grp" && ! id -nG | tr ' ' '\n' | grep -qx "$grp"; then NEED_RELOGIN=1; fi
  done
  # assets
  local A="$DATA/assets"
  if [ -f "$A/.fetched" ]; then ok "assets downloaded ($(du -sh "$A" 2>/dev/null | cut -f1) in $A)"
  elif [ -d "$A" ] && ls "$A"/earth_day_*.jpg >/dev/null 2>&1; then warn "assets partly downloaded: re-run game/tools/fetch_assets.sh"; w=$((w+1))
  else warn "no Earth/Moon assets yet (game uses procedural planets): ./setup.sh or game/tools/fetch_assets.sh"; w=$((w+1)); fi
  if ls "$A"/regions/*/manifest.json >/dev/null 2>&1; then
    ok "OSM region(s): $(find "$A/regions" -name manifest.json -printf '%h\n' 2>/dev/null | xargs -rn1 basename | paste -sd ' ' -)"
  else
    warn "no OSM detail region built yet"; w=$((w+1))
  fi
  # disk
  local free; free="$(df -Pk "$HOME" | awk 'NR==2{print int($4/1048576)}')"
  if [ "${free:-0}" -lt 5 ]; then warn "only ${free} GB free in $HOME (assets + caches want ~5 GB)"; w=$((w+1)); else ok "disk: ${free} GB free in $HOME"; fi

  step "Summary"
  if [ "${#FAILS[@]}" -gt 0 ]; then say "  ${R}Problems during setup:${N}"; printf '    - %s\n' "${FAILS[@]}"; fi
  say "  missing: $miss   warnings: $w"
  [ "$NEED_RELOGIN" = 1 ] && nexts+=("Log out and back in (or reboot): new group memberships (dialout/plugdev) and ~/.local/bin on PATH apply to new sessions only.")
  [ "$miss" -gt 0 ] && nexts+=("Re-run ./setup.sh (or ./setup.sh --dry-run to see what it would do).")
  nexts+=("Start the game: cd game && ./run.sh --cockpit   (or ./run.sh --dev on one screen)")
  [ "$VR" = 1 ] && nexts+=("VR: Quest 3 developer mode + WiVRn pairing: docs/game/VR_SETUP.md ('Setup on Linux Mint 22, step by step', steps 2-4).")
  local i=1 s
  for s in "${nexts[@]}"; do say "  $i. $s"; i=$((i+1)); done
  [ "$miss" = 0 ] && [ "${#FAILS[@]}" = 0 ]
}

# ---------------------------------------------------------------- main
preflight
if [ "$CHECK" = 1 ]; then doctor; exit $?; fi
[ "$DRY" = 1 ] && say "${Y}DRY RUN: nothing is installed, changed or downloaded.${N}"
plan=()
[ "$APT" = 1 ] && plan+=("apt packages")
[ "$DO_GODOT" = 1 ] && plan+=("Godot $GODOT_VER -> $GODOT_DIR")
[ "$PIP" = 1 ] && plan+=("pyosmium")
[ "$VR" = 1 ] && plan+=("WiVRn + adb")
[ "$HW" = 1 ] && plan+=("panel udev rule + dialout")
if [ "$ASSETS" = 1 ]; then
  if [ "$HD" = 1 ]; then plan+=("assets (~150 MB download, region $REGION)"); else plan+=("assets (no HD Earth, region $REGION)"); fi
fi
plan+=("then the doctor")
plan_s="$(IFS=';'; echo "${plan[*]}")"
say "Plan: ${plan_s//;/, }."
if [ "$YES" = 0 ] && [ "$DRY" = 0 ] && [ -t 0 ]; then
  read -r -p "Continue? [Y/n] " ans
  case "$ans" in n|N|no|NO) say "Nothing done."; exit 0 ;; esac
fi
[ "$APT" = 1 ] && do_apt
[ "$PIP" = 1 ] && do_python
[ "$DO_GODOT" = 1 ] && do_godot
[ "$VR" = 1 ] && do_vr
[ "$HW" = 1 ] && do_hw
[ "$DRY" = 0 ] && godot_import
[ "$ASSETS" = 1 ] && do_assets
if [ "$DRY" = 1 ]; then say; say "(The doctor below shows the CURRENT state: the dry run changed nothing.)"; doctor; exit 0; fi
doctor
