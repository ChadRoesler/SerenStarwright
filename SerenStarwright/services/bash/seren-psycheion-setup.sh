#!/usr/bin/env bash
# ==========================================================================
#  seren-psycheion-setup.sh  -  one-shot SerenPsycheion installer (Linux + macOS)
#
#  Sources seren-install-lib.sh (shared installer library). The identity
#  lines and the body it watches (the robot's control API and the Soma voice
#  server) are the unique parts.
#
#  Psycheion is the mind's workshop for a Seren body: watch what it senses
#  and does, set how it behaves, make its faces. It reaches the body over
#  the body's own HTTP APIs with tokens it holds as POINTERS (a file, an env
#  var, the keychain); the browser never sees them. Loopback by default; a
#  wider bind needs a bearer or Psycheion refuses to start.
#
#  USAGE
#    bash seren-psycheion-setup.sh --pypi --service
#    bash seren-psycheion-setup.sh --root /mnt/nvme/seren/wren --instance wren --pypi \
#         --soma-config /mnt/nvme/seren/wren/apps/soma/seren-soma.yaml --service
#
#  FLAGS
#    --port N               Port to listen on            (default 7429)
#    --host HOST            Bind address                 (default 127.0.0.1)
#    --token TOKEN          Set a bearer token (needed when --host is not loopback)
#    --gen-token            Generate a random bearer token
#    --soma-config PATH     A Soma's own config on this box: the robot, the voice
#                           server and where their token files live, read from it
#    --robot-url URL        The robot's control API      (default http://192.168.0.201:8080)
#    --robot-token-file P   A file holding only the robot's control token
#    --voice-url URL        The body's voice server (Soma) (default http://127.0.0.1:7480)
#    --voice-token-file P   A file holding only the voice server's API token
#    --repo-dir PATH        SerenPsycheion repo checkout  (default: sibling ../SerenPsycheion)
#    --wheel PATH           Install from a local .whl
#    --local DIR|URL        Install from a dev wheelhouse (seren-dev-publish.sh)
#    --pypi                 Install seren-psycheion from PyPI
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
PORT=7429
HOST="127.0.0.1"
TOKEN=""
GEN_TOKEN=false
SOMA_CONFIG=""
ROBOT_URL=""
ROBOT_TOKEN_FILE=""
VOICE_URL=""
VOICE_TOKEN_FILE=""
REPO_DIR="$(find_upward "SerenPsycheion" || true)"   # sibling checkout (build source)
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
VENV_DIR="$HOME/seren-venvs/psycheion"
APP_DIR="$HOME/seren-psycheion"

# -- Starwright contract: identity + machine-readable metadata ----------------
# Consumed by `--describe`; flags are derived from the case branches below.
# seren_psycheion/_describe.py carries the same port, group and accent.
SVC_NAME="seren-psycheion"
SVC_DISPLAY="Seren Psycheion"
SVC_DESC="The mind's workshop for a Seren body: watch what it senses and does, set how it behaves"
SVC_GROUP="auxiliary"
SVC_PACKAGE="seren-psycheion"
# Brain coloured.
SVC_ACCENT="#f2aeb1"
# A body is reached over its own HTTP APIs, so a Psycheion with no body
# configured still serves its pages and says so: Soma is recommended, not required.
SVC_REQUIRES=""
SVC_RECOMMENDS="seren-soma"
SVC_EXTRAS=""
SVC_SECRETS=""
SVC_CONFIG_KEYS="robot-url=soma.robot.url robot-token-file=soma.robot.token_file voice-url=soma.voice.url voice-token-file=soma.voice.token_file"

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
    --soma-config)      SOMA_CONFIG="$2"; shift 2 ;;
    --robot-url)        ROBOT_URL="$2"; shift 2 ;;
    --robot-token-file) ROBOT_TOKEN_FILE="$2"; shift 2 ;;
    --voice-url)        VOICE_URL="$2"; shift 2 ;;
    --voice-token-file) VOICE_TOKEN_FILE="$2"; shift 2 ;;
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

seren_layout "psycheion"
CFG_PATH="$APP_DIR/seren-psycheion.yaml"
CONNECT_HOST="$HOST"
[[ "$HOST" == "0.0.0.0" ]] && CONNECT_HOST="127.0.0.1"
[[ -n "$INSTANCE" && "$PORT" == "7429" ]] && warn "Instance '$INSTANCE' uses default port 7429 - may collide."

if (exec 9<>"/dev/tcp/${CONNECT_HOST}/${PORT}") 2>/dev/null; then
  warn "Something is already answering on ${CONNECT_HOST}:${PORT}."
  warn "If that's an older SerenPsycheion, carry on - this will upgrade it."
fi

echo -e "${G}==========================================${NC}"
$IS_MAC && echo -e "${G}  SerenPsycheion setup (macOS)${NC}" || echo -e "${G}  SerenPsycheion setup (Linux)${NC}"
echo -e "${G}==========================================${NC}"

# -- 1. find Python -----------------------------------------------------------
PYBIN="$(find_python)"
[[ -n "$REF" && -z "$REPO" ]] && REPO="ChadRoesler/SerenPsycheion"

# -- 2. resolve what to install ------------------------------------------------
PACKAGE="seren-psycheion"
WHEEL_SRC=""
CLEANUP_WHEEL=false
if [[ -n "$WHEEL" ]]; then
  [[ -f "$WHEEL" ]] || die "wheel not found: $WHEEL"
  WHEEL_SRC="$WHEEL"
  ok "Installing from local wheel: $(basename "$WHEEL")"
elif [[ -n "$LOCAL" || -n "$REPO" ]]; then
  resolve_wheel
elif $USE_PYPI; then
  WHEEL_SRC="seren-psycheion"
  ok "Installing the latest seren-psycheion from PyPI"
else
  step "Building a wheel from the SerenPsycheion checkout"
  PKG_DIR="${REPO_DIR}/SerenPsycheion"
  [[ -f "${PKG_DIR}/pyproject.toml" ]] || die "SerenPsycheion checkout not found at ${PKG_DIR}
  Point --repo-dir at your SerenPsycheion repo, or use --wheel / --pypi / --ref."
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

# -- 4. sanity check (import + app factory + the viewer's page) ---------------
step "Sanity-checking the install"
CHECK="$("$VPY" - <<'PY'
import pathlib
try:
    import seren_psycheion                             # noqa: F401
    from seren_psycheion.app import create_app         # noqa: F401
except Exception as e:
    print(f"IMPORT_FAILED: {e}"); raise SystemExit
ui = pathlib.Path(seren_psycheion.__file__).parent / "viewer" / "ui"
print("OK" if any(ui.glob("*.html")) else "VIEWER_MISSING")
PY
)" || CHECK="FAILED"
case "$CHECK" in
  OK) ok "Package imports, the app factory is reachable and the viewer's page is present" ;;
  VIEWER_MISSING) warn "Installed, but the viewer's page is missing - /viewer will 500" ;;
  *) die "Install looks broken: $CHECK" ;;
esac

# -- 5. the body ---------------------------------------------------------------
# A Soma config on this box names everything: the robot's url, the voice
# server's host and port, and the state folder its two token files live in.
# Anything given by hand wins over what the file says.
if [[ -n "$SOMA_CONFIG" ]]; then
  [[ -r "$SOMA_CONFIG" ]] || die "could not read the Soma's config: $SOMA_CONFIG"
  seren_read_sibling_config "$SOMA_CONFIG" || true
  [[ -z "$VOICE_URL" && -n "$SIB_URL" ]] && VOICE_URL="$SIB_URL"
  _soma_val() { grep -m1 -E "^[[:space:]]*$1:" "$SOMA_CONFIG" | sed -E 's/^[^:]*:[[:space:]]*//; s/[[:space:]]*#.*$//; s/^["'"'"']//; s/["'"'"']$//'; }
  _soma_state="$(_soma_val state_dir)"; _soma_state="${_soma_state/#\~/$HOME}"
  # robot: is a block; its url is the first `url:` after it
  _soma_robot="$(awk '/^robot:/{f=1; next} /^[^[:space:]#]/{f=0} f && /^[[:space:]]+url:/{sub(/^[^:]*:[[:space:]]*/,""); sub(/[[:space:]]*#.*$/,""); print; exit}' "$SOMA_CONFIG")"
  [[ -z "$ROBOT_URL" && -n "$_soma_robot" ]] && ROBOT_URL="$_soma_robot"
  if [[ -n "$_soma_state" ]]; then
    [[ -z "$VOICE_TOKEN_FILE" ]] && VOICE_TOKEN_FILE="$_soma_state/token"
    [[ -z "$ROBOT_TOKEN_FILE" ]] && ROBOT_TOKEN_FILE="$_soma_state/control_token"
  fi
  ok "The body from $SOMA_CONFIG: robot ${ROBOT_URL:-?}, voice ${VOICE_URL:-?}"
fi
[[ -n "$ROBOT_URL" ]] || ROBOT_URL="http://192.168.0.201:8080"
[[ -n "$VOICE_URL" ]] || VOICE_URL="http://127.0.0.1:7480"
for f in "$ROBOT_TOKEN_FILE" "$VOICE_TOKEN_FILE"; do
  [[ -n "$f" && ! -s "${f/#\~/$HOME}" ]] && warn "Token file not there yet: $f (Psycheion reads it when it is)"
done
[[ -z "$ROBOT_TOKEN_FILE$VOICE_TOKEN_FILE" ]] && warn "No token files named: the pages will show the body but calls to it will be refused until soma.robot / soma.voice get a token pointer in $CFG_PATH."

# -- 6. config --------------------------------------------------------------
step "Writing config at $CFG_PATH"
mkdir -p "$APP_DIR"
$GEN_TOKEN && TOKEN="$("$VPY" -c 'import secrets; print(secrets.token_urlsafe(32))')"
if [[ -z "$TOKEN" ]] && ! $GEN_TOKEN; then seren_reuse_token "$CFG_PATH" || true; fi
[[ -f "$CFG_PATH" ]] && cp "$CFG_PATH" "$CFG_PATH.bak.$(date +%s)" && warn "Existing config backed up"
case "$HOST" in
  127.*|localhost|::1) ;;
  *) [[ -z "$TOKEN" ]] && warn "--host $HOST with no bearer: SerenPsycheion will REFUSE TO START. Re-run with --gen-token (or --token)." ;;
esac
cat > "$CFG_PATH" <<YAML
# SerenPsycheion config - generated by seren-psycheion-setup.sh
# Full reference: see seren-psycheion.yaml.sample in the repo.
server:
  host: ${HOST}
  port: ${PORT}
$( [[ -n "$TOKEN" ]] && printf '  bearer_token: "%s"\n' "$TOKEN" || printf '  # bearer_token_env: SEREN_PSYCHEION_TOKEN   # needed once host is not loopback\n' )

# The body. Tokens are POINTERS: token_file (a file holding only the token),
# token_env (an env var's name) or token_keyring ("service/username"). The
# browser never sees these; Psycheion makes the calls itself.
soma:
  robot:                   # the robot's control API (firmware)
    url: ${ROBOT_URL}
$( [[ -n "$ROBOT_TOKEN_FILE" ]] && printf "    token_file: '%s'\n" "$ROBOT_TOKEN_FILE" || printf '    # token_file: ~/seren-soma/state/control_token\n' )
  voice:                   # the body's voice server (Soma)
    url: ${VOICE_URL}
$( [[ -n "$VOICE_TOKEN_FILE" ]] && printf "    token_file: '%s'\n" "$VOICE_TOKEN_FILE" || printf '    # token_file: ~/seren-soma/state/token\n' )
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
write_launcher "$APP_DIR" "seren-psycheion" "$VPY" "seren_psycheion" "$CFG_PATH"

# -- 7. optional autostart ----------------------------------------------------
$INSTALL_SERVICE && setup_autostart "$SCRIPT_DIR" "seren-psycheion" "$APP_DIR" "$TOKEN" "$SVC_SUFFIX" "$VENV_DIR" "$SERVICE_USER"

# -- done -------------------------------------------------------------------
echo
echo -e "${G}==========================================${NC}"
echo -e "${G}  SerenPsycheion is set up ✓${NC}"
echo -e "${G}==========================================${NC}"
if ! $INSTALL_SERVICE; then
  echo -e "  Start it:        ${B}$APP_DIR/run-seren-psycheion.sh${NC}"
fi
echo -e "  Viewer:          ${B}http://${CONNECT_HOST}:${PORT}/viewer${NC}"
echo -e "  Health:          ${B}http://${CONNECT_HOST}:${PORT}/health${NC}"
echo -e "  The body:        ${B}robot ${ROBOT_URL}, voice ${VOICE_URL}${NC}"
[[ -n "$TOKEN" ]] && echo -e "  Bearer token:    ${Y}${TOKEN}${NC}"
echo
echo -e "  ${Y}Watch what it senses, set how it behaves. Faces come when Face Studio moves in.${NC}"
echo -e "${G}Rip it and win. 🌭🔧${NC}"

# -- Starwright contract: structured completion event -------------------------
seren_emit_done "$SVC_NAME" "$CONNECT_HOST" "$PORT" "$INSTALL_SERVICE" "${TOKEN:-}"
