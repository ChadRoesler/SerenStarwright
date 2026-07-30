#!/usr/bin/env bash
# ==========================================================================
#  seren-workbench-setup.sh  -  one-shot SerenWorkbench installer (Linux + macOS)
#
#  The user-facing MCP/IDE — was seren-mcp (.NET), now seren-workbench on PyPI.
#  Follows the Memory/Loci pattern (template leaders).
#
#  USAGE
#    bash seren-workbench-setup.sh                  # PyPI, local-only
#    bash seren-workbench-setup.sh --service        # + autostart (sudo on linux)
#    bash seren-workbench-setup.sh --wheel ./seren_workbench-0.1.0-py3-none-any.whl
#    bash seren-workbench-setup.sh --ref v0.1.0     # pin to a GitHub release tag
#    bash seren-workbench-setup.sh --mcp            # install the [mcp] extra
#    bash seren-workbench-setup.sh --corp           # OS trust store (corp proxy)
#
#  FLAGS
#    --port N         Port to listen on            (default 7444)
#    --host HOST      Bind address                 (default 127.0.0.1)
#    --token TOKEN    Set a bearer token
#    --gen-token      Generate a random bearer token
#    --wheel PATH     Install from a local .whl
#    --ref TAG        Pin to a GitHub release tag
#    --repo SLUG      GitHub release repo
#    --service        Autostart via setup-workbench-service.sh
#    --mcp            Install the [mcp] extra
#    --corp           Route TLS through the OS trust store
#    --instance NAME  Instance name
#    --venv PATH      Override venv location
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
PORT=7444
HOST="127.0.0.1"
TOKEN=""
GEN_TOKEN=false
WHEEL=""
REF=""
REPO=""
INSTALL_SERVICE=false
MCP=false
CORP=false
INSTANCE=""
VENV_DIR="$HOME/seren-venvs/workbench"
APP_DIR="$HOME/seren-workbench"

# -- Starwright contract: identity + machine-readable metadata ----------------
# Consumed by `--describe`. flags/extras are DERIVED from the case branches
# below at runtime (see seren_flags_from_self), so adding a flag needs no edit
# here and this block can't drift from what the parser actually accepts.
SVC_NAME="seren-workbench"
SVC_DISPLAY="Seren Workbench"
SVC_DESC="The tools bench where things get done"
SVC_GROUP="core"
SVC_PACKAGE="seren-workbench"
# Card colour in Seren Starwright - matches seren_workbench/app.py viewer accent
SVC_ACCENT="#8e9aaf"

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
    --mcp)       MCP=true; shift ;;
    --corp)      CORP=true; shift ;;
    --instance)  INSTANCE="$2"; shift 2 ;;
    --venv)      VENV_DIR="$2"; shift 2 ;;
    --json)     seren_json_on; shift ;;
    --describe) seren_describe; exit 0 ;;
    -h|--help)   sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           die "unknown flag: $1  (try --help)" ;;
  esac
done

VENV_DIR="$VENV_DIR$INSTANCE"
APP_DIR="$APP_DIR$INSTANCE"
CFG_PATH="$APP_DIR/seren-workbench.yaml"
CONNECT_HOST="$HOST"; [[ "$HOST" == "0.0.0.0" ]] && CONNECT_HOST="127.0.0.1"
[[ -n "$INSTANCE" && "$PORT" == "7444" ]] && warn "Instance '$INSTANCE' using default port 7444 — may collide."

echo -e "${G}==========================================${NC}"
$IS_MAC && echo -e "${G}  SerenWorkbench setup (macOS)${NC}" || echo -e "${G}  SerenWorkbench setup (Linux)${NC}"
echo -e "${G}==========================================${NC}"

# -- 1. find Python ------------------------------------------------------------
PYBIN="$(find_python)"
[[ -n "$REF" && -z "$REPO" ]] && REPO="ChadRoesler/SerenWorkbench"
PACKAGE="seren-workbench"

# -- 2. resolve wheel ----------------------------------------------------------
resolve_wheel

# -- 3. venv + install ----------------------------------------------------------
create_venv "$VENV_DIR"
VPY="$VENV_DIR/bin/python"

# Build extras
EXTRAS_LIST=(); $MCP && EXTRAS_LIST+=("mcp"); $CORP && EXTRAS_LIST+=("corp")
EXTRAS=""; [[ ${#EXTRAS_LIST[@]} -gt 0 ]] && EXTRAS="[$(IFS=,; echo "${EXTRAS_LIST[*]}")]"
EXTRAS_DESC=""; $MCP && EXTRAS_DESC+=" + MCP SDK"; $CORP && EXTRAS_DESC+=" + truststore"
CORP_ARGS="$(pip_corp_args)"

pip_install "$VPY" "$WHEEL_SRC" "$EXTRAS" "$CORP_ARGS" "$EXTRAS_DESC"

# -- 4. sanity check -----------------------------------------------------------
sanity_check "$VPY" "seren_workbench" ""

# -- 5. config ------------------------------------------------------------------
step "Writing config at $CFG_PATH"
mkdir -p "$APP_DIR"
$GEN_TOKEN && TOKEN="$("$VPY" -c 'import secrets; print(secrets.token_urlsafe(32))')"
if [[ -f "$CFG_PATH" ]]; then
  bak="$CFG_PATH.bak.$(date +%s)"; cp "$CFG_PATH" "$bak"; warn "Existing config backed up"
fi
cat > "$CFG_PATH" <<YAML
# SerenWorkbench config - generated by seren-workbench-setup.sh
# Full reference: see seren-workbench.yaml.sample in the repo.
server:
  host: ${HOST}
  port: ${PORT}
  bearer_token: "${TOKEN}"

dashboard:
  tools_dir: ~/seren-workbench/tools
$( $CORP && printf 'tls:\n  trust_system_store: true\n' )
YAML
[[ -n "$TOKEN" ]] && chmod 600 "$CFG_PATH"
ok "Config written"

# -- 5b. launcher ---------------------------------------------------------------
write_launcher "$APP_DIR" "seren-workbench" "$VPY" "seren_workbench" "$CFG_PATH"

# -- 6. optional autostart ------------------------------------------------------
if $INSTALL_SERVICE; then
  setup_autostart "$SCRIPT_DIR" "seren-workbench" "$APP_DIR" "$TOKEN" "$INSTANCE" "$VENV_DIR"
fi

# -- done -----------------------------------------------------------------------
echo -e "${G}==========================================${NC}"
echo -e "${G}  SerenWorkbench is set up ✓${NC}"
echo -e "${G}==========================================${NC}"
if ! $INSTALL_SERVICE; then
  echo -e "  Start it:        ${B}$APP_DIR/run-seren-workbench.sh${NC}"
fi
echo -e "  Viewer:          ${B}http://${CONNECT_HOST}:${PORT}/viewer${NC}"
[[ -n "$TOKEN" ]] && echo -e "  Bearer token:    ${Y}${TOKEN}${NC}"
echo
$MCP  && echo -e "  MCP endpoint:    ${B}http://${CONNECT_HOST}:${PORT}/mcp/${NC}"
$CORP && echo -e "  TLS:             ${B}OS trust store${NC}"
echo -e "${G}Rip it and win. 🌭🔧${NC}"

# -- Starwright contract: structured completion event -------------------------
# Human banner above, machine-readable twin here. No-op without --json.
seren_emit_done "$SVC_NAME" "$CONNECT_HOST" "$PORT" "$INSTALL_SERVICE" "${TOKEN:-}"
