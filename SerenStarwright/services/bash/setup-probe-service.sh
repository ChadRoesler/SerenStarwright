#!/usr/bin/env bash
# ==========================================================================
#  setup-probe-service.sh  -  SerenProbe pointed wrapper (Linux + macOS)
#
#  Local-only probe — no bearer token, no env-file, no env vars.
#  Follows the Margin pattern (private, localhost-only).
#
#  INSTANCE CONVENTION (mirrors seren-probe-setup.sh):
#    --instance Test suffixes everything:
#      Service:  seren-probeTest
#      Venv:     ~/seren-venvs/probeTest
#      AppDir:   ~/seren-probeTest
#      Config:   ~/seren-probeTest/seren-probe.yaml
#    Run the installer with --instance Test FIRST, then this with the same.
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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --instance)    INSTANCE="$2"; shift 2 ;;
    --venv)        VENV_DIR="$2"; shift 2 ;;
    --app-dir)     APP_DIR="$2"; shift 2 ;;
    --config)      CFG_PATH="$2"; shift 2 ;;
    --health-port) HEALTH_PORT="$2"; shift 2 ;;
    -h|--help)     sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)             echo "unknown flag: $1  (try --help)" >&2; exit 1 ;;
  esac
done

# -- the identity lines -----------------------------------------------------
SERVICE_NAME="seren-probe$INSTANCE"
MODULE="seren_probe"
[[ -n "$VENV_DIR" ]] || VENV_DIR="$HOME/seren-venvs/probe$INSTANCE"
[[ -n "$APP_DIR"  ]] || APP_DIR="$HOME/seren-probe$INSTANCE"
[[ -n "$CFG_PATH" ]] || CFG_PATH="$APP_DIR/seren-probe.yaml"

# -- delegate to the shared generic core --------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# Probe is private, localhost-only, no token:
#   --memory-max none  -> no systemd MemoryMax fence (it's tiny)
#   no --env-file      -> no secret to keep out of the unit
exec bash "$CORE" \
  --service-name "$SERVICE_NAME" \
  --module       "$MODULE" \
  --venv         "$VENV_DIR" \
  --app-dir      "$APP_DIR" \
  --config       "$CFG_PATH" \
  --health-port  "$HEALTH_PORT" \
  --memory-max   none \
  --description  "SerenProbe$INSTANCE - local health and telemetry probe"
