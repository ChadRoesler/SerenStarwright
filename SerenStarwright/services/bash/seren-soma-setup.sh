#!/usr/bin/env bash
# ==========================================================================
#  seren-soma-setup.sh  -  one-shot SerenSoma installer (Linux + macOS)
#
#  Sources seren-install-lib.sh (shared installer library). The identity
#  lines, the robot, Lodestar for hearing and speaking, and the state folder
#  the tokens live in are the unique parts.
#
#  Soma is the body's nervous system: the voice server a Stack-chan robot
#  dials into over the LAN, its ears and touch, its faces' reactions, night
#  mode and work hours. It binds 0.0.0.0 by nature (the robot is another box),
#  so it always has an API token: the one you give it, or the one it makes
#  into <state>/token the first time it runs. The robot's own control token
#  is a second secret, kept in <state>/control_token, never in the config.
#
#  USAGE
#    bash seren-soma-setup.sh --pypi --service --gen-token
#    bash seren-soma-setup.sh --root /mnt/nvme/seren/wren --instance wren --pypi \
#         --robot-url http://192.168.0.201:8080 --advertise 192.168.0.200 \
#         --lodestar-config /mnt/nvme/seren/wren/apps/lodestar/seren-lodestar.yaml --service
#
#  FLAGS
#    --port N               Port to listen on            (default 7480: where the firmware has always found it)
#    --host HOST            Bind address                 (default 0.0.0.0: the robot dials in over the LAN)
#    --token TOKEN          The API token the robot and the Workbench present
#    --gen-token            Generate a random API token (else the service makes one into <state>/token)
#    --robot-url URL        The robot's control API     (default http://192.168.0.201:8080)
#    --robot-token TOKEN    The robot's control token (CONFIG_STACKCHAN_CONTROL_TOKEN in the firmware);
#                           written to <state>/control_token, mode 600, never into the config.
#                           May arrive as SEREN_SOMA_ROBOT_TOKEN in the environment instead
#    --advertise ADDR       This box's address as the robot reaches it (default: worked out at startup)
#    --device-from IPS      Addresses the robot reaches this box from, comma-separated, when it comes
#                           through NAT or a proxy (default: the host in --robot-url; the check-in answers only them)
#    --voice NAME           The voice Lodestar speaks in (default wren)
#    --lodestar-url URL     A Lodestar for hearing and speaking
#    --lodestar-token T     Its bearer (may arrive as SEREN_LODESTAR_TOKEN)
#    --lodestar-config P    A Lodestar's own config: url AND bearer, read from the file
#    --symposium-yaml P     Or the Symposium config on this box, which names the Lodestar
#    --state-dir DIR        Tokens, what was heard, touches, settings and the log
#                           (default: the install root's stores/soma, else ~/seren-soma/state)
#    --repo-dir PATH        SerenSoma repo checkout      (default: sibling ../SerenSoma)
#    --wheel PATH           Install from a local .whl
#    --local DIR|URL        Install from a dev wheelhouse (seren-dev-publish.sh)
#    --pypi                 Install seren-soma from PyPI
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
PORT=7480
HOST="0.0.0.0"
TOKEN=""
GEN_TOKEN=false
ROBOT_URL="http://192.168.0.201:8080"
ROBOT_TOKEN=""
ADVERTISE=""
DEVICE_FROM=""
VOICE="wren"
LODE_URL=""
LODE_TOKEN=""
LODE_CONFIG=""
SYMPOSIUM_YAML=""
STATE_DIR=""
REPO_DIR="$(find_upward "SerenSoma" || true)"   # sibling checkout (build source)
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
VENV_DIR="$HOME/seren-venvs/soma"
APP_DIR="$HOME/seren-soma"

# -- Starwright contract: identity + machine-readable metadata ----------------
# Consumed by `--describe`; flags are derived from the case branches below.
# seren_soma/_describe.py carries the same port, group and accent.
SVC_NAME="seren-soma"
SVC_DISPLAY="Seren Soma"
SVC_DESC="The body's nervous system: a Stack-chan robot's voice, ears and touch"
SVC_GROUP="auxiliary"
SVC_PACKAGE="seren-soma"
# Sage: the sweater the face wears.
SVC_ACCENT="#8fbf88"
# Lodestar does the hearing and speaking; without it the body still reacts to
# touch and keeps night, so it is recommended, not required.
SVC_REQUIRES=""
SVC_RECOMMENDS="seren-lodestar"
SVC_EXTRAS=""
SVC_SECRETS="robot-token=SEREN_SOMA_ROBOT_TOKEN lodestar-token=SEREN_LODESTAR_TOKEN"
SVC_CONFIG_KEYS="robot-url=robot.url robot-token=robot.token_file device-from=robot.device_from advertise=advertise voice=voice state-dir=state_dir lodestar-url=lodestar.url lodestar-token=lodestar.token symposium-yaml=lodestar.symposium_yaml"

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
    --robot-url)   ROBOT_URL="$2"; shift 2 ;;
    --robot-token) ROBOT_TOKEN="$2"; shift 2 ;;
    --advertise) ADVERTISE="$2"; shift 2 ;;
    --device-from) DEVICE_FROM="$2"; shift 2 ;;
    --voice)     VOICE="$2"; shift 2 ;;
    --lodestar-url)    LODE_URL="$2"; shift 2 ;;
    --lodestar-token)  LODE_TOKEN="$2"; shift 2 ;;
    --lodestar-config) LODE_CONFIG="$2"; shift 2 ;;
    --symposium-yaml)  SYMPOSIUM_YAML="$2"; shift 2 ;;
    --state-dir) STATE_DIR="$2"; shift 2 ;;
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

# a secret may arrive in the environment instead (Starwright's password box)
[[ -z "$ROBOT_TOKEN" && -n "${SEREN_SOMA_ROBOT_TOKEN:-}" ]] && ROBOT_TOKEN="$SEREN_SOMA_ROBOT_TOKEN"
[[ -z "$LODE_TOKEN" && -n "${SEREN_LODESTAR_TOKEN:-}" ]] && LODE_TOKEN="$SEREN_LODESTAR_TOKEN"

seren_layout "soma"
CFG_PATH="$APP_DIR/seren-soma.yaml"
[[ -n "$STATE_DIR" ]] || STATE_DIR="${DATA_DIR:-$APP_DIR/state}"
CONNECT_HOST="$HOST"
[[ "$HOST" == "0.0.0.0" ]] && CONNECT_HOST="127.0.0.1"
[[ -n "$INSTANCE" && "$PORT" == "7480" ]] && warn "Instance '$INSTANCE' uses default port 7480 - the firmware's check-in expects that port, so a second instance needs a reflashed robot."

if (exec 9<>"/dev/tcp/${CONNECT_HOST}/${PORT}") 2>/dev/null; then
  warn "Something is already answering on ${CONNECT_HOST}:${PORT}."
  warn "If that's an older SerenSoma (or the hand-run seren_voice.py), carry on - this will replace it."
fi

echo -e "${G}==========================================${NC}"
$IS_MAC && echo -e "${G}  SerenSoma setup (macOS)${NC}" || echo -e "${G}  SerenSoma setup (Linux)${NC}"
echo -e "${G}==========================================${NC}"

# -- 1. find Python -----------------------------------------------------------
PYBIN="$(find_python)"
[[ -n "$REF" && -z "$REPO" ]] && REPO="ChadRoesler/SerenSoma"

# -- 2. resolve what to install ------------------------------------------------
# Precedence: --wheel > --local (dev wheelhouse) > --repo/--ref (GitHub) > --pypi > local build (default)
PACKAGE="seren-soma"
WHEEL_SRC=""
CLEANUP_WHEEL=false
if [[ -n "$WHEEL" ]]; then
  [[ -f "$WHEEL" ]] || die "wheel not found: $WHEEL"
  WHEEL_SRC="$WHEEL"
  ok "Installing from local wheel: $(basename "$WHEEL")"
elif [[ -n "$LOCAL" || -n "$REPO" ]]; then
  resolve_wheel
elif $USE_PYPI; then
  WHEEL_SRC="seren-soma"
  ok "Installing the latest seren-soma from PyPI"
else
  step "Building a wheel from the SerenSoma checkout"
  PKG_DIR="${REPO_DIR}/SerenSoma"
  [[ -f "${PKG_DIR}/pyproject.toml" ]] || die "SerenSoma checkout not found at ${PKG_DIR}
  Point --repo-dir at your SerenSoma repo, or use --wheel / --pypi / --ref."
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

# -- 4. sanity check (import + the viewer's page) -----------------------------
step "Sanity-checking the install"
CHECK="$("$VPY" - <<'PY'
import pathlib
try:
    import seren_soma                                  # noqa: F401
    from seren_soma import voice                       # noqa: F401
except Exception as e:
    print(f"IMPORT_FAILED: {e}"); raise SystemExit
ui = pathlib.Path(seren_soma.__file__).parent / "viewer" / "ui"
print("OK" if any(ui.glob("*.html")) else "VIEWER_MISSING")
PY
)" || CHECK="FAILED"
case "$CHECK" in
  OK) ok "Package imports and the viewer's page is present" ;;
  VIEWER_MISSING) warn "Installed, but the viewer's page is missing - the body runs without its page" ;;
  *) die "Install looks broken: $CHECK" ;;
esac

# -- 5. the Lodestar that hears and speaks -------------------------------------------
# Three ways to name it, most specific first: a Lodestar config (url and bearer
# read from the file), a url and bearer by hand, or the Symposium config on this
# box, which the service reads at startup for the same two facts.
LODE_TOKEN_LINES=""
if [[ -n "$LODE_CONFIG" ]]; then
  seren_read_sibling_config "$LODE_CONFIG" || die "could not read the Lodestar's config: $LODE_CONFIG"
  [[ -z "$LODE_URL" ]] && LODE_URL="$SIB_URL"
  # Soma's token pointers are token / token_env / token_keyring (seren_soma.config.Pointer).
  [[ -n "$SIB_TOKEN" ]]         && LODE_TOKEN_LINES="$(printf '  token: "%s"' "$SIB_TOKEN")"
  [[ -n "$SIB_TOKEN_ENV" ]]     && LODE_TOKEN_LINES="$(printf '  token_env: %s' "$SIB_TOKEN_ENV")"
  [[ -n "$SIB_TOKEN_KEYRING" ]] && LODE_TOKEN_LINES="$(printf '  token_keyring: "%s"' "$SIB_TOKEN_KEYRING")"
fi
[[ -n "$LODE_TOKEN" ]] && LODE_TOKEN_LINES="$(printf '  token: "%s"' "$LODE_TOKEN")"
if [[ -z "$SYMPOSIUM_YAML" && -z "$LODE_URL" ]]; then
  for cand in "${ROOT:+$ROOT/apps/symposium/seren-symposium.yaml}" "$HOME/seren-symposium/seren-symposium.yaml"; do
    [[ -n "$cand" && -r "$cand" ]] && { SYMPOSIUM_YAML="$cand"; break; }
  done
fi
if [[ -n "$LODE_URL" ]]; then
  ok "Hearing and speaking through the Lodestar at $LODE_URL$([[ -n "$LODE_TOKEN_LINES" ]] && echo ", with its bearer")"
elif [[ -n "$SYMPOSIUM_YAML" ]]; then
  ok "Lodestar's address and bearer will be read from $SYMPOSIUM_YAML at startup"
else
  warn "No Lodestar named: the body will react to touch and keep night, but not hear or speak."
  warn "  Add one later with --lodestar-config, or lodestar: url / token in $CFG_PATH."
fi

# -- 6. config --------------------------------------------------------------
step "Writing config at $CFG_PATH"
mkdir -p "$APP_DIR"
mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"
$GEN_TOKEN && TOKEN="$("$VPY" -c 'import secrets; print(secrets.token_urlsafe(32))')"
if [[ -z "$TOKEN" ]] && ! $GEN_TOKEN; then seren_reuse_token "$CFG_PATH" || true; fi
[[ -f "$CFG_PATH" ]] && cp "$CFG_PATH" "$CFG_PATH.bak.$(date +%s)" && warn "Existing config backed up"
# The robot's control token is a file in the state folder, mode 600: the config
# only points at it. Given once, it stays through reinstalls.
ROBOT_TOKEN_FILE="$STATE_DIR/control_token"
if [[ -n "$ROBOT_TOKEN" ]]; then
  (umask 077; printf '%s' "$ROBOT_TOKEN" > "$ROBOT_TOKEN_FILE")
  ok "The robot's control token is in $ROBOT_TOKEN_FILE (mode 600)"
elif [[ -s "$ROBOT_TOKEN_FILE" ]]; then
  ok "Keeping the robot's control token already in $ROBOT_TOKEN_FILE"
else
  warn "No robot control token: give --robot-token (or SEREN_SOMA_ROBOT_TOKEN) or write $ROBOT_TOKEN_FILE yourself; the robot refuses calls without it."
fi
cat > "$CFG_PATH" <<YAML
# SerenSoma config - generated by seren-soma-setup.sh
# Full reference: see seren-soma.yaml.sample in the repo.
server:
  host: ${HOST}
  port: ${PORT}
$( [[ -n "$TOKEN" ]] && printf '  bearer_token: "%s"\n' "$TOKEN" || printf '  # The API token: blank means the file `token` in the state folder, made the first time.\n' )

# Tokens, what was heard, touches, settings and the log. Outside any repo.
state_dir: '${STATE_DIR}'

# This box's address as the robot reaches it. Blank: the address this box uses toward the robot.
$( [[ -n "$ADVERTISE" ]] && printf 'advertise: %s\n' "$ADVERTISE" || printf '# advertise: 192.0.2.10\n' )

voice: ${VOICE}                # the voice Lodestar speaks in
idle_close_seconds: 60     # an open channel with no words this long hangs up

robot:
  url: ${ROBOT_URL}
  # Its control token (CONFIG_STACKCHAN_CONTROL_TOKEN in the firmware), a file holding only the token.
  token_file: '${ROBOT_TOKEN_FILE}'
$( [[ -n "$DEVICE_FROM" ]] && printf '  # The check-in answers only these addresses (the robot through NAT or a proxy).
  device_from: [%s]
' "$(sed 's/[[:space:]]//g; s/,/, /g' <<<"$DEVICE_FROM")" )
YAML
{
  echo
  echo "lodestar:"
  echo "  # Hearing and speaking."
  if [[ -n "$LODE_URL" ]]; then
    echo "  url: ${LODE_URL}"
    [[ -n "$LODE_TOKEN_LINES" ]] && echo "$LODE_TOKEN_LINES"
  fi
  if [[ -n "$SYMPOSIUM_YAML" ]]; then
    echo "  # Blank url: read from the Symposium config on this box."
    echo "  symposium_yaml: '${SYMPOSIUM_YAML}'"
  elif [[ -z "$LODE_URL" ]]; then
    echo "  # url: http://192.0.2.200:6361"
    echo "  # token_env: SEREN_LODESTAR_TOKEN"
  fi
} >> "$CFG_PATH"
$UPDATES_OFF && cat >> "$CFG_PATH" <<'YAML'

# Update checking turned OFF at install time by --no-updates. It never
# upgrades anything; flip to true to have the info route say when one exists.
updates:
  enabled: false
YAML
# The file always carries robot.token_file, a pointer, and often a bearer: 600, the family rule.
chmod 600 "$CFG_PATH"
ok "Config written"

# -- 6b. launcher -----------------------------------------------------------
write_launcher "$APP_DIR" "seren-soma" "$VPY" "seren_soma" "$CFG_PATH"

# -- 7. optional autostart ----------------------------------------------------
$INSTALL_SERVICE && setup_autostart "$SCRIPT_DIR" "seren-soma" "$APP_DIR" "$TOKEN" "$SVC_SUFFIX" "$VENV_DIR" "$SERVICE_USER"

# -- done -------------------------------------------------------------------
echo
echo -e "${G}==========================================${NC}"
echo -e "${G}  SerenSoma is set up ✓${NC}"
echo -e "${G}==========================================${NC}"
if ! $INSTALL_SERVICE; then
  echo -e "  Start it:        ${B}$APP_DIR/run-seren-soma.sh${NC}"
fi
echo -e "  Viewer:          ${B}http://${CONNECT_HOST}:${PORT}/viewer${NC}"
echo -e "  Health:          ${B}http://${CONNECT_HOST}:${PORT}/health${NC}"
echo -e "  The robot:       ${B}${ROBOT_URL}${NC}  (it dials back in on port ${PORT}${ADVERTISE:+ at ${ADVERTISE}})"
[[ -n "$TOKEN" ]] && echo -e "  API token:       ${Y}${TOKEN}${NC}" || echo -e "  API token:       ${B}${STATE_DIR}/token${NC} (made the first time it runs)"
echo -e "  On the robot's SD card, soma.yaml names this box as ${B}voice:${NC} and carries the same control token as ${B}token:${NC}."
echo
echo -e "  ${Y}A body you can boop. Its face, its voice and its secrets stay yours.${NC}"
echo -e "${G}Rip it and win. 🌭🔧${NC}"

# -- Starwright contract: structured completion event -------------------------
seren_emit_done "$SVC_NAME" "$CONNECT_HOST" "$PORT" "$INSTALL_SERVICE" "${TOKEN:-}"
