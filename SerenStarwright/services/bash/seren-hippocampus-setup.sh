#!/usr/bin/env bash
# ==========================================================================
#  seren-hippocampus-setup.sh  -  one-shot SerenHippocampus installer (Linux + macOS)
#
#  The sleep cycle for SerenMemory, split out. Holds no store: it reads
#  short-terms from Memory, writes dockets to Memory, purges what was flagged.
#  Needs a running SerenMemory and the bearer that Memory requires.
#
#  USAGE
#    bash seren-hippocampus-setup.sh --memory-token <memory's token>
#    bash seren-hippocampus-setup.sh --service --gen-token --memory-token ...
#    bash seren-hippocampus-setup.sh --local ../../.dev-wheelhouse     # dev builds
#    bash seren-hippocampus-setup.sh --model-url ""                     # mechanical mode
#
#  FLAGS
#    --port N            Port to listen on            (default 7424)
#    --host HOST         Bind address                 (default 127.0.0.1)
#    --token TOKEN       Bearer THIS service requires of callers
#    --gen-token         Generate a random bearer token
#    --memory-url URL    Where SerenMemory is         (default http://127.0.0.1:7420)
#    --memory-token TOK  Bearer to present TO Memory  (the token Memory was installed with)
#    --memory-config P   Memory's own config: its url AND its bearer, read from the file
#    --model-url URL     Small model, OpenAI-compatible (default http://localhost:8090/v1;
#                        "" = mechanical mode, no attach/supersede proposals)
#    --repo-dir PATH     SerenHippocampus checkout    (default: sibling ../SerenHippocampus)
#    --wheel PATH        Install from a local .whl
#    --local DIR|URL     Install from a dev wheelhouse (seren-dev-publish.sh)
#    --pypi              Install seren-hippocampus from PyPI
#    --ref TAG           Pin to a GitHub release tag
#    --repo SLUG         GitHub release repo
#    --service           Autostart via systemd/launchd
#    --corp              Route TLS through OS trust store
#    --instance NAME     Instance name
#    --venv PATH         Override venv location
#    --no-updates        Turn update checking OFF in the generated config
#    -h, --help          This help
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
PORT=7424
HOST="127.0.0.1"
TOKEN=""
GEN_TOKEN=false
MEMORY_URL="http://127.0.0.1:7420"
MEMORY_TOKEN=""
MEMORY_CONFIG=""      # Memory's own config: its url AND its bearer, read from the file
MODEL_URL="http://localhost:8090/v1"
REPO_DIR="$(find_upward "SerenHippocampus" || true)"   # sibling checkout (build source)
WHEEL=""
LOCAL=""
USE_PYPI=false
REF=""
REPO=""
INSTALL_SERVICE=false
SERVICE_USER=""
CORP=false
UPDATES_OFF=false
INSTANCE=""
VENV_DIR="$HOME/seren-venvs/hippocampus"
APP_DIR="$HOME/seren-hippocampus"

# -- Starwright contract: identity + machine-readable metadata ----------------
SVC_NAME="seren-hippocampus"
SVC_DISPLAY="Seren Hippocampus"
SVC_DESC="The sleep cycle for SerenMemory"
SVC_GROUP="brain"
SVC_PACKAGE="seren-hippocampus"
SVC_REQUIRES="seren-memory"
SVC_ACCENT="#c9a0dc"

for _a in "$@"; do
  [[ "$_a" == "--describe" ]] && { seren_describe; exit 0; }
done

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)         PORT="$2"; shift 2 ;;
    --host)         HOST="$2"; shift 2 ;;
    --token)        TOKEN="$2"; shift 2 ;;
    --gen-token)    GEN_TOKEN=true; shift ;;
    --memory-url)   MEMORY_URL="$2"; shift 2 ;;
    --memory-token) MEMORY_TOKEN="$2"; shift 2 ;;
    --memory-config) MEMORY_CONFIG="$2"; shift 2 ;;
    --model-url)    MODEL_URL="$2"; shift 2 ;;
    --repo-dir)     REPO_DIR="$2"; shift 2 ;;
    --wheel)        WHEEL="$2"; shift 2 ;;
    --local)        LOCAL="$2"; shift 2 ;;
    --pypi)         USE_PYPI=true; shift ;;
    --ref)          REF="$2"; shift 2 ;;
    --repo)         REPO="$2"; shift 2 ;;
    --service)      INSTALL_SERVICE=true; shift ;;
    --corp)         CORP=true; shift ;;
    --no-updates)   UPDATES_OFF=true; shift ;;
    --service-user) SERVICE_USER="$2"; shift 2 ;;
    --instance)     INSTANCE="$2"; shift 2 ;;
    --venv)         VENV_DIR="$2"; shift 2 ;;
    --json)         seren_json_on; shift ;;
    --describe)     seren_describe; exit 0 ;;
    -h|--help)      awk 'NR>1{ if (/^#/) { sub(/^# ?/,""); print } else exit }' "$0"; exit 0 ;;
    *)              die "unknown flag: $1  (try --help)" ;;
  esac
done

VENV_DIR="$VENV_DIR$INSTANCE"
APP_DIR="$APP_DIR$INSTANCE"
CFG_PATH="$APP_DIR/seren-hippocampus.yaml"
CONNECT_HOST="$HOST"
[[ "$HOST" == "0.0.0.0" ]] && CONNECT_HOST="127.0.0.1"
[[ -n "$INSTANCE" && "$PORT" == "7424" ]] && warn "Instance '$INSTANCE' uses default port 7424 - may collide."
MEMORY_TOKEN_LINES=""
if [[ -n "$MEMORY_CONFIG" ]] && seren_read_sibling_config "$MEMORY_CONFIG"; then
  [[ -n "$SIB_URL" ]] && MEMORY_URL="$SIB_URL"
  [[ -z "$MEMORY_TOKEN" && -n "$SIB_TOKEN" ]] && MEMORY_TOKEN="$SIB_TOKEN"
  MEMORY_TOKEN_LINES="$(seren_sibling_token_lines "  ")"
  ok "Memory: ${MEMORY_URL} (from $MEMORY_CONFIG$([[ -n "$MEMORY_TOKEN_LINES" ]] && echo ", with its bearer"))"
fi
[[ -n "$MEMORY_TOKEN" ]] && MEMORY_TOKEN_LINES="$(printf '  bearer_token: "%s"' "$MEMORY_TOKEN")"
[[ -z "$MEMORY_TOKEN_LINES" ]] && warn "No --memory-token / --memory-config: fine if Memory has no bearer; a Memory installed with --gen-token will answer 401 to every sleep."

echo -e "${G}==========================================${NC}"
$IS_MAC && echo -e "${G}  SerenHippocampus setup (macOS)${NC}" || echo -e "${G}  SerenHippocampus setup (Linux)${NC}"
echo -e "${G}==========================================${NC}"

# -- 1. find Python -----------------------------------------------------------
PYBIN="$(find_python)"
[[ -n "$REF" && -z "$REPO" ]] && REPO="ChadRoesler/SerenHippocampus"

# -- 2. resolve what to install ------------------------------------------------
# Precedence: --wheel > --local (dev wheelhouse) > --repo/--ref (GitHub) > --pypi > local build (default)
PACKAGE="seren-hippocampus"
WHEEL_SRC=""
CLEANUP_WHEEL=false
if [[ -n "$WHEEL" ]]; then
  [[ -f "$WHEEL" ]] || die "wheel not found: $WHEEL"
  WHEEL_SRC="$WHEEL"
  ok "Installing from local wheel: $(basename "$WHEEL")"
elif [[ -n "$LOCAL" || -n "$REPO" ]]; then
  resolve_wheel
elif $USE_PYPI; then
  WHEEL_SRC="seren-hippocampus"
  ok "Installing the latest seren-hippocampus from PyPI"
else
  step "Building a wheel from the SerenHippocampus checkout"
  PKG_DIR="${REPO_DIR}/SerenHippocampus"
  [[ -f "${PKG_DIR}/pyproject.toml" ]] || die "SerenHippocampus checkout not found at ${PKG_DIR}
  Point --repo-dir at your SerenHippocampus repo, or use --wheel / --local / --pypi / --ref."
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

EXTRAS_LIST=()
$CORP && EXTRAS_LIST+=("corp")
EXTRAS=""
[[ ${#EXTRAS_LIST[@]} -gt 0 ]] && EXTRAS="[$(IFS=,; echo "${EXTRAS_LIST[*]}")]"
CORP_ARGS="$(pip_corp_args)"
pip_install "$VPY" "$WHEEL_SRC" "$EXTRAS" "$CORP_ARGS" "$($CORP && echo ' (+ truststore)')"
$CLEANUP_WHEEL && rm -f "$WHEEL_SRC"

# -- 4. sanity check ----------------------------------------------------------
sanity_check "$VPY" "seren_hippocampus" ""

# -- 5. config --------------------------------------------------------------
step "Writing config at $CFG_PATH"
mkdir -p "$APP_DIR"
[[ -f "$CFG_PATH" ]] && cp "$CFG_PATH" "$CFG_PATH.bak.$(date +%s)" && warn "Existing config backed up"
$GEN_TOKEN && TOKEN="$("$VPY" -c 'import secrets; print(secrets.token_urlsafe(32))')"
# A reinstall keeps the existing bearer unless --token / --gen-token say otherwise.
if [[ -z "$TOKEN" ]] && ! $GEN_TOKEN; then seren_reuse_token "$CFG_PATH" || true; fi
cat > "$CFG_PATH" <<YAML
# SerenHippocampus config - generated by seren-hippocampus-setup.sh
# Full reference: see seren-hippocampus.yaml.sample in the repo.
server:
  host: ${HOST}
  port: ${PORT}
$( [[ -n "$TOKEN" ]] && printf '  bearer_token: "%s"\n' "$TOKEN" )

memory:
  url: ${MEMORY_URL}
${MEMORY_TOKEN_LINES}

model:
  url: "${MODEL_URL}"

sleep:
  mode: thread
  state_path: ~/.seren-hippocampus${INSTANCE}/state.json
YAML
[[ -n "$TOKEN" || -n "$MEMORY_TOKEN_LINES" ]] && chmod 600 "$CFG_PATH"

$UPDATES_OFF && cat >> "$CFG_PATH" <<'YAML'

# ── Update checking ───────────────────────────────────────────────────
# Turned OFF at install time by --no-updates. Flip to true to re-enable, or
# set SEREN_HIPPOCAMPUS_UPDATES_ENABLED=true in the unit file.
updates:
  enabled: false
YAML
ok "Config written"

# -- 5b. launcher -----------------------------------------------------------
write_launcher "$APP_DIR" "seren-hippocampus" "$VPY" "seren_hippocampus" "$CFG_PATH"

# -- 6. optional autostart ----------------------------------------------------
$INSTALL_SERVICE && setup_autostart "$SCRIPT_DIR" "seren-hippocampus" "$APP_DIR" "$TOKEN" "$INSTANCE" "$VENV_DIR" "$SERVICE_USER"

# -- done -------------------------------------------------------------------
echo
echo -e "${G}==========================================${NC}"
echo -e "${G}  SerenHippocampus is set up ✓${NC}"
echo -e "${G}==========================================${NC}"
if ! $INSTALL_SERVICE; then
  echo -e "  Start it:        ${B}$APP_DIR/run-seren-hippocampus.sh${NC}"
fi
echo -e "  Health:          ${B}http://${CONNECT_HOST}:${PORT}/health${NC}"
echo -e "  Status:          ${B}http://${CONNECT_HOST}:${PORT}/status${NC}"
echo -e "  Sleep now:       ${B}POST http://${CONNECT_HOST}:${PORT}/sleep${NC}"
echo -e "  Memory:          ${B}${MEMORY_URL}${NC}"
[[ -z "$MODEL_URL" ]] && echo -e "  Model:           ${Y}none - mechanical mode${NC}" || echo -e "  Model:           ${B}${MODEL_URL}${NC}"
[[ -n "$TOKEN" ]] && echo -e "  Bearer token:    ${Y}${TOKEN}${NC}"
echo
echo -e "  ${Y}Sleeps every ~20h; tends denied operations every 5 minutes.${NC}"
echo -e "${G}Rip it and win. 🌭🔧${NC}"

seren_emit_done "$SVC_NAME" "$CONNECT_HOST" "$PORT" "$INSTALL_SERVICE" "${TOKEN:-}"
