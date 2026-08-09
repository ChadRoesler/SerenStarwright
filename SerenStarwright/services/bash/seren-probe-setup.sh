#!/usr/bin/env bash
# ==========================================================================
#  seren-probe-setup.sh  -  one-shot SerenProbe installer (Linux + macOS)
#
#  Local-only memory (RAG) Evaluation probe. No MCP, no TLS, no bearer token —
#  it's a private infra tool that only binds to 127.0.0.1.
#
#  USAGE
#    bash seren-probe-setup.sh
#    bash seren-probe-setup.sh --service
#    bash seren-probe-setup.sh --wheel ./seren_probe-0.1.0-py3-none-any.whl
#
#  FLAGS
#    --port N         Port to listen on            (default 7430)
#    --host HOST      Bind address                 (default 127.0.0.1)
#    --wheel PATH     Install from a local .whl
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
WHEEL=""
REF=""
REPO=""
INSTALL_SERVICE=false
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
# Card colour in Seren Starwright - no viewer yet; green picked for the installer only
SVC_ACCENT="#7fd88f"

# --describe must answer with ZERO side effects.
for _a in "$@"; do
  [[ "$_a" == "--describe" ]] && { seren_describe; exit 0; }
done

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)      PORT="$2"; shift 2 ;;
    --host)      HOST="$2"; shift 2 ;;
    --wheel)     WHEEL="$2"; shift 2 ;;
    --ref)       REF="$2"; shift 2 ;;
    --repo)      REPO="$2"; shift 2 ;;
    --service)   INSTALL_SERVICE=true; shift ;;
    --updates)   warn "--updates is unnecessary: update checking ships on by default"; shift ;;
    --no-updates) UPDATES_OFF=true; shift ;;
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
[[ -n "$INSTANCE" && "$PORT" == "7430" ]] && warn "Instance '$INSTANCE' uses default port 7430 — may collide."

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
CORP_ARGS=""
# no extras — local only
# Build extras
EXTRAS_LIST=(); $MCP && EXTRAS_LIST+=("mcp"); $CORP && EXTRAS_LIST+=("corp")
EXTRAS=""; [[ ${#EXTRAS_LIST[@]} -gt 0 ]] && EXTRAS="[$(IFS=,; echo "${EXTRAS_LIST[*]}")]"
pip_install "$VPY" "$WHEEL_SRC" "$EXTRAS" "$CORP_ARGS" ""

# -- 4. sanity check (import + viewer/probe.html) -----------------------------
step "Sanity-checking the install"
CHECK="$("$VPY" - <<'PY'
import pathlib
try:
    import seren_probe
except Exception as e:
    print(f"IMPORT_FAILED: {e}"); raise SystemExit
v = pathlib.Path(seren_probe.__file__).parent / "viewer" / "probe.html"
print("OK" if v.exists() else "VIEWER_MISSING")
PY
)"
case "$CHECK" in
  OK) ok "Package imports and the viewer asset is present" ;;
  VIEWER_MISSING) warn "Package installed but probe.html is missing — /viewer will 404 (wheel-packaging regression)" ;;
  *) die "Install looks broken: $CHECK" ;;
esac

# -- 5. config --------------------------------------------------------------
step "Writing config at $CFG_PATH"
mkdir -p "$APP_DIR"
[[ -f "$CFG_PATH" ]] && cp "$CFG_PATH" "$CFG_PATH.bak.$(date +%s)" && warn "Existing config backed up"
cat > "$CFG_PATH" <<YAML
# SerenProbe config - generated by seren-probe-setup.sh
# Full reference: see seren-probe.yaml.sample in the repo.
server:
  host: ${HOST}
  port: ${PORT}

storage:
  db_path: ~/.seren-probe${INSTANCE}/probe.db
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
ok "Config written"

# -- 5b. launcher -----------------------------------------------------------
write_launcher "$APP_DIR" "seren-probe" "$VPY" "seren_probe" "$CFG_PATH"

# -- 6. optional autostart ----------------------------------------------------
$INSTALL_SERVICE && setup_autostart "$SCRIPT_DIR" "seren-probe" "$APP_DIR" "" "$INSTANCE" "$VENV_DIR"

# -- done -------------------------------------------------------------------
echo
echo -e "${G}==========================================${NC}"
echo -e "${G}  SerenProbe is set up ✓${NC}"
echo -e "${G}==========================================${NC}"
if ! $INSTALL_SERVICE; then
  echo -e "  Start it:        ${B}$APP_DIR/run-seren-probe.sh${NC}"
fi
echo -e "  Dashboard:        ${B}http://${CONNECT_HOST}:${PORT}/probe${NC}"
echo -e "  Health:           ${B}http://${CONNECT_HOST}:${PORT}/health${NC}"
echo -e "${G}Rip it and win. 🌭🔧${NC}"

# -- Starwright contract: structured completion event -------------------------
seren_emit_done "$SVC_NAME" "$CONNECT_HOST" "$PORT" "$INSTALL_SERVICE" ""
