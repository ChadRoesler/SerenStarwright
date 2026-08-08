#!/usr/bin/env bash
# ==========================================================================
#  seren-loci-setup.sh  -  one-shot SerenLoci installer (Linux + macOS)
#
#  Refactored to source seren-install-lib.sh (shared installer library).
#  Identity lines + config + --vector flag are the unique parts.
#
#  USAGE (same flags as before)
#    bash seren-loci-setup.sh
#    bash seren-loci-setup.sh --gen-token --service
#    bash seren-loci-setup.sh --wheel ./seren_loci-0.1.0-py3-none-any.whl
#    bash seren-loci-setup.sh --mcp --vector --corp
#
#  FLAGS
#    --port N         Port to listen on            (default 7422)
#    --host HOST      Bind address                 (default 127.0.0.1)
#    --token TOKEN    Set a bearer token
#    --gen-token      Generate a random bearer token
#    --wheel PATH     Install from a local .whl
#    --ref TAG        Pin to a GitHub release tag
#    --repo SLUG      GitHub release repo
#    --service        Autostart via systemd/launchd
#    --mcp            Install the [mcp] extra
#    --vector         Install the [vector] extra (sqlite-vec + sentence-transformers)
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
PORT=7422
HOST="127.0.0.1"
TOKEN=""
GEN_TOKEN=false
WHEEL=""
REF=""
REPO=""
INSTALL_SERVICE=false
# Empty = the unit runs as whoever installs it. Only meaningful with --service.
SERVICE_USER=""
MCP=false
UPDATES_OFF=false
CORP=false
VECTOR=false
INSTANCE=""
VENV_DIR="$HOME/seren-venvs/loci"
APP_DIR="$HOME/seren-loci"

# -- Starwright contract: identity + machine-readable metadata ----------------
# Consumed by `--describe`. flags/extras are DERIVED from the case branches
# below at runtime (see seren_flags_from_self), so adding a flag needs no edit
# here and this block can't drift from what the parser actually accepts.
SVC_NAME="seren-loci"
SVC_DISPLAY="Seren Loci"
SVC_DESC="Fact store for memory"
SVC_GROUP="brain"
SVC_PACKAGE="seren-loci"
# Card colour in Seren Starwright - matches seren_loci/app.py viewer accent
SVC_ACCENT="#5bc8e8"

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
    --vector)    VECTOR=true; shift ;;
    --no-updates) UPDATES_OFF=true; shift ;;
    --service-user) SERVICE_USER="$2"; shift 2 ;;
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
CFG_PATH="$APP_DIR/seren-loci.yaml"
CONNECT_HOST="$HOST"
[[ "$HOST" == "0.0.0.0" ]] && CONNECT_HOST="127.0.0.1"
[[ -n "$INSTANCE" && "$PORT" == "7422" ]] && warn "Instance '$INSTANCE' uses default port 7422 — may collide."

echo -e "${G}==========================================${NC}"
$IS_MAC && echo -e "${G}  SerenLoci setup (macOS)${NC}" || echo -e "${G}  SerenLoci setup (Linux)${NC}"
echo -e "${G}==========================================${NC}"

# -- 1. find Python (3.10-3.12; torch in [vector] needs 3.12 at most) ---------
PYBIN="$(find_python)"   # lib caps at 3.12

[[ -n "$REF" && -z "$REPO" ]] && REPO="ChadRoesler/SerenLoci"

# -- 2. resolve wheel ----------------------------------------------------------
PACKAGE="seren-loci"
resolve_wheel

# -- 3. venv + install ---------------------------------------------------------
create_venv "$VENV_DIR"
VPY="$VENV_DIR/bin/python"

# extras: mcp, corp, vector (loci's unique triple)
EXTRAS_LIST=()
$MCP    && EXTRAS_LIST+=("mcp")
$CORP   && EXTRAS_LIST+=("corp")
$VECTOR && EXTRAS_LIST+=("vector")
EXTRAS=""
[[ ${#EXTRAS_LIST[@]} -gt 0 ]] && EXTRAS="[$(IFS=,; echo "${EXTRAS_LIST[*]}")]"
CORP_ARGS="$(pip_corp_args)"
pip_install "$VPY" "$WHEEL_SRC" "$EXTRAS" "$CORP_ARGS" " (web stack$($VECTOR && echo " + sqlite-vec + sentence-transformers/torch")$($MCP && echo " + MCP SDK")$($CORP && echo " + truststore"))"

# -- 4. sanity check (import + viewer/loci.html) -----------------------------
step "Sanity-checking the install"
CHECK="$("$VPY" - <<'PY'
import pathlib
try:
    import seren_loci
except Exception as e:
    print(f"IMPORT_FAILED: {e}"); raise SystemExit
v = pathlib.Path(seren_loci.__file__).parent / "viewer" / "loci.html"
print("OK" if v.exists() else "VIEWER_MISSING")
PY
)"
case "$CHECK" in
  OK) ok "Package imports and the viewer asset is present" ;;
  VIEWER_MISSING) warn "Package installed but loci.html is missing — /viewer will 404 (wheel-packaging regression)" ;;
  *) die "Install looks broken: $CHECK" ;;
esac

# -- 5. config --------------------------------------------------------------
step "Writing config at $CFG_PATH"
mkdir -p "$APP_DIR"
$GEN_TOKEN && TOKEN="$("$VPY" -c 'import secrets; print(secrets.token_urlsafe(32))')"
[[ -f "$CFG_PATH" ]] && cp "$CFG_PATH" "$CFG_PATH.bak.$(date +%s)" && warn "Existing config backed up"
cat > "$CFG_PATH" <<YAML
# SerenLoci config - generated by seren-loci-setup.sh
# Full reference: see seren-loci.yaml.sample in the repo.
server:
  host: ${HOST}
  port: ${PORT}
  bearer_token: "${TOKEN}"

storage:
  db_path: ~/.seren-loci${INSTANCE}/loci.db
$( $VECTOR && printf '  # Vector finder ON (--vector). Comment these out for embedding-free floor.\n  embedding_model: sentence-transformers/all-MiniLM-L6-v2\n  embedding_device: cpu\n' )
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
write_launcher "$APP_DIR" "seren-loci" "$VPY" "seren_loci" "$CFG_PATH"

# -- 6. optional autostart ----------------------------------------------------
$INSTALL_SERVICE && setup_autostart "$SCRIPT_DIR" "seren-loci" "$APP_DIR" "$TOKEN" "$INSTANCE" "$VENV_DIR" "$SERVICE_USER"

# -- done -------------------------------------------------------------------
echo
echo -e "${G}==========================================${NC}"
echo -e "${G}  SerenLoci is set up ✓${NC}"
echo -e "${G}==========================================${NC}"
if ! $INSTALL_SERVICE; then
  echo -e "  Start it:        ${B}$APP_DIR/run-seren-loci.sh${NC}"
fi
echo -e "  Viewer:          ${B}http://${CONNECT_HOST}:${PORT}/viewer${NC}"
echo -e "  VSCode plugin:   set serenLoci.endpoint to ${B}http://${CONNECT_HOST}:${PORT}${NC}"
[[ -n "$TOKEN" ]] && echo -e "  Bearer token:    ${Y}${TOKEN}${NC}"
echo
$MCP    && echo -e "  MCP endpoint:    ${B}http://${CONNECT_HOST}:${PORT}/mcp/${NC}"
$VECTOR && echo -e "  Finder:          ${B}vector (sqlite-vec + all-MiniLM-L6-v2)${NC}"
$CORP   && echo -e "  TLS:             ${B}OS trust store${NC}"
echo -e "${G}Rip it and win. 🌭🔧${NC}"

# -- Starwright contract: structured completion event -------------------------
# Human banner above, machine-readable twin here. No-op without --json.
seren_emit_done "$SVC_NAME" "$CONNECT_HOST" "$PORT" "$INSTALL_SERVICE" "${TOKEN:-}"
