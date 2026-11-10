#!/usr/bin/env bash
# ==========================================================================
#  seren-kitchen-setup.sh  -  one-shot SerenKitchen installer (Linux + macOS)
#
#  Sources seren-install-lib.sh (shared installer library). The identity
#  lines and the state folder are the unique parts: everything a house decides
#  after moving in (fonts, the GitHub token, which fridges, whose names) is set
#  from the kitchen's own page and kept in its state folder, never here.
#
#  The kitchen is the shared board of a house where a person and one or more
#  Wrens work on the same stack: a fridge per app in its own colour, magnets
#  for whoever holds a repo, and the sheets we leave each other. Its state is
#  one JSON file plus the pictures and fonts beside it. Loopback by default; a
#  wider bind needs a bearer or the kitchen refuses to start.
#
#  USAGE
#    bash seren-kitchen-setup.sh --pypi --service
#    bash seren-kitchen-setup.sh --root ~/seren/home --instance home --pypi --host 0.0.0.0 --gen-token --service
#
#  FLAGS
#    --port N               Port to listen on            (default 7431)
#    --host HOST            Bind address                 (default 127.0.0.1)
#    --token TOKEN          Set a bearer token (needed when --host is not loopback)
#    --gen-token            Generate a random bearer token
#    --state-dir DIR        Sheets, magnets, facts, pictures, fonts and settings
#                           (default: the install root's stores/kitchen, else ~/seren-kitchen/state)
#    --repo-dir PATH        SerenKitchen repo checkout    (default: sibling ../SerenKitchen)
#    --wheel PATH           Install from a local .whl
#    --local DIR|URL        Install from a dev wheelhouse (seren-dev-publish.sh)
#    --pypi                 Install seren-kitchen from PyPI (once it is there)
#    --ref TAG              Pin to a GitHub release tag
#    --repo SLUG            GitHub release repo
#    --service              Autostart via systemd/launchd
#    --instance NAME        Instance name
#    --root DIR             Install root: venvs, apps, stores, logs in one folder
#    --venv PATH            Override venv location
#    --no-updates           Turn update checking OFF in the generated config
#    -h, --help             This help
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
PORT=7431
HOST="127.0.0.1"
TOKEN=""
GEN_TOKEN=false
STATE_DIR=""
REPO_DIR="$(find_upward "SerenKitchen" || true)"   # sibling checkout (build source)
WHEEL=""
LOCAL=""
USE_PYPI=false
REF=""
REPO=""
INSTALL_SERVICE=false
SERVICE_USER=""
UPDATES_OFF=false
INSTANCE=""
ROOT=""
VENV_DIR="$HOME/seren-venvs/kitchen"
APP_DIR="$HOME/seren-kitchen"

# -- Starwright contract: identity + machine-readable metadata ----------------
# Consumed by `--describe`; flags are derived from the case branches below.
# seren_kitchen/_describe.py carries the same port, group and accent.
SVC_NAME="seren-kitchen"
SVC_DISPLAY="Seren Kitchen"
SVC_DESC="The kitchen: a fridge per Seren app, magnets for whoever holds it, and the notes we leave each other"
SVC_GROUP="auxiliary"
SVC_PACKAGE="seren-kitchen"
# Tomato: a fridge-magnet red no other app in the family wears.
SVC_ACCENT="#e0514b"
# The freezer reads GitHub over HTTP and the wall stands without it; nothing else is needed.
SVC_REQUIRES=""
SVC_RECOMMENDS=""
SVC_EXTRAS=""
# The GitHub token is pasted into the kitchen's own page and kept as a 600 file in its state: no secret on this card.
SVC_SECRETS=""
SVC_CONFIG_KEYS="state-dir=state_dir"

# --describe must answer with ZERO side effects: no venv, no network, no python.
SEREN_INSTALL_ARGV="$(printf '%s
' "$@")"     # recorded on the install record, minus secrets
for _a in "$@"; do
  [[ "$_a" == "--describe" ]] && { seren_describe; exit 0; }
done

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)      PORT="$2"; shift 2 ;;
    --host)      HOST="$2"; shift 2 ;;
    --token)     TOKEN="$2"; shift 2 ;;
    --gen-token) GEN_TOKEN=true; shift ;;
    --state-dir)        STATE_DIR="$2"; shift 2 ;;
    --repo-dir)  REPO_DIR="$2"; shift 2 ;;
    --wheel)     WHEEL="$2"; shift 2 ;;
    --local)     LOCAL="$2"; shift 2 ;;
    --pypi)      USE_PYPI=true; shift ;;
    --ref)       REF="$2"; shift 2 ;;
    --repo)      REPO="$2"; shift 2 ;;
    --service)   INSTALL_SERVICE=true; shift ;;
    --no-updates) UPDATES_OFF=true; shift ;;
    --service-user) SERVICE_USER="$2"; shift 2 ;;
    --instance)  INSTANCE="$2"; shift 2 ;;
    --root)      ROOT="$2"; shift 2 ;;
    --venv)      VENV_DIR="$2"; shift 2 ;;
    --json)      seren_json_on; shift ;;
    --describe)  seren_describe; exit 0 ;;
    -h|--help)   awk 'NR>1{ if (/^#/) { sub(/^# ?/,""); print } else exit }' "$0"; exit 0 ;;
    *)           die "unknown flag: $1  (try --help)" ;;
  esac
done

seren_layout "kitchen"
CFG_PATH="$APP_DIR/seren-kitchen.yaml"
[[ -n "$STATE_DIR" ]] || STATE_DIR="${DATA_DIR:-$APP_DIR/state}"
CONNECT_HOST="$HOST"
[[ "$HOST" == "0.0.0.0" ]] && CONNECT_HOST="127.0.0.1"
[[ -n "$INSTANCE" && "$PORT" == "7431" ]] && warn "Instance '$INSTANCE' uses default port 7431 - may collide."

if (exec 9<>"/dev/tcp/${CONNECT_HOST}/${PORT}") 2>/dev/null; then
  warn "Something is already answering on ${CONNECT_HOST}:${PORT}."
  warn "If that's an older SerenKitchen, carry on - this will upgrade it."
fi

echo -e "${G}==========================================${NC}"
$IS_MAC && echo -e "${G}  SerenKitchen setup (macOS)${NC}" || echo -e "${G}  SerenKitchen setup (Linux)${NC}"
echo -e "${G}==========================================${NC}"

# -- 1. find Python -----------------------------------------------------------
PYBIN="$(find_python)"
[[ -n "$REF" && -z "$REPO" ]] && REPO="ChadRoesler/SerenKitchen"

# -- 2. resolve what to install ------------------------------------------------
PACKAGE="seren-kitchen"
WHEEL_SRC=""
CLEANUP_WHEEL=false
if [[ -n "$WHEEL" ]]; then
  [[ -f "$WHEEL" ]] || die "wheel not found: $WHEEL"
  WHEEL_SRC="$WHEEL"
  ok "Installing from local wheel: $(basename "$WHEEL")"
elif [[ -n "$LOCAL" || -n "$REPO" ]]; then
  resolve_wheel
elif $USE_PYPI; then
  WHEEL_SRC="seren-kitchen"
  ok "Installing the latest seren-kitchen from PyPI"
else
  step "Building a wheel from the SerenKitchen checkout"
  PKG_DIR="${REPO_DIR}/SerenKitchen"
  [[ -f "${PKG_DIR}/pyproject.toml" ]] || die "SerenKitchen checkout not found at ${PKG_DIR}
  Point --repo-dir at your SerenKitchen repo (git clone it beside this one), or use --wheel / --local."
  BUILD_VENV="$(mktemp -d)/build-venv"
  "$PYBIN" -m venv "$BUILD_VENV"
  "$BUILD_VENV/bin/pip" install -q --upgrade pip build
  rm -f "${PKG_DIR}/dist/"*.whl 2>/dev/null || true
  "$BUILD_VENV/bin/python" -m build --wheel "$PKG_DIR"
  rm -rf "${BUILD_VENV%/*}"
  WHEEL_SRC="$(ls -t "${PKG_DIR}/dist/"*.whl 2>/dev/null | head -1 || true)"
  [[ -n "$WHEEL_SRC" && -f "$WHEEL_SRC" ]] || die "build completed but no wheel in ${PKG_DIR}/dist/"
  ok "Built $(basename "$WHEEL_SRC")"
fi

# -- 3. venv + install ------------------------------------------------------
create_venv "$VENV_DIR"
VPY="$VENV_DIR/bin/python"
pip_install "$VPY" "$WHEEL_SRC" "" "" ""
$CLEANUP_WHEEL && rm -f "$WHEEL_SRC"

# -- 4. sanity check (import + app factory + the page) ------------------------
step "Sanity-checking the install"
CHECK="$("$VPY" - <<'PY'
import pathlib
try:
    import seren_kitchen                             # noqa: F401
    from seren_kitchen.app import create_app         # noqa: F401
except Exception as e:
    print(f"IMPORT_FAILED: {e}"); raise SystemExit
ui = pathlib.Path(seren_kitchen.__file__).parent / "viewer" / "ui"
print("OK" if any(ui.glob("*.html")) else "VIEWER_MISSING")
PY
)" || CHECK="FAILED"
case "$CHECK" in
  OK) ok "Package imports, the app factory is reachable and the page is present" ;;
  VIEWER_MISSING) warn "Installed, but the page is missing - /viewer will 500" ;;
  *) die "Install looks broken: $CHECK" ;;
esac

# -- 5. the state folder -------------------------------------------------------
mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"
ok "Sheets, magnets, pictures, fonts and settings live in $STATE_DIR"
ok "Fonts, the GitHub token, the fridges and whose house it is are set from the page ('The house' tab) once it runs"

# -- 6. config --------------------------------------------------------------
step "Writing config at $CFG_PATH"
mkdir -p "$APP_DIR"
$GEN_TOKEN && TOKEN="$("$VPY" -c 'import secrets; print(secrets.token_urlsafe(32))')"
if [[ -z "$TOKEN" ]] && ! $GEN_TOKEN; then seren_reuse_token "$CFG_PATH" || true; fi
[[ -f "$CFG_PATH" ]] && cp "$CFG_PATH" "$CFG_PATH.bak.$(date +%s)" && warn "Existing config backed up"
LOOPBACK_ONLY=false
case "$HOST" in
  127.*|localhost|::1) LOOPBACK_ONLY=true ;;
  *) [[ -z "$TOKEN" ]] && warn "--host $HOST with no bearer: SerenKitchen will REFUSE TO START. Re-run with --gen-token (or --token)." ;;
esac
# A kitchen is a page people open from their own machines; a service bound to
# loopback is reachable from this box and nowhere else.
if $LOOPBACK_ONLY && $INSTALL_SERVICE; then
  warn "LOOPBACK ONLY: bound to ${HOST}, so the page is reachable from this box and nowhere else."
  warn "  To open it from another machine, re-run with: --host 0.0.0.0 --gen-token"
fi
cat > "$CFG_PATH" <<YAML
# SerenKitchen config - generated by seren-kitchen-setup.sh
# Full reference: see seren-kitchen.yaml.sample in the repo.
server:
  host: ${HOST}
  port: ${PORT}
$( [[ -n "$TOKEN" ]] && printf '  bearer_token: "%s"\n' "$TOKEN" || printf '  # bearer_token_env: SEREN_KITCHEN_TOKEN   # needed once host is not loopback\n' )

# Sheets, magnets, freezer facts (one JSON file), the pictures, the fonts and
# settings.json beside it. Fonts, the GitHub token, the fridges and whose house
# it is are set from the page (The house) and kept there, not in this file.
state_dir: '${STATE_DIR}'
YAML
$UPDATES_OFF && cat >> "$CFG_PATH" <<'YAML'

# Update checking turned OFF at install time by --no-updates. It never
# upgrades anything; flip to true to have the info route say when one exists.
updates:
  enabled: false
YAML
[[ -n "$TOKEN" ]] && chmod 600 "$CFG_PATH"
ok "Config written"

# -- 6b. launcher -----------------------------------------------------------
write_launcher "$APP_DIR" "seren-kitchen" "$VPY" "seren_kitchen" "$CFG_PATH"

# -- 7. optional autostart ----------------------------------------------------
$INSTALL_SERVICE && setup_autostart "$SCRIPT_DIR" "seren-kitchen" "$APP_DIR" "$TOKEN" "$SVC_SUFFIX" "$VENV_DIR" "$SERVICE_USER"

# -- done -------------------------------------------------------------------
echo
echo -e "${G}==========================================${NC}"
echo -e "${G}  SerenKitchen is set up ✓${NC}"
echo -e "${G}==========================================${NC}"
if ! $INSTALL_SERVICE; then
  echo -e "  Start it:        ${B}$APP_DIR/run-seren-kitchen.sh${NC}"
fi
echo -e "  The kitchen:     ${B}http://${CONNECT_HOST}:${PORT}/viewer${NC}"
echo -e "  Health:          ${B}http://${CONNECT_HOST}:${PORT}/health${NC}"
$LOOPBACK_ONLY && echo -e "  ${Y}Loopback only: not reachable from other machines. Re-run with --host 0.0.0.0 --gen-token to open it up.${NC}"
echo -e "  State:           ${B}${STATE_DIR}${NC}"
[[ -n "$TOKEN" ]] && echo -e "  Bearer token:    ${Y}${TOKEN}${NC}"
echo
echo -e "  ${Y}A fridge per app, and the notes we leave each other. Don't touch the cheese.${NC}"
echo -e "${G}Rip it and win. 🧀🧲${NC}"

# -- Starwright contract: structured completion event -------------------------
seren_emit_done "$SVC_NAME" "$CONNECT_HOST" "$PORT" "$INSTALL_SERVICE" "${TOKEN:-}"
