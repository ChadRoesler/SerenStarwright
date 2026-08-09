#!/usr/bin/env bash
# ==========================================================================
#  setup-workbench-service.sh  -  SerenWorkbench pointed wrapper
#
#  Was setup-mcp-service.sh (.NET) — renamed when mcp → workbench on PyPI.
#  Now a Python service using the shared generic core (setup-seren-service.sh).
#  Follows the Memory/Loci service-wrapper pattern.
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
    -h|--help)     sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)             echo "unknown flag: $1  (try --help)" >&2; exit 1 ;;
  esac
done

# -- identity lines ------------------------------------------------------------
SERVICE_NAME="seren-workbench$INSTANCE"
MODULE="seren_workbench"
[[ -n "$VENV_DIR" ]] || VENV_DIR="$HOME/seren-venvs/workbench$INSTANCE"
[[ -n "$APP_DIR"  ]] || APP_DIR="$HOME/seren-workbench$INSTANCE"
[[ -n "$CFG_PATH" ]] || CFG_PATH="$APP_DIR/seren-workbench.yaml"

# -- delegate to the shared generic core ----------------------------------------
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
  echo "ERROR: setup-seren-service.sh not found." >&2; exit 1
fi

exec bash "$CORE" \
  --service-name "$SERVICE_NAME" \
  --module       "$MODULE" \
  --venv         "$VENV_DIR" \
  --app-dir      "$APP_DIR" \
  --config       "$CFG_PATH" \
  --health-port  "$HEALTH_PORT" \
  --service-user "$SERVICE_USER" \
  --description  "SerenWorkbench$INSTANCE - user-facing MCP/IDE"
