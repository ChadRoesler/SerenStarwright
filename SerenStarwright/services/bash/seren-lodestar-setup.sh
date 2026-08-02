#!/usr/bin/env bash
# ==========================================================================
#  seren-lodestar-setup.sh  -  one-shot SerenLodestar installer (Linux + macOS)
#
#  The cluster head / orchestrator — was seren-runtimehost (.NET), now
#  seren-lodestar on PyPI. Follows the Memory/Loci pattern (template leaders).
#
#  USAGE
#    bash seren-lodestar-setup.sh                  # PyPI, local-only
#    bash seren-lodestar-setup.sh --service        # + autostart (sudo on linux)
#    bash seren-lodestar-setup.sh --wheel ./seren_lodestar-0.1.0-py3-none-any.whl
#    bash seren-lodestar-setup.sh --ref v0.1.0     # pin to a GitHub release tag
#    bash seren-lodestar-setup.sh --mcp            # install the [mcp] extra
#    bash seren-lodestar-setup.sh --corp           # OS trust store (corp proxy)
#
#  FLAGS
#    --port N         Port to listen on            (default 6361)
#    --host HOST      Bind address                 (default 0.0.0.0)
#    --token TOKEN    Set a bearer token
#    --gen-token      Generate a random bearer token
#    --wheel PATH     Install from a local .whl
#    --ref TAG        Pin to a GitHub release tag
#    --repo SLUG      GitHub release repo
#    --service        Autostart via setup-lodestar-service.sh
#    --mcp            Install the [mcp] extra
#    --corp           Route TLS through the OS trust store
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

# -- defaults ------------------------------------------------------------------
PORT=6361
HOST="0.0.0.0"
TOKEN=""
GEN_TOKEN=false
WHEEL=""
REF=""
REPO=""
INSTALL_SERVICE=false
MCP=false
UPDATES_OFF=false
CORP=false
INSTANCE=""
VENV_DIR="$HOME/seren-venvs/lodestar"
APP_DIR="$HOME/seren-lodestar"

# -- Starwright contract: identity + machine-readable metadata ----------------
# Consumed by `--describe`. flags/extras are DERIVED from the case branches
# below at runtime (see seren_flags_from_self), so adding a flag needs no edit
# here and this block can't drift from what the parser actually accepts.
SVC_NAME="seren-lodestar"
SVC_DISPLAY="Seren Lodestar"
SVC_DESC="Management plane for nodes and orchestration"
SVC_GROUP="core"
SVC_PACKAGE="seren-lodestar"
# mcp is a CORE dependency of this package, not an extra, so the lib
# derivation (which allowlists mcp for the family) would over-report it.
SVC_EXTRAS="corp"
# Card colour in Seren Starwright - matches seren_lodestar ACCENT (light golden yellow, like butter)
SVC_ACCENT="#F5D76E"

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
    --updates)   warn "--updates is unnecessary: update checking ships on by default"; shift ;;
    --no-updates) UPDATES_OFF=true; shift ;;
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
CFG_PATH="$APP_DIR/seren-lodestar.yaml"
CONNECT_HOST="$HOST"; [[ "$HOST" == "0.0.0.0" ]] && CONNECT_HOST="127.0.0.1"
[[ -n "$INSTANCE" && "$PORT" == "6361" ]] && warn "Instance '$INSTANCE' using default port 6361 — may collide."

echo -e "${G}==========================================${NC}"
$IS_MAC && echo -e "${G}  SerenLodestar setup (macOS)${NC}" || echo -e "${G}  SerenLodestar setup (Linux)${NC}"
echo -e "${G}==========================================${NC}"

# -- 1. find Python ------------------------------------------------------------
PYBIN="$(find_python)"
[[ -n "$REF" && -z "$REPO" ]] && REPO="ChadRoesler/SerenLodestar"
PACKAGE="seren-lodestar"

# -- 2. resolve wheel ----------------------------------------------------------
resolve_wheel

# -- 3. venv + install ----------------------------------------------------------
create_venv "$VENV_DIR"
VPY="$VENV_DIR/bin/python"

# Build extras
EXTRAS_LIST=(); $CORP && EXTRAS_LIST+=("corp")
# NOTE: no "mcp" here - mcp is a CORE dependency of this package, not an
# extra. Asking pip for [mcp] just earns a "does not provide the extra"
# warning. --mcp is still accepted so existing scripts do not break.
$MCP && warn "--mcp is unnecessary: the MCP SDK is a core dependency here"
EXTRAS=""; [[ ${#EXTRAS_LIST[@]} -gt 0 ]] && EXTRAS="[$(IFS=,; echo "${EXTRAS_LIST[*]}")]"
EXTRAS_DESC=""; $CORP && EXTRAS_DESC+=" + truststore"
CORP_ARGS="$(pip_corp_args)"

pip_install "$VPY" "$WHEEL_SRC" "$EXTRAS" "$CORP_ARGS" "$EXTRAS_DESC"

# -- 4. sanity check -----------------------------------------------------------
sanity_check "$VPY" "seren_lodestar" ""

# -- 5. config ------------------------------------------------------------------
step "Writing config at $CFG_PATH"
mkdir -p "$APP_DIR"
$GEN_TOKEN && TOKEN="$("$VPY" -c 'import secrets; print(secrets.token_urlsafe(32))')"
if [[ -f "$CFG_PATH" ]]; then
  bak="$CFG_PATH.bak.$(date +%s)"; cp "$CFG_PATH" "$bak"; warn "Existing config backed up"
fi
# The cluster block is emitted COMMENTED but STRUCTURALLY COMPLETE. It used
# to be omitted entirely, which left an operator to invent the shape - and
# the obvious guess (a top-level `nodes:`) parses to zero nodes, because the
# loader reads cluster.nodes. Lodestar then starts perfectly happily as a
# cluster head with no cluster and says so only in a log warning. Shipping
# the scaffold means uncommenting beats guessing.
cat > "$CFG_PATH" <<YAML
# SerenLodestar config - generated by seren-lodestar-setup.sh
# Full reference: see seren-lodestar.yaml.sample in the repo.
server:
  host: ${HOST}
  port: ${PORT}
  bearer_token: "${TOKEN}"

# ── Cluster topology ───────────────────────────────────────────────────
# One entry per node running a SerenObservatory, INCLUDING this one.
# NOTE the nesting: nodes live under \`cluster:\`. A top-level \`nodes:\`
# is silently ignored and you get an orchestrator with nothing to talk to.
#
# Observatory listens on 7777. Verify a node before adding it:
#     curl http://<node>:7777/api/v1/system/ping
cluster:
  refresh_interval: "00:30:00"
  discovery_timeout: "00:00:02"
  nodes: []
  # nodes:
  #   - name: "${INSTANCE:-nuc}"
  #     agent_url: "http://127.0.0.1:7777"
  #     agent_token: ""
  #     is_host: true
  #     nickname: "management plane"
  #   - name: "nano8gb"
  #     agent_url: "http://192.168.1.101:7777"
  #     agent_token: ""
  #     preferred_for: ["whisper", "kokoro"]
  #     is_host: false

runtime:
  inject_bearer_token: true
$( $CORP && printf 'tls:\n  trust_system_store: true\n' )
YAML

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
[[ -n "$TOKEN" ]] && chmod 600 "$CFG_PATH"
ok "Config written"

# -- 5b. launcher ---------------------------------------------------------------
write_launcher "$APP_DIR" "seren-lodestar" "$VPY" "seren_lodestar" "$CFG_PATH"

# -- 6. optional autostart ------------------------------------------------------
if $INSTALL_SERVICE; then
  setup_autostart "$SCRIPT_DIR" "seren-lodestar" "$APP_DIR" "$TOKEN" "$INSTANCE" "$VENV_DIR"
fi

# -- done -----------------------------------------------------------------------
echo -e "${G}==========================================${NC}"
echo -e "${G}  SerenLodestar is set up ✓${NC}"
echo -e "${G}==========================================${NC}"
if ! $INSTALL_SERVICE; then
  echo -e "  Start it:        ${B}$APP_DIR/run-seren-lodestar.sh${NC}"
fi
echo -e "  Cluster head:    ${B}http://${CONNECT_HOST}:${PORT}/viewer${NC}"
[[ -n "$TOKEN" ]] && echo -e "  Bearer token:    ${Y}${TOKEN}${NC}"
echo
$MCP  && echo -e "  MCP endpoint:    ${B}http://${CONNECT_HOST}:${PORT}/mcp/${NC}"
$CORP && echo -e "  TLS:             ${B}OS trust store${NC}"
echo -e "${G}Rip it and win. 🌭🔧${NC}"

# -- Starwright contract: structured completion event -------------------------
# Human banner above, machine-readable twin here. No-op without --json.
seren_emit_done "$SVC_NAME" "$CONNECT_HOST" "$PORT" "$INSTALL_SERVICE" "${TOKEN:-}"
