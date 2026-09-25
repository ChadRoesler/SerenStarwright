#!/usr/bin/env bash
# ==========================================================================
#  seren-probe-setup.sh  -  one-shot SerenProbe installer (Linux + macOS)
#
#  Memory (RAG) evaluation harness. Binds to 127.0.0.1 by default; beyond
#  loopback it wants a bearer (--token / --gen-token) or refuses to start.
#  [mcp] adds the MCP surface for a connected model; [corp] adds OS-trust-store
#  TLS for intercepting proxies.
#
#  USAGE
#    bash seren-probe-setup.sh
#    bash seren-probe-setup.sh --service --gen-token
#    bash seren-probe-setup.sh --wheel ./seren_probe-0.1.0-py3-none-any.whl
#
#  FLAGS
#    --port N         Port to listen on            (default 7430)
#    --host HOST      Bind address                 (default 127.0.0.1)
#    --token TOKEN    Set a bearer token
#    --gen-token      Generate a random bearer token
#    --mcp            Install the [mcp] extra
#    --corp           Install the [corp] extra (OS trust store)
#    --wheel PATH     Install from a local .whl
#    --local DIR|URL  Install from a dev wheelhouse (seren-dev-publish.sh)
#    --ref TAG        Pin to a GitHub release tag
#    --repo SLUG      GitHub release repo
#    --service        Autostart via systemd/launchd
#    --instance NAME  Instance name
#    --venv PATH      Override venv location
#    --no-updates     Turn update checking OFF in the generated config
#                     (it is ON by default; this never blocks install)
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

# -- defaults ---------------------------------------------------------------
PORT=7430
HOST="127.0.0.1"
TOKEN=""
GEN_TOKEN=false
WHEEL=""
LOCAL=""
REF=""
REPO=""
INSTALL_SERVICE=false
# Empty = the unit runs as whoever installs it. Only meaningful with --service.
SERVICE_USER=""
UPDATES_OFF=false
INSTANCE=""
VENV_DIR="$HOME/seren-venvs/probe"
APP_DIR="$HOME/seren-probe"
MCP=false
CORP=false

# -- Starwright contract: identity + machine-readable metadata ----------------
SVC_NAME="seren-probe"
SVC_DISPLAY="Seren Probe"
SVC_DESC="Memory (RAG) Evaluation"
SVC_GROUP="auxiliary"
SVC_PACKAGE="seren-probe"
# Card colour in Seren Starwright - matches seren_probe/app.py viewer accent
SVC_ACCENT="#8fffb4"

# --describe must answer with ZERO side effects.
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
    --local)     LOCAL="$2"; shift 2 ;;
    --ref)       REF="$2"; shift 2 ;;
    --repo)      REPO="$2"; shift 2 ;;
    --service)   INSTALL_SERVICE=true; shift ;;
    --no-updates) UPDATES_OFF=true; shift ;;
    --service-user) SERVICE_USER="$2"; shift 2 ;;
    --mcp)       MCP=true; shift ;;
    --corp)      CORP=true; shift ;;
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
CFG_PATH="$APP_DIR/seren-probe.yaml"
CONNECT_HOST="$HOST"
[[ "$HOST" == "0.0.0.0" ]] && CONNECT_HOST="127.0.0.1"
[[ -n "$INSTANCE" && "$PORT" == "7430" ]] && warn "Instance '$INSTANCE' uses default port 7430 - may collide."

echo -e "${G}==========================================${NC}"
$IS_MAC && echo -e "${G}  SerenProbe setup (macOS)${NC}" || echo -e "${G}  SerenProbe setup (Linux)${NC}"
echo -e "${G}==========================================${NC}"

# -- 1. find Python (3.10+) ----------------------------------------------------
PYBIN="$(find_python)"

[[ -n "$REF" && -z "$REPO" ]] && REPO="ChadRoesler/SerenProbe"

# -- 2. resolve wheel ----------------------------------------------------------
PACKAGE="seren-probe"
resolve_wheel

# -- 3. venv + install ---------------------------------------------------------
create_venv "$VENV_DIR"
VPY="$VENV_DIR/bin/python"
# Build extras - [mcp] and [corp] are real extras on this package.
EXTRAS_LIST=(); $MCP && EXTRAS_LIST+=("mcp"); $CORP && EXTRAS_LIST+=("corp")
EXTRAS=""; [[ ${#EXTRAS_LIST[@]} -gt 0 ]] && EXTRAS="[$(IFS=,; echo "${EXTRAS_LIST[*]}")]"
EXTRAS_DESC=""; $MCP && EXTRAS_DESC+=" + mcp"; $CORP && EXTRAS_DESC+=" + truststore"
CORP_ARGS="$(pip_corp_args)"
pip_install "$VPY" "$WHEEL_SRC" "$EXTRAS" "$CORP_ARGS" "$EXTRAS_DESC"

# -- 4. sanity check (import + the viewer fragments) --------------------------
# The dashboard is rendered from viewer/ui/*.html through the shared Meninges
# shell; there has never been a viewer/probe.html, so the old check warned on
# every single install.
sanity_check "$VPY" "seren_probe" "viewer/ui/body.html"

# -- 5. config --------------------------------------------------------------
step "Writing config at $CFG_PATH"
mkdir -p "$APP_DIR"
$GEN_TOKEN && TOKEN="$("$VPY" -c 'import secrets; print(secrets.token_urlsafe(32))')"
# A reinstall keeps the existing bearer unless --token / --gen-token say otherwise.
if [[ -z "$TOKEN" ]] && ! $GEN_TOKEN; then seren_reuse_token "$CFG_PATH" || true; fi
[[ -f "$CFG_PATH" ]] && cp "$CFG_PATH" "$CFG_PATH.bak.$(date +%s)" && warn "Existing config backed up"
# No storage block: SerenProbe keeps its topology state and results under
# ~/.seren-probe/ on its own and reads no db_path.
cat > "$CFG_PATH" <<YAML
# SerenProbe config - generated by seren-probe-setup.sh
# Full reference: see seren-probe.yaml.sample in the repo.
server:
  host: ${HOST}
  port: ${PORT}
  bearer_token: "${TOKEN}"
$( $CORP && printf 'tls:\n  trust_system_store: true\n' )
YAML
[[ -n "$TOKEN" ]] && chmod 600 "$CFG_PATH"

$UPDATES_OFF && cat >> "$CFG_PATH" <<'YAML'

# ── Update checking ───────────────────────────────────────────────────
# Turned OFF at install time by --no-updates. Update checking is on by
# default across the Seren family: it asks the package index whether a newer
# release exists and reports it on the service's info route. It NEVER
# upgrades anything. Flip this to true to turn it back on, or set
# SEREN_<SERVICE>_UPDATES_ENABLED=true in the unit file.
updates:
  enabled: false
YAML
ok "Config written"

# -- 5b. launcher -----------------------------------------------------------
write_launcher "$APP_DIR" "seren-probe" "$VPY" "seren_probe" "$CFG_PATH"

# -- 6. optional autostart ----------------------------------------------------
$INSTALL_SERVICE && setup_autostart "$SCRIPT_DIR" "seren-probe" "$APP_DIR" "$TOKEN" "$INSTANCE" "$VENV_DIR" "$SERVICE_USER"

# -- done -------------------------------------------------------------------
echo
echo -e "${G}==========================================${NC}"
echo -e "${G}  SerenProbe is set up ✓${NC}"
echo -e "${G}==========================================${NC}"
if ! $INSTALL_SERVICE; then
  echo -e "  Start it:        ${B}$APP_DIR/run-seren-probe.sh${NC}"
fi
echo -e "  Dashboard:        ${B}http://${CONNECT_HOST}:${PORT}/viewer${NC}"
echo -e "  Health:           ${B}http://${CONNECT_HOST}:${PORT}/health${NC}"
[[ -n "$TOKEN" ]] && echo -e "  Bearer token:     ${Y}${TOKEN}${NC}"
$MCP  && echo -e "  MCP endpoint:     ${B}http://${CONNECT_HOST}:${PORT}/mcp/${NC}"
$CORP && echo -e "  TLS:              ${B}OS trust store${NC}"
echo -e "${G}Rip it and win. 🌭🔧${NC}"

# -- Starwright contract: structured completion event -------------------------
seren_emit_done "$SVC_NAME" "$CONNECT_HOST" "$PORT" "$INSTALL_SERVICE" "${TOKEN:-}"
