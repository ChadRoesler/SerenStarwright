#!/usr/bin/env bash
# ==========================================================================
#  setup-theatre-service.sh  -  SerenTheatre pointed wrapper (Linux + macOS)
#
#  The CONVENTION half of the generic-core / pointed-wrapper split. Knows
#  what a SerenTheatre install looks like (dirs, instance suffix, module) and
#  hands it to setup-seren-service.sh, which does the systemd/launchd work.
#
#  Lives alongside the core in the SerenStarwright repo.
#
#  INSTANCE CONVENTION (mirrors seren-theatre-setup.sh):
#    --instance Test suffixes everything:
#      Service:  seren-theatreTest
#      Venv:     ~/seren-venvs/theatreTest
#      AppDir:   ~/seren-theatreTest
#      Config:   ~/seren-theatreTest/seren-theatre.yaml
#    Run the installer with --instance Test FIRST, then this with the same.
#
#  No MemoryMax fence and no secret env-file, same as Margin. Theatre holds no
#  bearer token (localhost-only, read-only, nothing to authorise) and its
#  memory profile is FastAPI plus however much of a log tail it was told to
#  read - 256 KiB by default. Fencing that would be theatre of a different kind.
#
#  FLAGS
#    --instance NAME   Instance name                 (default: "")
#    --venv PATH       Override venv location
#    --app-dir PATH    Override app dir
#    --config PATH     Override config path
#    --health-port N   Override the health-check port
#    -h, --help        This help
# ==========================================================================
set -euo pipefail

INSTANCE=""
VENV_DIR=""
APP_DIR=""
CFG_PATH=""
HEALTH_PORT=0
# Empty = run as the invoking user, which is the only default that keeps ~ in
# the config resolving to the home the installer just wrote into.
SERVICE_USER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --instance)    INSTANCE="$2"; shift 2 ;;
    --venv)        VENV_DIR="$2"; shift 2 ;;
    --app-dir)     APP_DIR="$2"; shift 2 ;;
    --config)      CFG_PATH="$2"; shift 2 ;;
    --health-port) HEALTH_PORT="$2"; shift 2 ;;
    --service-user) SERVICE_USER="$2"; shift 2 ;;
    -h|--help)     sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)             echo "unknown flag: $1  (try --help)" >&2; exit 1 ;;
  esac
done

# -- the identity lines (the whole point of this wrapper) ---------------------
SERVICE_NAME="seren-theatre$INSTANCE"
MODULE="seren_theatre"
[[ -n "$VENV_DIR" ]] || VENV_DIR="$HOME/seren-venvs/theatre$INSTANCE"
[[ -n "$APP_DIR"  ]] || APP_DIR="$HOME/seren-theatre$INSTANCE"
[[ -n "$CFG_PATH" ]] || CFG_PATH="$APP_DIR/seren-theatre.yaml"

# -- delegate to the shared generic core --------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -- locate a file by walking UP the tree (reorg-robust; injected by fixup) ---
# Survives the services/{bash,powershell,lib} split AND any future reorg - we never
# hardcode a relative hop, we search upward for the target.
find_upward() {
  local rel="$1" dir="${2:-$SCRIPT_DIR}"
  while [[ "$dir" != "/" && -n "$dir" ]]; do
    [[ -e "$dir/$rel" ]] && { echo "$dir/$rel"; return 0; }
    dir="$(dirname "$dir")"
  done
  return 1
}

CORE="$(find_upward "services/lib/setup-seren-service.sh")"
if [[ ! -f "$CORE" ]]; then
  echo "ERROR: setup-seren-service.sh not found walking up from this script ($SCRIPT_DIR)." >&2
  echo "       The wrapper is just conventions - the core does the work. Keep the shared scripts together." >&2
  exit 1
fi

# Theatre is read-only, localhost-only, no token:
#   --memory-max none  -> no systemd MemoryMax fence (FastAPI + a log tail)
#   no --env-file      -> no secret to keep out of the unit
exec bash "$CORE" \
  --service-name "$SERVICE_NAME" \
  --module       "$MODULE" \
  --venv         "$VENV_DIR" \
  --app-dir      "$APP_DIR" \
  --config       "$CFG_PATH" \
  --health-port  "$HEALTH_PORT" \
  --service-user "$SERVICE_USER" \
  --memory-max   none \
  --description  "SerenTheatre$INSTANCE - watch a model being made"
