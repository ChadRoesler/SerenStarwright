#!/usr/bin/env bash
# ==========================================================================
#  seren-memory-setup.sh  -  one-shot SerenMemory installer (Linux + macOS)
#
#  Refactored to source seren-install-lib.sh (shared installer library).
#  Identity lines + config are the only unique parts.
#
#  USAGE (same flags as before)
#    bash seren-memory-setup.sh
#    bash seren-memory-setup.sh --gen-token --service
#    bash seren-memory-setup.sh --wheel ./seren_memory-0.1.0-py3-none-any.whl
#    bash seren-memory-setup.sh --mcp --corp
#
#  FLAGS
#    --port N         Port to listen on            (default 7420)
#    --host HOST      Bind address                 (default 127.0.0.1)
#    --token TOKEN    Set a bearer token
#    --gen-token      Generate a random bearer token
#    --wheel PATH     Install from a local .whl
#    --ref TAG        Pin to a GitHub release tag
#    --repo SLUG      GitHub release repo
#    --service        Autostart via systemd/launchd
#    --mcp            Install the [mcp] extra
#    --corp           Route TLS through OS trust store
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
PORT=7420
HOST="127.0.0.1"
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
VENV_DIR="$HOME/seren-venvs/memory"
APP_DIR="$HOME/seren-memory"

# -- Starwright contract: identity + machine-readable metadata ----------------
# Consumed by `--describe`. flags/extras are DERIVED from the case branches
# below at runtime (see seren_flags_from_self), so adding a flag needs no edit
# here and this block can't drift from what the parser actually accepts.
SVC_NAME="seren-memory"
SVC_DISPLAY="Seren Memory"
SVC_DESC="Episodic short, near, and long term memory"
SVC_GROUP="brain"
SVC_PACKAGE="seren-memory"
# Card colour in Seren Starwright - matches seren_memory/app.py viewer accent
SVC_ACCENT="#ff6e8a"

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
CFG_PATH="$APP_DIR/seren-memory.yaml"
CONNECT_HOST="$HOST"
[[ "$HOST" == "0.0.0.0" ]] && CONNECT_HOST="127.0.0.1"
[[ -n "$INSTANCE" && "$PORT" == "7420" ]] && warn "Instance '$INSTANCE' uses default port 7420 — may collide."

echo -e "${G}==========================================${NC}"
$IS_MAC && echo -e "${G}  SerenMemory setup (macOS)${NC}" || echo -e "${G}  SerenMemory setup (Linux)${NC}"
echo -e "${G}==========================================${NC}"

# -- 1. find Python (3.10-3.12; chromadb can't build on 3.13) ------------------
PYBIN="$(find_python)"   # lib's find_python caps at 3.12 by default — good here

[[ -n "$REF" && -z "$REPO" ]] && REPO="ChadRoesler/SerenMemory"

# -- 2. resolve wheel ----------------------------------------------------------
PACKAGE="seren-memory"
resolve_wheel

# -- 3. venv + install ---------------------------------------------------------
create_venv "$VENV_DIR"
VPY="$VENV_DIR/bin/python"

# extras
EXTRAS_LIST=()
$MCP  && EXTRAS_LIST+=("mcp")
$CORP && EXTRAS_LIST+=("corp")
EXTRAS=""
[[ ${#EXTRAS_LIST[@]} -gt 0 ]] && EXTRAS="[$(IFS=,; echo "${EXTRAS_LIST[*]}")]"
CORP_ARGS="$(pip_corp_args)"
pip_install "$VPY" "$WHEEL_SRC" "$EXTRAS" "$CORP_ARGS" " (chromadb$($MCP && echo " + MCP SDK")$($CORP && echo " + truststore"))"

# -- 4. sanity check (import + viewer/halls.html) -----------------------------
step "Sanity-checking the install"
CHECK="$("$VPY" - <<'PY'
import pathlib
try:
    import seren_memory
except Exception as e:
    print(f"IMPORT_FAILED: {e}"); raise SystemExit
v = pathlib.Path(seren_memory.__file__).parent / "viewer" / "halls.html"
print("OK" if v.exists() else "VIEWER_MISSING")
PY
)"
case "$CHECK" in
  OK) ok "Package imports and the Halls viewer asset is present" ;;
  VIEWER_MISSING) warn "Package installed but halls.html is missing — /viewer will 404 (wheel-packaging regression)" ;;
  *) die "Install looks broken: $CHECK" ;;
esac

# -- 5. config --------------------------------------------------------------
step "Writing config at $CFG_PATH"
mkdir -p "$APP_DIR"
$GEN_TOKEN && TOKEN="$("$VPY" -c 'import secrets; print(secrets.token_urlsafe(32))')"
[[ -f "$CFG_PATH" ]] && cp "$CFG_PATH" "$CFG_PATH.bak.$(date +%s)" && warn "Existing config backed up"
cat > "$CFG_PATH" <<YAML
# SerenMemory config - generated by seren-memory-setup.sh
# Full reference: see seren-memory.yaml.sample in the repo.
server:
  host: ${HOST}
  port: ${PORT}
  bearer_token: "${TOKEN}"

storage:
  persist_dir: ~/.seren-memory${INSTANCE}/chroma
$( $CORP && printf '\ntls:\n  trust_system_store: true\n' )
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

# -- 5b. launcher -----------------------------------------------------------
write_launcher "$APP_DIR" "seren-memory" "$VPY" "seren_memory" "$CFG_PATH"

# -- 6. optional autostart ----------------------------------------------------
$INSTALL_SERVICE && setup_autostart "$SCRIPT_DIR" "seren-memory" "$APP_DIR" "$TOKEN" "$INSTANCE" "$VENV_DIR"

# -- done -------------------------------------------------------------------
echo
echo -e "${G}==========================================${NC}"
echo -e "${G}  SerenMemory is set up ✓${NC}"
echo -e "${G}==========================================${NC}"
if ! $INSTALL_SERVICE; then
  echo -e "  Start it:        ${B}$APP_DIR/run-seren-memory.sh${NC}"
fi
echo -e "  Viewer:          ${B}http://${CONNECT_HOST}:${PORT}/viewer${NC}"
echo -e "  VSCode plugin:   set serenMemory.endpoint to ${B}http://${CONNECT_HOST}:${PORT}${NC}"
[[ -n "$TOKEN" ]] && echo -e "  Bearer token:    ${Y}${TOKEN}${NC}"
echo
$MCP  && echo -e "  MCP endpoint:    ${B}http://${CONNECT_HOST}:${PORT}/mcp/${NC}"
$CORP && echo -e "  TLS:             ${B}OS trust store${NC}"
echo -e "${G}Rip it and win. 🌭🔧${NC}"

# -- Starwright contract: structured completion event -------------------------
# Human banner above, machine-readable twin here. No-op without --json.
seren_emit_done "$SVC_NAME" "$CONNECT_HOST" "$PORT" "$INSTALL_SERVICE" "${TOKEN:-}"
