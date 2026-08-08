#!/usr/bin/env bash
# ==========================================================================
#  setup-seren-python-service.sh  -  GENERIC installer mechanism for any
#  Python-module-shaped seren service.
#
#  *** THIS IS THE BASE TEMPLATE ***
#  Memory and Loci are the template leaders — see seren-memory-setup.sh and
#  seren-loci-setup.sh for the canonical reference implementations.
#
#  This script is the MECHANISM half: it handles Python discovery, venv
#  creation, wheel resolution, pip install, config writing, launcher, and
#  autostart delegation. The pointed wrapper (seren-X-setup.sh) sets the
#  identity variables and calls into this.
#
#  DESIGN PATTERN (same as setup-seren-service.sh for service wrappers):
#    Pointed wrapper (seren-X-setup.sh) → sets identity + flags
#       → exec's this generic core with those parameters
#
#  USAGE
#    bash setup-seren-python-service.sh \
#      --service-name seren-memory \
#      --module  seren_memory \
#      --package seren-memory \
#      --default-port 7420 \
#      --venv-dir ~/seren-venvs/memory \
#      --app-dir ~/seren-memory \
#      --config seren-memory.yaml \
#      --repo ChadRoesler/SerenMemory \
#      --viewer halls.html
#
#  FLAGS
#    --service-name NAME   Service name (seren-memory, seren-loci, etc.)
#                          NOT --service: that is the user-facing autostart
#                          switch below, and the two used to collide. See the
#                          note on the case block.
#    --module NAME         Python module name (seren_memory, seren_loci, etc.)
#    --package NAME        PyPI package name (seren-memory, seren-loci, etc.)
#    --default-port N      Default port for this service
#    --venv-dir PATH       Default venv dir (~/seren-venvs/<name>)
#    --app-dir PATH        Default app dir (~/seren-<name>)
#    --config FILE         Config filename (seren-memory.yaml)
#    --repo SLUG           GitHub repo (owner/name) for release downloads
#    --viewer FILE         Viewer asset filename to sanity-check
#    --extras LIST         Comma-separated extras flags (mcp,corp,vector)
#    -h, --help            This help
#
#  The pointed wrapper also passes through user-facing flags:
#    --port, --host, --token, --gen-token, --wheel, --ref, --repo,
#    --service, --mcp, --corp, --vector, --instance, --venv
#
#  Each pointed wrapper defines a write_config() function for its own
#  service-specific YAML content before calling the generic core.
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

# -- locate a file by walking UP the tree (reorg-robust) -----------------------
find_upward() {
  local rel="$1" dir="${2:-$SCRIPT_DIR}"
  while [[ "$dir" != "/" && -n "$dir" ]]; do
    [[ -e "$dir/$rel" ]] && { echo "$dir/$rel"; return 0; }
    dir="$(dirname "$dir")"
  done
  return 1
}

# -- identity vars (set by pointed wrapper) -----------------------------------
SERVICE=""; MODULE=""; PACKAGE=""; DEFAULT_PORT=""
VENV_DIR=""; APP_DIR=""; CONFIG_FILE=""; REPO=""; VIEWER=""; EXTRAS=""

# -- user-facing flags (passed through from pointed wrapper) -------------------
PORT=""; HOST=""; TOKEN=""; GEN_TOKEN=false; WHEEL=""; REF=""
INSTALL_SERVICE=false; MCP=false; CORP=false; VECTOR=false
INSTANCE=""; VENV_OVERRIDE=""; SERVICE_USER=""

# COLLISION THAT WAS HERE, and why the identity flag is now --service-name:
#
#   --service)  SERVICE="$2"; shift 2 ;;        # identity
#   ...
#   --service)  INSTALL_SERVICE=true; shift ;;  # user-facing autostart switch
#
# A bash `case` takes the FIRST matching pattern, so the second branch was
# unreachable. --service never enabled autostart; it silently overwrote the
# service NAME with whatever came next and ate that argument too. Passing
# `--service --mcp` left SERVICE='--mcp', INSTALL_SERVICE=false and MCP=false -
# three wrong answers from one duplicated pattern, none of them an error.
#
# Nothing on the live path calls this file (the real installers use
# setup_autostart from seren-install-lib.sh), so this was a landmine waiting
# for the next service written from the template rather than a live outage.
while [[ $# -gt 0 ]]; do
  case "$1" in
    # identity
    --service-name) SERVICE="$2"; shift 2 ;;
    --module)       MODULE="$2"; shift 2 ;;
    --package)      PACKAGE="$2"; shift 2 ;;
    --default-port) DEFAULT_PORT="$2"; shift 2 ;;
    --venv-dir)     VENV_DIR="$2"; shift 2 ;;
    --app-dir)      APP_DIR="$2"; shift 2 ;;
    --config)       CONFIG_FILE="$2"; shift 2 ;;
    --repo)         REPO="$2"; shift 2 ;;
    --viewer)       VIEWER="$2"; shift 2 ;;
    --extras)       EXTRAS="$2"; shift 2 ;;
    # user-facing (passed through)
    --port)         PORT="$2"; shift 2 ;;
    --host)         HOST="$2"; shift 2 ;;
    --token)        TOKEN="$2"; shift 2 ;;
    --gen-token)    GEN_TOKEN=true; shift ;;
    --wheel)        WHEEL="$2"; shift 2 ;;
    --ref)          REF="$2"; shift 2 ;;
    --repo)         REPO="$2"; shift 2 ;;
    --service)      INSTALL_SERVICE=true; shift ;;
    --mcp)          MCP=true; shift ;;
    --corp)         CORP=true; shift ;;
    --vector)       VECTOR=true; shift ;;
    --instance)     INSTANCE="$2"; shift 2 ;;
    --venv)         VENV_OVERRIDE="$2"; shift 2 ;;
    --service-user) SERVICE_USER="$2"; shift 2 ;;
    # Header printed by SHAPE, not by a hardcoded line range - a magic number
    # here silently truncates --help every time the header grows.
    -h|--help)      awk 'NR>1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"; exit 0 ;;
    *)              die "unknown flag: $1  (try --help)" ;;
  esac
done

[[ -n "$SERVICE" ]] || die "--service is required"
[[ -n "$MODULE"   ]] || die "--module is required"
[[ -n "$PACKAGE"  ]] || die "--package is required"

# -- apply defaults + instance suffix -----------------------------------------
VENV_DIR="${VENV_OVERRIDE:-${VENV_DIR:-$HOME/seren-venvs/${SERVICE#seren-}}}"
APP_DIR="${APP_DIR:-$HOME/$SERVICE}"
CONFIG_FILE="${CONFIG_FILE:-$SERVICE.yaml}"
CONFIG_PATH="$APP_DIR/$CONFIG_FILE"
[[ -z "$REPO" ]] && REPO="ChadRoesler/${SERVICE^}"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-$DEFAULT_PORT}"
CONNECT_HOST="$HOST"
[[ "$HOST" == "0.0.0.0" ]] && CONNECT_HOST="127.0.0.1"

VENV_DIR="$VENV_DIR$INSTANCE"
APP_DIR="$APP_DIR$INSTANCE"
CONFIG_PATH="$APP_DIR/$CONFIG_FILE"

if [[ -n "$INSTANCE" && "$PORT" == "$DEFAULT_PORT" ]]; then
  warn "Instance '$INSTANCE' is using the default port $DEFAULT_PORT - give each concurrent instance its own --port or they'll collide."
fi

echo -e "${G}==========================================${NC}"
$IS_MAC && echo -e "${G}  ${SERVICE^} setup (macOS)${NC}" || echo -e "${G}  ${SERVICE^} setup (Linux)${NC}"
echo -e "${G}==========================================${NC}"

# -- parse extras -------------------------------------------------------------
MCP=false; CORP=false; VECTOR=false
if [[ -n "$EXTRAS" ]]; then
  for e in $(echo "$EXTRAS" | tr ',' ' '); do
    case "$e" in mcp) MCP=true ;; corp) CORP=true ;; vector) VECTOR=true ;; esac
  done
fi

# -- build extras suffix + description ----------------------------------------
EXTRAS_LIST=()
$MCP    && EXTRAS_LIST+=("mcp")
$CORP   && EXTRAS_LIST+=("corp")
$VECTOR && EXTRAS_LIST+=("vector")
EXTRAS_SUFFIX=""
[[ ${#EXTRAS_LIST[@]} -gt 0 ]] && EXTRAS_SUFFIX="[$(IFS=,; echo "${EXTRAS_LIST[*]}")]"

EXTRAS_DESC=""
$MCP    && EXTRAS_DESC+=" + the MCP SDK"
$CORP   && EXTRAS_DESC+=" + truststore"
$VECTOR && EXTRAS_DESC+=" + sqlite-vec + sentence-transformers/torch"

# ============================================================================
#  PHASE 1: find Python
# ============================================================================
step "Finding a usable Python (3.10-3.12)"
PYBIN=""
for cand in python3.12 python3.11 python3.10 python3 python; do
  if command -v "$cand" >/dev/null 2>&1; then
    ver="$("$cand" -c 'import sys; print("%d.%d"%sys.version_info[:2])' 2>/dev/null || echo "")"
    case "$ver" in 3.10|3.11|3.12) PYBIN="$cand"; break ;; esac
  fi
done
[[ -n "$PYBIN" ]] || die "No Python 3.10-3.12 found. Install python3.12 + python3.12-venv."
PYVER="$("$PYBIN" -c 'import sys; print("%d.%d.%d"%sys.version_info[:3])')"
ok "Using $PYBIN (Python $PYVER)"

# ============================================================================
#  PHASE 2: resolve wheel
# ============================================================================
[[ -n "$REF" && -z "$REPO" ]] && REPO="ChadRoesler/${SERVICE^}"

WHEEL_SRC=""; CLEANUP_WHEEL=false
if [[ -n "$WHEEL" ]]; then
  [[ -f "$WHEEL" ]] || die "wheel not found: $WHEEL"
  WHEEL_SRC="$WHEEL"; ok "Installing from local wheel: $(basename "$WHEEL")"
elif [[ -n "$REPO" ]]; then
  step "Resolving the $PACKAGE release from GitHub ($REPO)"
  command -v curl >/dev/null 2>&1 || die "curl is required (sudo apt install curl)"
  api="https://api.github.com/repos/${REPO}/releases/${REF:+tags/$REF}"
  [[ -z "$REF" ]] && api="https://api.github.com/repos/${REPO}/releases/latest"
  json="$(curl -fsSL "$api" 2>/dev/null)" || die "GitHub API request failed ($api)"
  read -r TAG WHL_URL < <("$PYBIN" - "$json" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
tag = d.get("tag_name", "?")
whl = next((a["browser_download_url"] for a in d.get("assets", []) if a.get("name","").endswith(".whl")), "")
print(tag, whl)
PY
)
  [[ -n "$WHL_URL" && "$WHL_URL" != "None" ]] || die "No .whl asset in release '$TAG'"
  ok "Release $TAG  ($(basename "$WHL_URL"))"
  WHEEL_SRC="$(mktemp /tmp/seren_XXXXXX.whl)"; CLEANUP_WHEEL=true
  trap '[[ "$CLEANUP_WHEEL" == true ]] && rm -f "$WHEEL_SRC"' EXIT
  curl -fsSL "$WHL_URL" -o "$WHEEL_SRC" || die "download failed"; ok "Downloaded"
else
  WHEEL_SRC="$PACKAGE"; ok "Installing $PACKAGE from PyPI"
fi

# ============================================================================
#  PHASE 3: venv + install
# ============================================================================
step "Creating venv at $VENV_DIR"
if [[ -x "$VENV_DIR/bin/python" ]]; then warn "venv already exists - reusing it"
else "$PYBIN" -m venv "$VENV_DIR" || die "venv creation failed (need python3-venv?)"; ok "venv created"; fi
VPY="$VENV_DIR/bin/python"

pip_corp_args() {
  $CORP || return 0
  local pipver major minor
  pipver="$("$VPY" -m pip --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)"
  major="${pipver%%.*}"; minor="${pipver#*.}"
  (( major > 24 || (major == 24 && minor >= 2) )) && echo "--use-feature=truststore"
}
CORP_ARGS="$(pip_corp_args)"

step "Installing ${PACKAGE}${EXTRAS_SUFFIX}${EXTRAS_DESC}"
"$VPY" -m pip install -q --upgrade pip
# shellcheck disable=SC2086
"$VPY" -m pip install -q --upgrade $CORP_ARGS "${WHEEL_SRC}${EXTRAS_SUFFIX}" || die "pip install failed"
ok "Installed"

# ============================================================================
#  PHASE 4: sanity check
# ============================================================================
step "Sanity-checking the install"
CHECK="$("$VPY" - "$VIEWER" <<'PY'
import pathlib, sys
viewer = sys.argv[1]
try:
    import ${MODULE}
except Exception as e:
    print(f"IMPORT_FAILED: {e}"); raise SystemExit
v = pathlib.Path(${MODULE}.__file__).parent / "viewer" / viewer
print("OK" if v.exists() else "VIEWER_MISSING")
PY
)" 2>/dev/null || CHECK="FAILED"
case "$CHECK" in
  OK) ok "Package imports and the viewer asset is present" ;;
  VIEWER_MISSING) warn "Package installed but $VIEWER is missing - /viewer will 404" ;;
  *) die "Install looks broken: $CHECK" ;;
esac

# ============================================================================
#  PHASE 5: config
# ============================================================================
step "Writing config at $CONFIG_PATH"
mkdir -p "$APP_DIR"
$GEN_TOKEN && TOKEN="$("$VPY" -c 'import secrets; print(secrets.token_urlsafe(32))')"
if [[ -f "$CONFIG_PATH" ]]; then
  bak="$CONFIG_PATH.bak.$(date +%s)"
  cp "$CONFIG_PATH" "$bak"
  warn "Existing config backed up to $(basename "$bak")"
fi

# Pointed wrapper should define write_config() for service-specific YAML
if declare -F write_config >/dev/null 2>&1; then
  write_config
else
  # Minimal fallback
  cat > "$CONFIG_PATH" <<YAML
# ${SERVICE^} config
server:
  host: ${HOST}
  port: ${PORT}
  bearer_token: "${TOKEN}"
YAML
fi
[[ -n "$TOKEN" ]] && chmod 600 "$CONFIG_PATH" && ok "Config locked to 0600"
ok "Config written"

# ============================================================================
#  PHASE 5b: launcher
# ============================================================================
LAUNCHER="$APP_DIR/run-${SERVICE}.sh"
cat > "$LAUNCHER" <<LAUNCHEOF
#!/usr/bin/env bash
exec "$VPY" -m ${MODULE} --config "$CONFIG_PATH"
LAUNCHEOF
chmod +x "$LAUNCHER"
ok "Launcher written: $LAUNCHER"

# ============================================================================
#  PHASE 6: optional autostart
# ============================================================================
if $INSTALL_SERVICE; then
  step "Installing the autostart service"
  WRAPPER="$SCRIPT_DIR/../bash/setup-${SERVICE#seren-}-service.sh"
  CORE="$(find_upward "services/lib/setup-seren-service.sh")"
  if [[ -f "$WRAPPER" && -f "$CORE" ]]; then
    if [[ -n "$TOKEN" ]]; then
      env_var="${SERVICE^^}_BEARER_TOKEN"; env_var="${env_var//-/_}"
      printf '%s=%s\n' "$env_var" "$TOKEN" > "$APP_DIR/${SERVICE}.env"
      chmod 600 "$APP_DIR/${SERVICE}.env"
    fi
    # NOT `local`. This block is at script top level, not inside a function,
    # and bash rejects `local` outside a function at RUNTIME with exit 1 -
    # which under `set -euo pipefail` killed the install right here, after five
    # phases of real work, with the memorable message
    # "local: can only be used in a function".
    #
    # `bash -n` does NOT catch this. It parses perfectly and only fails when
    # the line is actually reached, which is why it survived: the --service
    # collision above meant INSTALL_SERVICE was never true, so this branch was
    # unreachable and the bug never got a chance to fire. Two defects, the
    # first one hiding the second.
    venv_flag=""
    [[ -n "$VENV_DIR" ]] && venv_flag="--venv $VENV_DIR"
    user_flag=""
    [[ -n "$SERVICE_USER" ]] && user_flag="--service-user $SERVICE_USER"
    # Unquoted on purpose: flag+value pairs that must word-split, empty if unset.
    bash "$WRAPPER" $venv_flag $user_flag --instance "${INSTANCE}" || die "service install failed"
  else
    warn "setup-${SERVICE#seren-}-service.sh not found. Run it manually:"
    warn "  bash setup-${SERVICE#seren-}-service.sh --instance '${INSTANCE}'"
  fi
fi

# ============================================================================
#  DONE
# ============================================================================
echo
echo -e "${G}==========================================${NC}"
echo -e "${G}  ${SERVICE^} is set up ✓${NC}"
echo -e "${G}==========================================${NC}"
if ! $INSTALL_SERVICE; then
  echo -e "  Start it:        ${B}$LAUNCHER${NC}"
fi
echo -e "  Viewer:          ${B}http://${CONNECT_HOST}:${PORT}/viewer${NC}"
[[ -n "$TOKEN" ]] && echo -e "  Bearer token:    ${Y}${TOKEN}${NC}"
echo
$MCP    && echo -e "  MCP endpoint:    ${B}http://${CONNECT_HOST}:${PORT}/mcp/${NC}"
$CORP   && echo -e "  TLS:             ${B}OS trust store${NC}"
$VECTOR && echo -e "  Finder:          ${B}vector (sqlite-vec + all-MiniLM-L6-v2)${NC}"
echo -e "${G}Rip it and win. 🌭🔧${NC}"
