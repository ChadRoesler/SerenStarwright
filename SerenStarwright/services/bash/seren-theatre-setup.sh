#!/usr/bin/env bash
# ==========================================================================
#  seren-theatre-setup.sh  -  one-shot SerenTheatre installer (Linux + macOS)
#
#  Sources seren-install-lib.sh (shared installer library). Identity lines,
#  config, the --stage convenience and the local-build-from-repo default are
#  the unique parts.
#
#  Theatre is the closest sibling to Margin: localhost-only, no bearer token,
#  no MCP surface, requires nothing. The one thing it has that Margin doesn't
#  is a STAGE - a directory to watch - and --stage writes it into the config
#  so a fresh install lands on something real instead of an empty room.
#
#  USAGE
#    bash seren-theatre-setup.sh                    # build from repo, local-only
#    bash seren-theatre-setup.sh --service          # + autostart
#    bash seren-theatre-setup.sh --stage /mnt/nvme/fraunkensteinLab
#    bash seren-theatre-setup.sh --wheel ./seren_theatre-0.1.0-py3-none-any.whl
#    bash seren-theatre-setup.sh --pypi             # once published
#
#  FLAGS
#    --port N         Port to listen on            (default 7427)
#    --host HOST      Bind address                 (default 127.0.0.1)
#    --stage PATH     A directory to watch; repeatable. Written into the
#                     generated config as a stages: entry.
#    --repo-dir PATH  SerenTheatre repo checkout   (default: sibling ../SerenTheatre)
#    --wheel PATH     Install from a local .whl
#    --pypi           Install seren-theatre from PyPI
#    --ref TAG        Pin to a GitHub release tag
#    --repo SLUG      GitHub release repo
#    --service        Autostart via systemd/launchd
#    --stagehand      Install the [stagehand] extra (pulls the ms-moe CLI, so
#                     this box can START builds, not just watch them)
#    --instance NAME  Instance name
#    --venv PATH      Override venv location
#    --no-updates     Turn update checking OFF in the generated config
#                     (it is ON by default; this never blocks install)
#    -h, --help       This help
#
#  ON THE PORT: 7427, not 7426. 7426 belongs to SerenSymposium's loopback UI
#  shim. Symposium is localhost-only so it isn't in the `seren/port-map` fact,
#  which is exactly why the first pick collided with it. See the long note in
#  seren_theatre/_describe.py.
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
PORT=7427
HOST="127.0.0.1"
REPO_DIR="$(find_upward "SerenTheatre" || true)"   # sibling checkout (build source)
WHEEL=""
USE_PYPI=false
REF=""
REPO=""
INSTALL_SERVICE=false
STAGEHAND=false
# Empty = the unit runs as whoever installs it. Only meaningful with --service.
SERVICE_USER=""
UPDATES_OFF=false
INSTANCE=""
VENV_DIR="$HOME/seren-venvs/theatre"
APP_DIR="$HOME/seren-theatre"
STAGES=()

# -- Starwright contract: identity + machine-readable metadata ----------------
# Consumed by `--describe`. flags/extras are DERIVED from the case branches
# below at runtime (see seren_flags_from_self), so adding a flag needs no edit
# here and this block can't drift from what the parser actually accepts.
#
# THIS IS THE ONLY --describe THAT ANYTHING READS. Starwright builds its grid by
# running --describe on the installers, and the SerenTheatre package deliberately
# does not depend on this repo or look for it - so nothing cross-checks these
# values automatically. Port, accent and description also appear in
# seren_theatre/_describe.py; if you change one here, change it there by hand.
SVC_NAME="seren-theatre"
SVC_DISPLAY="Seren Theatre"
SVC_DESC="Watch a model being made. Read-only viewer over training logs and artifacts."
SVC_GROUP="auxiliary"
SVC_PACKAGE="seren-theatre"
# Every other service in the constellation gets a colour. The theatre gets the
# house lights down.
SVC_ACCENT="#171717"
# Requires NOTHING, deliberately. A stage is a directory, so Theatre can be the
# first thing installed on a box and still be useful.
SVC_REQUIRES=""
# EXPLICIT, and it has to be. seren_describe derives extras by filtering the
# parsed flags through a family-wide allowlist of mcp|corp|vector - which is
# correct for the eight services that shipped before this one and structurally
# cannot know about a new extra. Left to derive, --describe would advertise
# extras:[] while --stagehand quietly worked, so Starwright would never offer
# the checkbox for a thing the installer supports. Overriding is the documented
# escape hatch (lodestar and workbench use it for the opposite reason).
SVC_EXTRAS="stagehand"

# --describe must answer with ZERO side effects: no venv, no network, no python.
# Scanned ahead of the parse loop so no other flag can have run anything first.
for _a in "$@"; do
  [[ "$_a" == "--describe" ]] && { seren_describe; exit 0; }
done

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)      PORT="$2"; shift 2 ;;
    --host)      HOST="$2"; shift 2 ;;
    --stage)     STAGES+=("$2"); shift 2 ;;
    --repo-dir)  REPO_DIR="$2"; shift 2 ;;
    --wheel)     WHEEL="$2"; shift 2 ;;
    --pypi)      USE_PYPI=true; shift ;;
    --ref)       REF="$2"; shift 2 ;;
    --repo)      REPO="$2"; shift 2 ;;
    --service)   INSTALL_SERVICE=true; shift ;;
    --stagehand) STAGEHAND=true; shift ;;
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
CFG_PATH="$APP_DIR/seren-theatre.yaml"
CONNECT_HOST="$HOST"
[[ "$HOST" == "0.0.0.0" ]] && CONNECT_HOST="127.0.0.1"
[[ -n "$INSTANCE" && "$PORT" == "7427" ]] && warn "Instance '$INSTANCE' uses default port 7427 — may collide."

# -- 0. preflight: is anyone already sitting in this seat? ---------------------
# Cheap, non-fatal, and the guard that would have caught 7426. It does NOT scan
# ports - it asks about exactly the one port we are about to take, which is the
# only one we have any business knowing about. A live answer here means either
# an existing Theatre (fine, we're upgrading) or something else already bound
# (not fine, and much easier to hear about now than after the unit fails).
if (exec 3<>"/dev/tcp/${CONNECT_HOST}/${PORT}") 2>/dev/null; then
  exec 3<&- 2>/dev/null || true
  warn "Something is already answering on ${CONNECT_HOST}:${PORT}."
  warn "If that's an older SerenTheatre, carry on - this will upgrade it."
  warn "If it isn't, stop and pick another port with --port; 7426 is Symposium's."
fi

echo -e "${G}==========================================${NC}"
$IS_MAC && echo -e "${G}  SerenTheatre setup (macOS)${NC}" || echo -e "${G}  SerenTheatre setup (Linux)${NC}"
echo -e "${G}==========================================${NC}"

# -- 1. find Python -----------------------------------------------------------
PYBIN="$(find_python)"
[[ -n "$REF" && -z "$REPO" ]] && REPO="ChadRoesler/SerenTheatre"

# -- 2. resolve what to install ------------------------------------------------
# Precedence: --wheel > --repo/--ref (GitHub) > --pypi > local build (default)
PACKAGE="seren-theatre"
WHEEL_SRC=""
CLEANUP_WHEEL=false
if [[ -n "$WHEEL" ]]; then
  [[ -f "$WHEEL" ]] || die "wheel not found: $WHEEL"
  WHEEL_SRC="$WHEEL"
  ok "Installing from local wheel: $(basename "$WHEEL")"
elif [[ -n "$REPO" ]]; then
  resolve_wheel
elif $USE_PYPI; then
  WHEEL_SRC="seren-theatre"
  ok "Installing the latest seren-theatre from PyPI"
else
  # DEFAULT: build a wheel from the repo checkout. Theatre isn't on PyPI yet.
  step "Building a wheel from the SerenTheatre checkout"
  PKG_DIR="${REPO_DIR}/SerenTheatre"
  [[ -f "${PKG_DIR}/pyproject.toml" ]] || die "SerenTheatre checkout not found at ${PKG_DIR}
  Point --repo-dir at your SerenTheatre repo, or use --wheel / --pypi / --ref."
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

# No [mcp]: Theatre reads files off disk and has deliberately no write path to
# expose one over. [stagehand] is the ONE extra, and it is opt-in on purpose -
# watching a run has never required being able to start one, so a plain install
# stays a viewer and nothing more.
EXTRAS=""
$STAGEHAND && EXTRAS="[stagehand]"
pip_install "$VPY" "$WHEEL_SRC" "$EXTRAS" "" \
  "$($STAGEHAND && echo ' + the ms-moe CLI')"
$CLEANUP_WHEEL && rm -f "$WHEEL_SRC"

# -- 4. sanity check ---------------------------------------------------------
# NOT the shared sanity_check(): that one looks for a module/viewer/<asset>
# file, and Theatre generates /viewer as HTML in app.py with no asset dir on
# disk. Checking for a file that was never meant to exist would warn on a
# perfectly good install, and a warning that fires on working software teaches
# people to ignore warnings.
#
# What IS invariant: the package imports, the app factory is reachable, and
# --describe answers. Those three are true by construction of a good install
# and false for every broken one.
step "Sanity-checking the install"
CHECK="$("$VPY" - <<'PY'
try:
    import seren_theatre
    from seren_theatre.app import create_app          # noqa: F401
    from seren_theatre._describe import DESCRIBE
except Exception as e:
    print(f"IMPORT_FAILED: {e}"); raise SystemExit
missing = [k for k in ("name", "port", "group", "accent") if k not in DESCRIBE]
print("DESCRIBE_INCOMPLETE: " + ",".join(missing) if missing else "OK")
PY
)" || CHECK="FAILED"
case "$CHECK" in
  OK) ok "Package imports, the app factory is reachable and --describe answers" ;;
  DESCRIBE_INCOMPLETE*) warn "Installed but $CHECK — Starwright's grid will show gaps" ;;
  *) die "Install looks broken: $CHECK" ;;
esac

# -- 5. config --------------------------------------------------------------
step "Writing config at $CFG_PATH"
mkdir -p "$APP_DIR"
[[ -f "$CFG_PATH" ]] && cp "$CFG_PATH" "$CFG_PATH.bak.$(date +%s)" && warn "Existing config backed up"
cat > "$CFG_PATH" <<YAML
# SerenTheatre config - generated by seren-theatre-setup.sh
# Full reference: see seren-theatre.yaml.sample in the repo.
server:
  # 127.0.0.1 on purpose. Training logs carry absolute paths, hostnames and the
  # occasional corpus snippet - not something to put on the LAN by accident.
  host: ${HOST}
  port: ${PORT}

# Only the tail of each log is ever read. The dashboard must never be the
# reason the box is busy.
tail_bytes: 262144
refresh_seconds: 5
YAML

if [[ ${#STAGES[@]} -gt 0 ]]; then
  {
    echo
    echo "stages:"
    for s in "${STAGES[@]}"; do
      echo "  - name: $(basename "$s")"
      echo "    path: ${s}"
      echo "    logs: [\"*.log\"]"
      echo "    rungs: [\"dryrun_*\", \"*_agent_*\"]"
    done
  } >> "$CFG_PATH"
  ok "Config written with ${#STAGES[@]} stage(s)"
else
  {
    echo
    echo "# No stages yet - the room is empty, which is a true reading, not an"
    echo "# error. A stage is just a directory; add one and restart:"
    echo "# stages:"
    echo "#   - name: FraunkensteinsLab"
    echo "#     path: /mnt/nvme/fraunkensteinLab"
    echo "stages: []"
  } >> "$CFG_PATH"
  ok "Config written (no stages - pass --stage PATH, or edit the file)"
fi

$UPDATES_OFF && cat >> "$CFG_PATH" <<'YAML'

# ── Update checking ───────────────────────────────────────────────────
# Turned OFF at install time by --no-updates. Update checking is on by
# default across the Seren family: it asks the package index whether a newer
# release exists and reports it on the service's info route. It NEVER
# upgrades anything. Flip this to true to turn it back on, or set
# SEREN_THEATRE_UPDATES_ENABLED=true in the unit file.
updates:
  enabled: false
YAML

# -- 5b. launcher -----------------------------------------------------------
write_launcher "$APP_DIR" "seren-theatre" "$VPY" "seren_theatre" "$CFG_PATH"

# -- 6. optional autostart ----------------------------------------------------
$INSTALL_SERVICE && setup_autostart "$SCRIPT_DIR" "seren-theatre" "$APP_DIR" "" "$INSTANCE" "$VENV_DIR" "$SERVICE_USER"

# -- done -------------------------------------------------------------------
echo
echo -e "${G}==========================================${NC}"
echo -e "${G}  SerenTheatre is set up ✓${NC}"
echo -e "${G}==========================================${NC}"
if ! $INSTALL_SERVICE; then
  echo -e "  Start it:        ${B}$APP_DIR/run-seren-theatre.sh${NC}"
fi
echo -e "  Viewer:          ${B}http://${CONNECT_HOST}:${PORT}/viewer${NC}"
echo -e "  State (JSON):    ${B}http://${CONNECT_HOST}:${PORT}/api/state${NC}"
echo -e "  Health:          ${B}http://${CONNECT_HOST}:${PORT}/health${NC}"
echo
if $STAGEHAND; then
  echo -e "  Stagehand:       ${B}$VENV_DIR/bin/seren-theatre-stagehand --check${NC}"
  echo -e "  Start a build:   ${B}$VENV_DIR/bin/seren-theatre-stagehand recipe.yaml${NC}"
  echo -e "  ${Y}Stagehand is a COMMAND, not a button. The service exposes no${NC}"
  echo -e "  ${Y}write route - a stagehand is not on stage.${NC}"
  echo
fi
if [[ ${#STAGES[@]} -eq 0 ]]; then
  echo -e "  ${Y}No stages configured yet - the room is empty. Add one to${NC}"
  echo -e "  ${Y}$CFG_PATH, or try a one-off:${NC}"
  echo -e "  ${B}SEREN_THEATRE_STAGE=/path/to/lab $VPY -m seren_theatre${NC}"
  echo
fi
echo -e "  ${Y}Read-only by construction. A theatre cannot perturb the thing on the table.${NC}"
echo -e "${G}Rip it and win. 🌭🔧${NC}"

# -- Starwright contract: structured completion event -------------------------
# Human banner above, machine-readable twin here. No-op without --json.
seren_emit_done "$SVC_NAME" "$CONNECT_HOST" "$PORT" "$INSTALL_SERVICE" "${TOKEN:-}"
