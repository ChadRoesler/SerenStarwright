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
#    --sleep-at HH:MM    Bedtime at a wall-clock time (a sleep still waits for a brief)
#    --sleep-every HOURS ...or bedtime every N hours after the last sleep (default ~20)
#    --max-attempts N    The draft cap: attempts per chain, 1-10 (default 3)
#    --model-server PATH The llama-server the hippocampus starts when a sleep needs it
#                        (default on a node: ~/llama.cpp/build/bin/llama-server)
#    --model-path PATH   The .gguf it serves. With a server this turns on management:
#                        started for a sleep, stopped when idle. Host and port from --model-url
#    --model-max-tokens N  The cap on one answer from the small model (default 2000).
#                        Too low and answers are cut off mid-operation; keep it
#                        under the context the server was started with
#    --keep-warm SECS    How long a started model stays up after its last call before
#                        the hippocampus stops it (default 300; a review and a
#                        redraft reuse it)
#    --model-args ARGS   The rest of the server line (default "-ngl 99 -c 8192")
#    --ripple TYPE       Ask the model at bedtime and when drafts wait: script | endpoint | off
#    --ripple-command C  The script ripple's command (default: claude -p "{message}")
#    --ripple-url URL    The endpoint ripple's url (the model box's Observatory:
#                        http://<desktop>:7777/api/v1/system/ripple)
#    --ripple-token TOK  The bearer for --ripple-url (that Observatory's token)
#    --ripple-claude DIR Wake Claude Code as the model: `claude -p` run in DIR (the
#                        project its memory MCP servers are registered for) with those
#                        servers' tools pre-approved - read from ~/.claude.json. A script
#                        ripple; implies --ripple script
#    --voice-card        Turn on the voice card (opt in): a short text the main model
#                        writes about itself - voice, pronouns, whose experience is
#                        whose - carried by every draft prompt. The model writes it
#                        (set_voice_card over MCP); this only turns it on
#    --ripple-stdin      A script ripple sends the message on stdin, not as {message}:
#                        for `ssh desktop claude -p` with no Lodestar or Observatory
#    --ripple-run-as U   Whose account a script ripple runs as (default: you, the
#                        person running this - a root service drops to you)
#    --repo-dir PATH     SerenHippocampus checkout    (default: sibling ../SerenHippocampus)
#    --wheel PATH        Install from a local .whl
#    --local DIR|URL     Install from a dev wheelhouse (seren-dev-publish.sh)
#    --pypi              Install seren-hippocampus from PyPI
#    --ref TAG           Pin to a GitHub release tag
#    --repo SLUG         GitHub release repo
#    --service           Autostart via systemd/launchd
#    --mcp               Install the [mcp] extra: the sleep's tools at /mcp for the main model
#    --claude-mcp        Register this service with Claude Code at user scope (every
#                        folder) as <instance>-hippocampus; the bearer is read from this
#                        config when Claude connects. Implies --mcp
#    --corp              Route TLS through OS trust store
#    --instance NAME     Instance name
#    --root DIR     Install root: venvs, apps, stores, logs in one folder
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
SLEEP_AT=""
SLEEP_EVERY=""
MAX_ATTEMPTS=""
MODEL_SERVER=""
MODEL_PATH=""
MODEL_ARGS=""
KEEP_WARM=""
MODEL_MAX_TOKENS=""
RIPPLE=""
RIPPLE_COMMAND=""
RIPPLE_URL=""
RIPPLE_TOKEN=""
RIPPLE_RUN_AS=""
RIPPLE_STDIN=false
VOICE_CARD=false
RIPPLE_CLAUDE=""
REPO_DIR="$(find_upward "SerenHippocampus" || true)"   # sibling checkout (build source)
WHEEL=""
LOCAL=""
USE_PYPI=false
REF=""
REPO=""
INSTALL_SERVICE=false
SERVICE_USER=""
MCP=false
CLAUDE_MCP=false
CORP=false
UPDATES_OFF=false
INSTANCE=""
# Starwright's install root (~/seren/<install>): venvs, apps, stores and
# logs under one folder, absolute paths. Empty = the old layout.
ROOT=""
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
SVC_CHOICES="ripple=script|endpoint|off"

SEREN_INSTALL_ARGV="$(printf '%s
' "$@")"     # recorded on the install record, minus secrets
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
    --sleep-at)     SLEEP_AT="$2"; shift 2 ;;
    --sleep-every)  SLEEP_EVERY="$2"; shift 2 ;;
    --max-attempts) MAX_ATTEMPTS="$2"; shift 2 ;;
    --model-server) MODEL_SERVER="$2"; shift 2 ;;
    --model-path)   MODEL_PATH="$2"; shift 2 ;;
    --model-args)   MODEL_ARGS="$2"; shift 2 ;;
    --keep-warm)    KEEP_WARM="$2"; shift 2 ;;
    --model-max-tokens) MODEL_MAX_TOKENS="$2"; shift 2 ;;
    --ripple)       RIPPLE="$2"; shift 2 ;;
    --ripple-command) RIPPLE_COMMAND="$2"; shift 2 ;;
    --ripple-url)   RIPPLE_URL="$2"; shift 2 ;;
    --ripple-token) RIPPLE_TOKEN="$2"; shift 2 ;;
    --ripple-run-as) RIPPLE_RUN_AS="$2"; shift 2 ;;
    --ripple-stdin) RIPPLE_STDIN=true; shift ;;
    --voice-card) VOICE_CARD=true; shift ;;
    --ripple-claude) RIPPLE_CLAUDE="$2"; shift 2 ;;
    --repo-dir)     REPO_DIR="$2"; shift 2 ;;
    --wheel)        WHEEL="$2"; shift 2 ;;
    --local)        LOCAL="$2"; shift 2 ;;
    --pypi)         USE_PYPI=true; shift ;;
    --ref)          REF="$2"; shift 2 ;;
    --repo)         REPO="$2"; shift 2 ;;
    --service)      INSTALL_SERVICE=true; shift ;;
    --mcp)          MCP=true; shift ;;
    --claude-mcp) CLAUDE_MCP=true MCP=true; shift ;;
    --corp)         CORP=true; shift ;;
    --no-updates)   UPDATES_OFF=true; shift ;;
    --service-user) SERVICE_USER="$2"; shift 2 ;;
    --instance)     INSTANCE="$2"; shift 2 ;;
    --root)        ROOT="$2"; shift 2 ;;
    --venv)         VENV_DIR="$2"; shift 2 ;;
    --json)         seren_json_on; shift ;;
    --describe)     seren_describe; exit 0 ;;
    -h|--help)      awk 'NR>1{ if (/^#/) { sub(/^# ?/,""); print } else exit }' "$0"; exit 0 ;;
    *)              die "unknown flag: $1  (try --help)" ;;
  esac
done

seren_layout "hippocampus"

# Bedtime and the draft cap. Checked here so a typo fails the install with its
# reason instead of a service that quietly falls back to defaults.
if [[ -n "$SLEEP_AT" ]]; then
  [[ "$SLEEP_AT" =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ]] || die "--sleep-at wants HH:MM (local time), got '$SLEEP_AT'"
fi
SLEEP_EVERY_SECONDS=""
if [[ -n "$SLEEP_EVERY" ]]; then
  SLEEP_EVERY_SECONDS="$(awk -v h="$SLEEP_EVERY" 'BEGIN { if (h+0 > 0) printf "%d", h*3600 }')"
  [[ -n "$SLEEP_EVERY_SECONDS" && "$SLEEP_EVERY_SECONDS" -ge 600 ]] || die "--sleep-every wants hours (at least 0.17, ten minutes), got '$SLEEP_EVERY'"
fi
if [[ -n "$MAX_ATTEMPTS" ]]; then
  [[ "$MAX_ATTEMPTS" =~ ^[0-9]+$ && "$MAX_ATTEMPTS" -ge 1 && "$MAX_ATTEMPTS" -le 10 ]] || die "--max-attempts wants 1-10, got '$MAX_ATTEMPTS'"
fi
[[ -z "$KEEP_WARM" || "$KEEP_WARM" =~ ^[0-9]+$ ]] || die "--keep-warm wants seconds, got '$KEEP_WARM'"
[[ -z "$MODEL_MAX_TOKENS" || ( "$MODEL_MAX_TOKENS" =~ ^[0-9]+$ && "$MODEL_MAX_TOKENS" -ge 256 ) ]]   || die "--model-max-tokens wants a number of tokens, 256 or more, got '$MODEL_MAX_TOKENS'"
# Refused here, before anything is installed, like the sleep flags above.
RIPPLE_CLAUDE_LINES=""
if [[ -n "$RIPPLE_CLAUDE" ]]; then
  [[ -z "$RIPPLE" ]] && RIPPLE=script
  [[ "$RIPPLE" == script ]] || die "--ripple-claude wakes Claude Code on THIS box (a script ripple). For a model on another box, point --ripple endpoint at its Observatory or Lodestar and give that card --ripple-claude"
  RIPPLE_CLAUDE_LINES="$(seren_claude_ripple_lines "$RIPPLE_CLAUDE" 2 "${RIPPLE_RUN_AS:-${SUDO_USER:-$(id -un)}}")" || exit 1
fi
case "$RIPPLE" in
  ""|off|script) ;;
  endpoint) [[ -n "$RIPPLE_URL" ]] || die "--ripple endpoint needs --ripple-url" ;;
  *) die "--ripple wants script, endpoint or off, got '$RIPPLE'" ;;
esac
if [[ -n "$MODEL_SERVER$MODEL_PATH" && -z "$MODEL_PATH" ]]; then
  die "--model-server needs --model-path (the server and the .gguf it serves go together)"
fi
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
$MCP  && EXTRAS_LIST+=("mcp")
$CORP && EXTRAS_LIST+=("corp")
EXTRAS=""
[[ ${#EXTRAS_LIST[@]} -gt 0 ]] && EXTRAS="[$(IFS=,; echo "${EXTRAS_LIST[*]}")]"
CORP_ARGS="$(pip_corp_args)"
pip_install "$VPY" "$WHEEL_SRC" "$EXTRAS" "$CORP_ARGS" "$($MCP && echo ' (+ MCP SDK)')$($CORP && echo ' (+ truststore)')"
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
if [[ -n "$DATA_DIR" ]]; then STORE_PATH="'$DATA_DIR/state.json'"; else STORE_PATH='~/.seren-hippocampus'${INSTANCE}'/state.json'; fi
# The model lifecycle and the ripple, built before the heredoc so an unset flag
# writes nothing (seren-keep-config.py then carries the old block forward).
# yaml single-quoted: backslashes stay literal, a ' is written ''
_yq() { local v=${1//\'/\'\'}; printf "'%s'" "$v"; }
if [[ -n "$MODEL_PATH" && -z "$MODEL_SERVER" && -x "$HOME/llama.cpp/build/bin/llama-server" ]]; then
  MODEL_SERVER="$HOME/llama.cpp/build/bin/llama-server"      # the node's llama component
fi
MODEL_LIFECYCLE_LINES=""
if [[ -n "$MODEL_SERVER" || -n "$MODEL_PATH" ]]; then
  [[ -n "$MODEL_SERVER" ]] || die "--model-path needs --model-server: no llama-server at ~/llama.cpp/build/bin to default to"
  MODEL_LIFECYCLE_LINES="  lifecycle:
    # Started when a sleep needs it, stopped when idle: <server> -m <model_path>
    # --host/--port (from url) <server_args>.
    server: $(_yq "$MODEL_SERVER")
    model_path: $(_yq "$MODEL_PATH")"
  [[ -n "$MODEL_ARGS" ]] && MODEL_LIFECYCLE_LINES+="
    server_args: $(_yq "$MODEL_ARGS")"
  [[ -n "$KEEP_WARM" ]] && MODEL_LIFECYCLE_LINES+="
    keep_warm_seconds: $KEEP_WARM"
fi
RIPPLE_LINES=""
RIPPLE_DEFAULT_COMMAND='claude -p "{message}"'
case "$RIPPLE" in
  "") ;;
  off)
    RIPPLE_LINES=$(printf '\nripple:\n  type: ""                  # off; --ripple script|endpoint turns it back on')
    ;;
  script)
    # Inferred at setup (Chad, 28 Sept 2026): the person running the install is
    # whose login the command needs. A root service drops to them (runuser).
    RIPPLE_WHO="${RIPPLE_RUN_AS:-${SUDO_USER:-$(id -un)}}"
    if [[ -n "${RIPPLE_CLAUDE_LINES:-}" ]]; then
      # Claude Code, read off this box: run in the project, memory tools pre-approved.
      RIPPLE_LINES=$(printf '\nripple:\n  # At bedtime and when drafts wait, the hippocampus wakes Claude Code.\n  type: script\n%s\n  run_as: %s' \
        "$RIPPLE_CLAUDE_LINES" "$(_yq "$RIPPLE_WHO")")
    else
      RIPPLE_LINES=$(printf '\nripple:\n  # At bedtime and when drafts wait, the hippocampus asks the model.\n  type: script\n  command: %s\n  run_as: %s' \
        "$(_yq "${RIPPLE_COMMAND:-$RIPPLE_DEFAULT_COMMAND}")" "$(_yq "$RIPPLE_WHO")")
    fi
    [[ "${RIPPLE_STDIN:-false}" == true ]] && RIPPLE_LINES+=$(printf '\n  stdin: true')
    ;;
  endpoint)
    # The model lives on another box: its Observatory receives the ripple and
    # starts the command there, as the person (POST /api/v1/system/ripple).
    RIPPLE_LINES=$(printf '\nripple:\n  type: endpoint\n  url: %s' "$(_yq "$RIPPLE_URL")")
    [[ -n "$RIPPLE_TOKEN" ]] && RIPPLE_LINES+=$(printf '\n  bearer_token: %s' "$(_yq "$RIPPLE_TOKEN")")
    ;;
esac

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
$([[ -n "$MODEL_MAX_TOKENS" ]] && printf '  max_tokens: %s' "$MODEL_MAX_TOKENS" || printf '  # max_tokens: 2000            # the cap on one answer; too low and answers are cut off')
${MODEL_LIFECYCLE_LINES}

sleep:
  mode: thread
  state_path: ${STORE_PATH}
  # BEDTIME, not a timer: a sleep fires whenever the main model has left a
  # brief, any hour. Bedtime is when the hippocampus starts counting checks
  # that find none and, after enough, asks for one. Either a wall-clock time
  # (local HH:MM)...
$([[ -n "$SLEEP_AT" ]] && printf '  at: "%s"' "$SLEEP_AT" || printf '  # at: "03:30"')
  # ...or every N hours after the last sleep (the default, ~20h: not 24, so it drifts through the day).
$([[ -n "$SLEEP_EVERY_SECONDS" ]] && printf '  interval_seconds: %s' "$SLEEP_EVERY_SECONDS" || printf '  # interval_seconds: 72000')
  # The draft cap: attempts per chain before the last is terminal (the reviewer
  # may then edit on approve; a denial ends the chain). 1-10.
$([[ -n "$MAX_ATTEMPTS" ]] && printf '  max_attempts: %s' "$MAX_ATTEMPTS" || printf '  # max_attempts: 3')
YAML
[[ -n "$TOKEN" || -n "$MEMORY_TOKEN_LINES" ]] && chmod 600 "$CFG_PATH"
if [[ -n "$RIPPLE_LINES" ]]; then echo "$RIPPLE_LINES" >> "$CFG_PATH"; fi
# The voice card is opt in, and the model writes it; the config only turns it on.
$VOICE_CARD && printf '\nvoice:\n  # The voice card: the model writes it (set_voice_card); every version is kept.\n  enabled: true\n' >> "$CFG_PATH"
[[ -n "$RIPPLE_TOKEN" ]] && chmod 600 "$CFG_PATH"

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
$INSTALL_SERVICE && setup_autostart "$SCRIPT_DIR" "seren-hippocampus" "$APP_DIR" "$TOKEN" "$SVC_SUFFIX" "$VENV_DIR" "$SERVICE_USER"
$CLAUDE_MCP && seren_claude_mcp_register "hippocampus"

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
$MCP && echo -e "  MCP endpoint:    ${B}http://${CONNECT_HOST}:${PORT}/mcp/${NC}"
echo
echo -e "  ${Y}Sleeps every ~20h; tends denied operations every 5 minutes.${NC}"
echo -e "${G}Rip it and win. 🌭🔧${NC}"

seren_emit_done "$SVC_NAME" "$CONNECT_HOST" "$PORT" "$INSTALL_SERVICE" "${TOKEN:-}"
