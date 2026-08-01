#!/usr/bin/env bash
# ==========================================================================
#  seren-corpus-callosum-setup.sh  -  one-shot SCC installer (Linux + macOS)
#
#  Refactored to source seren-install-lib.sh (shared installer library).
#  Identity lines + config are the only unique parts.
#
#  USAGE (same flags as before)
#    bash seren-corpus-callosum-setup.sh
#    bash seren-corpus-callosum-setup.sh --mcp --service
#    bash seren-corpus-callosum-setup.sh --wheel ./seren_corpus_callosum-0.1.0-py3-none-any.whl
#    bash seren-corpus-callosum-setup.sh --corp
#
#  FLAGS
#    --port N         Port to listen on            (default 7423)
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
#    --updates        Install update-checking support ([updates] extra)
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
PORT=7423
HOST="127.0.0.1"
TOKEN=""
GEN_TOKEN=false
WHEEL=""
REF=""
REPO=""
INSTALL_SERVICE=false
MCP=false
UPDATES=false
CORP=false
INSTANCE=""
VENV_DIR="$HOME/seren-venvs/callosum"
APP_DIR="$HOME/seren-corpus-callosum"

# -- Starwright contract: identity + machine-readable metadata ----------------
# Consumed by `--describe`. flags/extras are DERIVED from the case branches
# below at runtime (see seren_flags_from_self), so adding a flag needs no edit
# here and this block can't drift from what the parser actually accepts.
SVC_NAME="seren-corpus-callosum"
SVC_DISPLAY="Seren Corpus Callosum"
SVC_DESC="The bridge between Loci and Memory"
SVC_GROUP="brain"
SVC_PACKAGE="seren-corpus-callosum"
# Card colour in Seren Starwright - matches seren_corpus_callosum/app.py viewer accent
SVC_ACCENT="#9d7cff"
# The config this installer writes is pre-wired to memory:7420 + loci:7422,
# so installing SCC alone gives you a bridge to nothing.
SVC_REQUIRES="seren-memory seren-loci"

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
    --updates)   UPDATES=true; shift ;;
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
CFG_PATH="$APP_DIR/seren-corpus-callosum.yaml"
CONNECT_HOST="$HOST"
[[ "$HOST" == "0.0.0.0" ]] && CONNECT_HOST="127.0.0.1"
[[ -n "$INSTANCE" && "$PORT" == "7423" ]] && warn "Instance '$INSTANCE' uses default port 7423 — may collide."

echo -e "${G}==========================================${NC}"
$IS_MAC && echo -e "${G}  SerenCorpusCallosum setup (macOS)${NC}" || echo -e "${G}  SerenCorpusCallosum setup (Linux)${NC}"
echo -e "${G}==========================================${NC}"

# -- 1. find Python (3.10+; no upper cap — SCC never pulls torch) -------------
step "Finding a usable Python (3.10+)"
PYBIN=""
for cand in python3.13 python3.12 python3.11 python3.10 python3 python; do
  if command -v "$cand" >/dev/null 2>&1; then
    ver="$("$cand" -c 'import sys; print("%d.%d"%sys.version_info[:2])' 2>/dev/null || echo "")"
    case "$ver" in 3.10|3.11|3.12|3.13) PYBIN="$cand"; break ;; esac
  fi
done
[[ -z "$PYBIN" ]] && die "No Python 3.10+ found. Install one (brew/apt/dnf)."
PYVER="$("$PYBIN" -c 'import sys; print("%d.%d.%d"%sys.version_info[:3])')"
ok "Using $PYBIN (Python $PYVER)"

[[ -n "$REF" && -z "$REPO" ]] && REPO="ChadRoesler/SerenCorpusCallosum"

# -- 2. resolve wheel ----------------------------------------------------------
PACKAGE="seren-corpus-callosum"
resolve_wheel

# -- 3. venv -------------------------------------------------------------------
create_venv "$VENV_DIR"
VPY="$VENV_DIR/bin/python"

# -- extras + install ----------------------------------------------------------
EXTRAS_LIST=()
$MCP  && EXTRAS_LIST+=("mcp")
$CORP && EXTRAS_LIST+=("corp")
$UPDATES && EXTRAS_LIST+=("updates")
EXTRAS=""
[[ ${#EXTRAS_LIST[@]} -gt 0 ]] && EXTRAS="[$(IFS=,; echo "${EXTRAS_LIST[*]}")]"
CORP_ARGS="$(pip_corp_args)"
pip_install "$VPY" "$WHEEL_SRC" "$EXTRAS" "$CORP_ARGS" " (web stack + httpx$($MCP && echo " + MCP SDK")$($CORP && echo " + truststore"))"

# -- 4. sanity check (import; verify MCP extra if --mcp) ------------------------
step "Sanity-checking the install"
CHECK="$("$VPY" - "$($MCP && echo 1 || echo 0)" <<'PY'
import sys
want_mcp = sys.argv[1] == "1"
try:
    import seren_corpus_callosum  # noqa: F401
except Exception as e:
    print(f"IMPORT_FAILED: {e}"); raise SystemExit
if want_mcp:
    try:
        import mcp  # noqa: F401
    except Exception:
        print("MCP_MISSING"); raise SystemExit
    print("OK_MCP")
else:
    print("OK")
PY
)"
case "$CHECK" in
  OK)     ok "Package imports cleanly" ;;
  OK_MCP) ok "Package imports + the MCP SDK is present (/mcp surface will mount)" ;;
  MCP_MISSING) die "Package installed but [mcp] extra didn't land. Re-run with --mcp or:\n  $VPY -m pip install 'seren-corpus-callosum[mcp]'" ;;
  *) die "Install looks broken: $CHECK" ;;
esac

# -- 5. config --------------------------------------------------------------
step "Writing config at $CFG_PATH"
mkdir -p "$APP_DIR"
$GEN_TOKEN && TOKEN="$("$VPY" -c 'import secrets; print(secrets.token_urlsafe(32))')"
[[ -f "$CFG_PATH" ]] && cp "$CFG_PATH" "$CFG_PATH.bak.$(date +%s)" && warn "Existing config backed up"
cat > "$CFG_PATH" <<YAML
# SerenCorpusCallosum config - generated by seren-corpus-callosum-setup.sh
# Full reference: see seren-corpus-callosum.yaml.sample in the repo.
server:
  host: ${HOST}
  port: ${PORT}
  bearer_token: "${TOKEN}"

federation:
  stores:
    - name: memory
      type: seren_memory
      url: http://127.0.0.1:7420
    - name: loci
      type: seren_loci
      url: http://127.0.0.1:7422
$( $CORP && printf '\ntls:\n  trust_system_store: true\n' )
YAML
[[ -n "$TOKEN" ]] && chmod 600 "$CFG_PATH"
ok "Config written (pre-wired to fan memory:7420 + loci:7422)"

# -- 5b. launcher -----------------------------------------------------------
write_launcher "$APP_DIR" "seren-corpus-callosum" "$VPY" "seren_corpus_callosum" "$CFG_PATH"

# -- 6. optional autostart ----------------------------------------------------
$INSTALL_SERVICE && setup_autostart "$SCRIPT_DIR" "seren-corpus-callosum" "$APP_DIR" "$TOKEN" "$INSTANCE" "$VENV_DIR"

# -- done -------------------------------------------------------------------
echo
echo -e "${G}==========================================${NC}"
echo -e "${G}  SerenCorpusCallosum is set up ✓${NC}"
echo -e "${G}==========================================${NC}"
if ! $INSTALL_SERVICE; then
  echo -e "  Start it:        ${B}$APP_DIR/run-seren-corpus-callosum.sh${NC}"
fi
echo -e "  Fan/search:      ${B}POST http://${CONNECT_HOST}:${PORT}/search${NC}"
echo -e "  Health:          ${B}http://${CONNECT_HOST}:${PORT}/health${NC}"
echo -e "  VSCode plugin:   set endpoint to ${B}http://${CONNECT_HOST}:${PORT}${NC}"
[[ -n "$TOKEN" ]] && echo -e "  Bearer token:    ${Y}${TOKEN}${NC}"
echo
$MCP  && echo -e "  MCP endpoint:    ${B}http://${CONNECT_HOST}:${PORT}/mcp/${NC}  (tool: search)"
$CORP && echo -e "  TLS:             ${B}OS trust store${NC}"
echo -e "${G}Rip it and win. 🌭🔧${NC}"

# -- Starwright contract: structured completion event -------------------------
# Human banner above, machine-readable twin here. No-op without --json.
seren_emit_done "$SVC_NAME" "$CONNECT_HOST" "$PORT" "$INSTALL_SERVICE" "${TOKEN:-}"
