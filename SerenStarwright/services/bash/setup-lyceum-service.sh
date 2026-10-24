#!/usr/bin/env bash
# ==========================================================================
#  setup-lyceum-service.sh  -  SerenLyceum pointed wrapper (Linux + macOS)
#
#  The CONVENTION half of the generic-core / pointed-wrapper split. Knows
#  what a SerenLyceum install looks like (dirs, instance suffix, module) and
#  hands it to setup-seren-service.sh, which does the systemd/launchd work.
#
#  INSTANCE CONVENTION (mirrors seren-lyceum-setup.sh):
#    --instance Test suffixes everything:
#      Service:  seren-lyceumTest
#      Venv:     ~/seren-venvs/lyceumTest
#      AppDir:   ~/seren-lyceumTest
#      Config:   ~/seren-lyceumTest/seren-lyceum.yaml
#    Under an install root the card passes --app-dir and --venv, and the
#    instance arrives as "-wren": seren-lyceum-wren.
#
#  KillMode=process: the service forks the trainer, detached, into the same
#  cgroup. systemd's default stops the whole cgroup, so restarting the
#  service (an upgrade, a config change) would kill a run mid-epoch. With
#  process only the service stops; the runner finds the trainer again by its
#  pid when it comes back.
#
#  No MemoryMax either: the service is small, but MemoryMax applies to the
#  cgroup, and the trainer in it holds a model.
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
    -h|--help)     awk 'NR>1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"; exit 0 ;;
    *)             echo "unknown flag: $1  (try --help)" >&2; exit 1 ;;
  esac
done

SERVICE_NAME="seren-lyceum$INSTANCE"
MODULE="seren_lyceum"
[[ -n "$VENV_DIR" ]] || VENV_DIR="$HOME/seren-venvs/lyceum$INSTANCE"
[[ -n "$APP_DIR"  ]] || APP_DIR="$HOME/seren-lyceum$INSTANCE"
[[ -n "$CFG_PATH" ]] || CFG_PATH="$APP_DIR/seren-lyceum.yaml"

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

ENV_FILE="$APP_DIR/seren-lyceum.env"

exec bash "$CORE" \
  --service-name "$SERVICE_NAME" \
  --module       "$MODULE" \
  --venv         "$VENV_DIR" \
  --app-dir      "$APP_DIR" \
  --config       "$CFG_PATH" \
  --env-file     "$ENV_FILE" \
  --env          PYTHONUTF8=1 \
  --health-port  "$HEALTH_PORT" \
  --service-user "$SERVICE_USER" \
  --memory-max   none \
  --kill-mode    process \
  --description  "SerenLyceum$INSTANCE - train a model: a dataset in, a model out"
