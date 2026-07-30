#!/usr/bin/env bash
# ==========================================================================
#  seren-margin-setup.sh  -  one-shot SerenMargin installer (Linux + macOS)
#
#  Refactored to source seren-install-lib.sh (shared installer library).
#  Identity lines + config + local-build-from-repo default are the unique parts.
#
#  USAGE (same flags as before)
#    bash seren-margin-setup.sh                  # build from repo, local-only
#    bash seren-margin-setup.sh --service        # + autostart
#    bash seren-margin-setup.sh --wheel ./seren_margin-0.1.0-py3-none-any.whl
#    bash seren-margin-setup.sh --pypi           # once published
#
#  FLAGS
#    --port N         Port to listen on            (default 7421)
#    --host HOST      Bind address                 (default 127.0.0.1)
#    --repo-dir PATH  SerenMargin repo checkout    (default: sibling ../SerenMargin)
#    --wheel PATH     Install from a local .whl
#    --pypi           Install seren-margin from PyPI
#    --ref TAG        Pin to a GitHub release tag
#    --repo SLUG      GitHub release repo
#    --service        Autostart via systemd/launchd
#    --mcp            Install the [mcp] extra
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

# -- defaults ---------------------------------------------------------------
PORT=7421
HOST="127.0.0.1"
REPO_DIR="$(find_upward "SerenMargin" || true)"   # sibling checkout (build source)
WHEEL=""
USE_PYPI=false
REF=""
REPO=""
INSTALL_SERVICE=false
MCP=false
INSTANCE=""
VENV_DIR="$HOME/seren-venvs/margin"
APP_DIR="$HOME/seren-margin"

# -- Starwright contract: identity + machine-readable metadata ----------------
# Consumed by `--describe`. flags/extras are DERIVED from the case branches
# below at runtime (see seren_flags_from_self), so adding a flag needs no edit
# here and this block can't drift from what the parser actually accepts.
SVC_NAME="seren-margin"
SVC_DISPLAY="Seren Margin"
SVC_DESC="Private notes-to-self for an AI assistant"
SVC_GROUP="auxiliary"
SVC_PACKAGE="seren-margin"
# Card colour in Seren Starwright - no viewer by design; muted gold picked for the installer only
SVC_ACCENT="#d1cbba"

# --describe must answer with ZERO side effects: no venv, no network, no python.
# Scanned ahead of the parse loop so no other flag can have run anything first.
for _a in "$@"; do
  [[ "$_a" == "--describe" ]] && { seren_describe; exit 0; }
done

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)      PORT="$2"; shift 2 ;;
    --host)      HOST="$2"; shift 2 ;;
    --repo-dir)  REPO_DIR="$2"; shift 2 ;;
    --wheel)     WHEEL="$2"; shift 2 ;;
    --pypi)      USE_PYPI=true; shift ;;
    --ref)       REF="$2"; shift 2 ;;
    --repo)      REPO="$2"; shift 2 ;;
    --service)   INSTALL_SERVICE=true; shift ;;
    --mcp)       MCP=true; shift ;;
    --instance)  INSTANCE="$2"; shift 2 ;;
    --venv)      VENV_DIR="$2"; shift 2 ;;
    --json)     seren_json_on; shift ;;
    --describe) seren_describe; exit 0 ;;
    -h|--help)   sed -n '2,42p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           die "unknown flag: $1  (try --help)" ;;
  esac
done

VENV_DIR="$VENV_DIR$INSTANCE"
APP_DIR="$APP_DIR$INSTANCE"
CFG_PATH="$APP_DIR/seren-margin.yaml"
CONNECT_HOST="$HOST"
[[ "$HOST" == "0.0.0.0" ]] && CONNECT_HOST="127.0.0.1"
[[ -n "$INSTANCE" && "$PORT" == "7421" ]] && warn "Instance '$INSTANCE' uses default port 7421 — may collide."

echo -e "${G}==========================================${NC}"
$IS_MAC && echo -e "${G}  SerenMargin setup (macOS)${NC}" || echo -e "${G}  SerenMargin setup (Linux)${NC}"
echo -e "${G}==========================================${NC}"

# -- 1. find Python -----------------------------------------------------------
PYBIN="$(find_python)"
[[ -n "$REF" && -z "$REPO" ]] && REPO="ChadRoesler/SerenMargin"

# -- 2. resolve what to install ------------------------------------------------
# Precedence: --wheel > --repo/--ref (GitHub) > --pypi > local build (default)
PACKAGE="seren-margin"
WHEEL_SRC=""
CLEANUP_WHEEL=false
if [[ -n "$WHEEL" ]]; then
  [[ -f "$WHEEL" ]] || die "wheel not found: $WHEEL"
  WHEEL_SRC="$WHEEL"
  ok "Installing from local wheel: $(basename "$WHEEL")"
elif [[ -n "$REPO" ]]; then
  resolve_wheel
elif $USE_PYPI; then
  WHEEL_SRC="seren-margin"
  ok "Installing the latest seren-margin from PyPI"
else
  # DEFAULT: build a wheel from the repo checkout. Margin isn't on PyPI yet.
  step "Building a wheel from the SerenMargin checkout"
  PKG_DIR="${REPO_DIR}/SerenMargin"
  [[ -f "${PKG_DIR}/pyproject.toml" ]] || die "SerenMargin checkout not found at ${PKG_DIR}
  Point --repo-dir at your SerenMargin repo, or use --wheel / --pypi / --ref."
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

EXTRAS=""
$MCP && EXTRAS="[mcp]"
pip_install "$VPY" "$WHEEL_SRC" "$EXTRAS" "" " ($($MCP && echo ' + MCP SDK'))"
$CLEANUP_WHEEL && rm -f "$WHEEL_SRC"

# -- 4. sanity check (import + mcp-manifest asset) ---------------------------
step "Sanity-checking the install"
CHECK="$("$VPY" - <<'PY'
import pathlib
try:
    import seren_margin
except Exception as e:
    print(f"IMPORT_FAILED: {e}"); raise SystemExit
m = pathlib.Path(seren_margin.__file__).parent / "mcp-manifest.yaml"
print("OK" if m.exists() else "MANIFEST_MISSING")
PY
)"
case "$CHECK" in
  OK) ok "Package imports and the MCP manifest asset is present" ;;
  MANIFEST_MISSING) warn "Installed but mcp-manifest.yaml is missing — /mcp-manifest will 500" ;;
  *) die "Install looks broken: $CHECK" ;;
esac

# -- 5. config --------------------------------------------------------------
step "Writing config at $CFG_PATH"
mkdir -p "$APP_DIR"
[[ -f "$CFG_PATH" ]] && cp "$CFG_PATH" "$CFG_PATH.bak.$(date +%s)" && warn "Existing config backed up"
cat > "$CFG_PATH" <<YAML
# SerenMargin config - generated by seren-margin-setup.sh
# Full reference: see seren-margin.yaml.sample in the repo.
server:
  host: ${HOST}
  port: ${PORT}
  db_path: ~/.seren-margin${INSTANCE}/notes.db
YAML
ok "Config written"

# -- 5b. launcher -----------------------------------------------------------
write_launcher "$APP_DIR" "seren-margin" "$VPY" "seren_margin" "$CFG_PATH"

# -- 6. optional autostart ----------------------------------------------------
$INSTALL_SERVICE && setup_autostart "$SCRIPT_DIR" "seren-margin" "$APP_DIR" "" "$INSTANCE" "$VENV_DIR"

# -- done -------------------------------------------------------------------
echo
echo -e "${G}==========================================${NC}"
echo -e "${G}  SerenMargin is set up ✓${NC}"
echo -e "${G}==========================================${NC}"
if ! $INSTALL_SERVICE; then
  echo -e "  Start it:        ${B}$APP_DIR/run-seren-margin.sh${NC}"
fi
echo -e "  Health:          ${B}http://${CONNECT_HOST}:${PORT}/health${NC}"
echo -e "  Engine-check:    ${B}http://${CONNECT_HOST}:${PORT}/notes/stats${NC}"
echo -e "  MCP manifest:    ${B}http://${CONNECT_HOST}:${PORT}/mcp-manifest${NC}"
echo
$MCP  && echo -e "  MCP endpoint:    ${B}http://${CONNECT_HOST}:${PORT}/mcp/${NC}"
echo -e "  ${Y}Private by default, transparent in mechanism, opt-in by deploy.${NC}"
echo -e "${G}Rip it and win. 🌭🔧${NC}"

# -- Starwright contract: structured completion event -------------------------
# Human banner above, machine-readable twin here. No-op without --json.
seren_emit_done "$SVC_NAME" "$CONNECT_HOST" "$PORT" "$INSTALL_SERVICE" "${TOKEN:-}"
