#!/usr/bin/env bash
# ==========================================================================
#  setup-hippocampus-service.sh  -  SerenHippocampus pointed wrapper (Linux + macOS)
#
#  The CONVENTION half of the generic-core / pointed-wrapper split. Knows
#  what a SerenHippocampus install looks like (dirs, instance suffix, module)
#  and hands it to setup-seren-service.sh, which does the systemd/launchd work.
#
#  INSTANCE CONVENTION (mirrors seren-hippocampus-setup.sh):
#    --instance Test suffixes everything:
#      Service:  seren-hippocampusTest
#      Venv:     ~/seren-venvs/hippocampusTest
#      AppDir:   ~/seren-hippocampusTest
#      Config:   ~/seren-hippocampusTest/seren-hippocampus.yaml
#
#  No MemoryMax fence: the hippocampus holds no store and no model; it is a
#  scheduler with an HTTP client.
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
SERVICE_USER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --instance)    INSTANCE="$2"; shift 2 ;;
    --venv)        VENV_DIR="$2"; shift 2 ;;
    --app-dir)     APP_DIR="$2"; shift 2 ;;
    --config)      CFG_PATH="$2"; shift 2 ;;
    --health-port) HEALTH_PORT="$2"; shift 2 ;;
    --service-user) SERVICE_USER="$2"; shift 2 ;;
    -h|--help)     sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)             echo "unknown flag: $1  (try --help)" >&2; exit 1 ;;
  esac
done

SERVICE_NAME="seren-hippocampus$INSTANCE"
MODULE="seren_hippocampus"
[[ -n "$VENV_DIR" ]] || VENV_DIR="$HOME/seren-venvs/hippocampus$INSTANCE"
[[ -n "$APP_DIR"  ]] || APP_DIR="$HOME/seren-hippocampus$INSTANCE"
[[ -n "$CFG_PATH" ]] || CFG_PATH="$APP_DIR/seren-hippocampus.yaml"

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
  exit 1
fi

exec bash "$CORE" \
  --service-name "$SERVICE_NAME" \
  --module       "$MODULE" \
  --venv         "$VENV_DIR" \
  --app-dir      "$APP_DIR" \
  --config       "$CFG_PATH" \
  --health-port  "$HEALTH_PORT" \
  --service-user "$SERVICE_USER" \
  --memory-max   none \
  --description  "SerenHippocampus$INSTANCE - the sleep cycle for SerenMemory"
