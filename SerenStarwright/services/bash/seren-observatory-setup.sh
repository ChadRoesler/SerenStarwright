#!/usr/bin/env bash
# ==========================================================================
#  seren-observatory-setup.sh  -  one-shot SerenObservatory installer (Linux + macOS)
#
#  The per-node management plane — was seren-agent, now seren-observatory on PyPI.
#  Follows the Memory/Loci pattern (template leaders).
#
#  USAGE
#    bash seren-observatory-setup.sh                # PyPI, local-only
#    bash seren-observatory-setup.sh --service      # + autostart (sudo on linux)
#    bash seren-observatory-setup.sh --wheel ./seren_observatory-0.1.0-py3-none-any.whl
#    bash seren-observatory-setup.sh --ref v0.1.0   # pin to a GitHub release tag
#
#  FLAGS
#    --port N         Port to listen on            (default 7777)
#    --host HOST      Bind address                 (default 0.0.0.0)
#    --token TOKEN    Set a bearer token
#    --gen-token      Generate a random bearer token
#    --wheel PATH     Install from a local .whl
#    --ref TAG        Pin to a GitHub release tag
#    --repo SLUG      GitHub release repo
#    --service        Autostart via setup-observatory-service.sh
#    --instance NAME  Instance name
#    --venv PATH      Override venv location
#    --updates        Install update-checking support ([updates] extra)
#    -h, --help       This help
# ==========================================================================
set -euo pipefail

OS="$(uname -s)"
IS_MAC=false
[[ "$OS" == "Darwin" ]] && IS_MAC=true

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; B='\033[0;34m'; NC='\033[0m'
step() { echo -e "\n${B}==>${NC} $1"; }
ok()   { echo -e "${G}  ✓${NC} $1"; }
warn() { echo -e "${Y}  !${NC} $1"; }
die()  { echo -e "${R}ERROR:${NC} $1" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -- bootstrap find_upward (needed before sourcing the lib) --------------------
find_upward() {
  local rel="$1" dir="${2:-$SCRIPT_DIR}"
  while [[ "$dir" != "/" && -n "$dir" ]]; do
    [[ -e "$dir/$rel" ]] && { echo "$dir/$rel"; return 0; }
    dir="$(dirname "$dir")"
  done
  return 1
}

# -- source the shared installer library ---------------------------------------
lib="$(find_upward "services/lib/seren-install-lib.sh" || true)"
[[ -z "$lib" ]] && die "seren-install-lib.sh not found. Keep the services/lib/ folder with the shared scripts."
source "$lib"

# -- defaults ------------------------------------------------------------------
PORT=7777
HOST="0.0.0.0"
TOKEN=""
GEN_TOKEN=false
WHEEL=""
REF=""
REPO=""
INSTALL_SERVICE=false
UPDATES=false
INSTANCE=""
VENV_DIR="$HOME/seren-venvs/observatory"
APP_DIR="$HOME/seren-observatory"

# -- Starwright contract: identity + machine-readable metadata ----------------
# Consumed by `--describe`. flags/extras are DERIVED from the case branches
# below at runtime (see seren_flags_from_self), so adding a flag needs no edit
# here and this block can't drift from what the parser actually accepts.
SVC_NAME="seren-observatory"
SVC_DISPLAY="Seren Observatory"
SVC_DESC="The insight into the node"
SVC_GROUP="core"
SVC_PACKAGE="seren-observatory"
# Card colour in Seren Starwright - matches seren_observatory/app.py viewer accent
SVC_ACCENT="#f59056"

# --describe must answer with ZERO side effects: no venv, no network, no python.
# Scanned ahead of the parse loop so no other flag can have run anything first.
for _a in "$@"; do
  [[ "$_a" == "--describe" ]] && { seren_describe; exit 0; }
done

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)      PORT="$2"; shift 2 ;;
    --host)      HOST="$2"; shift 2 ;;
    --token)     TOKEN="$2"; shift 2 ;;
    --gen-token) GEN_TOKEN=true; shift ;;
    --wheel)     WHEEL="$2"; shift 2 ;;
    --ref)       REF="$2"; shift 2 ;;
    --repo)      REPO="$2"; shift 2 ;;
    --service)   INSTALL_SERVICE=true; shift ;;
    --updates)   UPDATES=true; shift ;;
    --instance)  INSTANCE="$2"; shift 2 ;;
    --venv)      VENV_DIR="$2"; shift 2 ;;
    --json)     seren_json_on; shift ;;
    --describe) seren_describe; exit 0 ;;
    -h|--help)   awk 'NR>1{ if (/^#/) { sub(/^# ?/,""); print } else exit }' "$0"; exit 0 ;;
    *)           die "unknown flag: $1  (try --help)" ;;
  esac
done

VENV_DIR="$VENV_DIR$INSTANCE"
APP_DIR="$APP_DIR$INSTANCE"
CFG_PATH="$APP_DIR/seren-observatory.yaml"
CONNECT_HOST="$HOST"; [[ "$HOST" == "0.0.0.0" ]] && CONNECT_HOST="127.0.0.1"
[[ -n "$INSTANCE" && "$PORT" == "7777" ]] && warn "Instance '$INSTANCE' using default port 7777 — may collide."

echo -e "${G}==========================================${NC}"
$IS_MAC && echo -e "${G}  SerenObservatory setup (macOS)${NC}" || echo -e "${G}  SerenObservatory setup (Linux)${NC}"
echo -e "${G}==========================================${NC}"

# -- 1. find Python ------------------------------------------------------------
PYBIN="$(find_python)"
[[ -n "$REF" && -z "$REPO" ]] && REPO="ChadRoesler/SerenObservatory"
PACKAGE="seren-observatory"

# -- 2. resolve wheel ----------------------------------------------------------
resolve_wheel

# -- 3. venv + install ----------------------------------------------------------
create_venv "$VENV_DIR"
VPY="$VENV_DIR/bin/python"
CORP=false; MCP=false; VECTOR=false  # observatory: only [updates] applies
CORP_ARGS=""
# Build extras
EXTRAS_LIST=(); $UPDATES && EXTRAS_LIST+=("updates")
EXTRAS=""; [[ ${#EXTRAS_LIST[@]} -gt 0 ]] && EXTRAS="[$(IFS=,; echo "${EXTRAS_LIST[*]}")]"
pip_install "$VPY" "$WHEEL_SRC" "$EXTRAS" "$CORP_ARGS" ""

# -- 4. sanity check -----------------------------------------------------------
sanity_check "$VPY" "seren_observatory" ""

# -- 5. config ------------------------------------------------------------------
step "Writing config at $CFG_PATH"
mkdir -p "$APP_DIR"
$GEN_TOKEN && TOKEN="$("$VPY" -c 'import secrets; print(secrets.token_urlsafe(32))')"
if [[ -f "$CFG_PATH" ]]; then
  bak="$CFG_PATH.bak.$(date +%s)"; cp "$CFG_PATH" "$bak"; warn "Existing config backed up"
fi
cat > "$CFG_PATH" <<YAML
# SerenObservatory config - generated by seren-observatory-setup.sh
# The bearer TOKEN is NOT here — it's a safety interlock in
# ~/.seren/secrets.json (run seren-secrets.sh).
server:
  host: ${HOST}
  port: ${PORT}
YAML
[[ -n "$TOKEN" ]] && chmod 600 "$CFG_PATH"
ok "Config written"

# -- 5b. launcher ---------------------------------------------------------------
write_launcher "$APP_DIR" "seren-observatory" "$VPY" "seren_observatory" "$CFG_PATH"

# -- 6. optional autostart ------------------------------------------------------
if $INSTALL_SERVICE; then
  setup_autostart "$SCRIPT_DIR" "seren-observatory" "$APP_DIR" "$TOKEN" "$INSTANCE" "$VENV_DIR"
fi

# -- done -----------------------------------------------------------------------
echo -e "${G}==========================================${NC}"
echo -e "${G}  SerenObservatory is set up ✓${NC}"
echo -e "${G}==========================================${NC}"
if ! $INSTALL_SERVICE; then
  echo -e "  Start it:        ${B}$APP_DIR/run-seren-observatory.sh${NC}"
fi
echo -e "  Ping:            ${B}http://${CONNECT_HOST}:${PORT}/api/v1/system/ping${NC}"
[[ -n "$TOKEN" ]] && echo -e "  Bearer token:    ${Y}${TOKEN}${NC}"
echo -e "  ${Y}Token is a safety interlock: run seren-secrets.sh to write ~/.seren/secrets.json.${NC}"
echo -e "${G}Rip it and win. 🌭🔧${NC}"

# -- Starwright contract: structured completion event -------------------------
# Human banner above, machine-readable twin here. No-op without --json.
seren_emit_done "$SVC_NAME" "$CONNECT_HOST" "$PORT" "$INSTALL_SERVICE" "${TOKEN:-}"
