#!/usr/bin/env bash
# ==========================================================================
#  seren-symposium-setup.sh  -  one-shot SerenSymposium installer (Linux + macOS)
#
#  Twin of seren-symposium-setup.ps1. The desktop front door: one window,
#  chat in the first tab and the other services' own pages in the rest. A
#  CLIENT, not a service - it serves its own UI on 127.0.0.1, talks to
#  Lodestar, and installs no autostart. A chat is answered by a local model
#  through Lodestar, or (voice: claude) by the claude CLI on this box.
#
#  Lodestar: --lodestar-config (Starwright hands over a sibling's config
#  path; url and bearer are read from it) or --lodestar-url for one on
#  another box, its token from $SEREN_LODESTAR_TOKEN - never a flag. Neither:
#  the config keeps the Lodestar it had (127.0.0.1:6361 on a first install).
#
#  USAGE
#    bash seren-symposium-setup.sh --lodestar-config ~/seren/x/apps/lodestar/seren-lodestar.yaml
#    SEREN_LODESTAR_TOKEN=... bash seren-symposium-setup.sh --lodestar-url http://node-a:6361
#    bash seren-symposium-setup.sh --voice claude --claude-name alice --claude-tools 'mcp__workbench__*'
#
#  FLAGS
#    --port N                Loopback UI port              (default 7426)
#    --host HOST             UI bind address (loopback; past it Symposium
#                            refuses to start without ui.allow_open_lan)
#    --lodestar-config PATH  The Lodestar on this box: its config
#    --lodestar-url URL      A Lodestar on another box ($SEREN_LODESTAR_TOKEN)
#    --voice lodestar|claude Who answers in the starter project (first install)
#    --claude-name NAME      What the claude voice's answers are signed as
#    --claude-cwd DIR        Where the claude CLI runs (its project settings)
#    --claude-tools LIST     Tools it may use without asking, comma-separated
#    --no-window             No native window: serve to a browser instead
#    --no-shortcut           No application-menu entry
#    --corp                  Install the [corp] extra (OS trust store)
#    --wheel PATH            Install from a local .whl
#    --local DIR|URL         Install from a dev wheelhouse (seren-dev-publish.sh)
#    --ref TAG               Pin to a GitHub release tag
#    --repo SLUG             GitHub release repo
#    --instance NAME         Instance name
#    --root DIR              Install root: venvs, apps, stores, logs in one folder
#    --venv PATH             Override venv location
#    --no-updates            Turn update checking OFF in the generated config
#    -h, --help              This help
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
PORT=7426
HOST="127.0.0.1"
LODESTAR_CONFIG=""
LODESTAR_URL=""
VOICE="lodestar"
CLAUDE_NAME=""
CLAUDE_CWD=""
CLAUDE_TOOLS=""
NO_WINDOW=false
NO_SHORTCUT=false
WHEEL=""
LOCAL=""
REF=""
REPO=""
UPDATES_OFF=false
INSTANCE=""
# Starwright's install root (~/seren/<install>): venvs, apps, stores and
# logs under one folder, absolute paths. Empty = the old layout.
ROOT=""
VENV_DIR="$HOME/seren-venvs/symposium"
APP_DIR="$HOME/seren-symposium"
CORP=false

# -- Starwright contract: identity + machine-readable metadata ----------------
SVC_NAME="seren-symposium"
SVC_DISPLAY="Seren Symposium"
SVC_DESC="The desktop front door: chat, projects, the viewers"
SVC_GROUP="desktop"
SVC_PACKAGE="seren-symposium"
# Card colour in Seren Starwright - matches seren_symposium/app.py ACCENT
SVC_ACCENT="#a3b18a"
# [desktop] is not a pick-list extra: it is on unless --no-window.
SVC_EXTRAS="corp"
SVC_RECOMMENDS="seren-lodestar"
SVC_CHOICES="voice=lodestar|claude"
# A Lodestar on another box presents a token; it rides in the environment,
# never on a command line.
SVC_SECRETS="lodestar-token=SEREN_LODESTAR_TOKEN"

# --describe must answer with ZERO side effects.
SEREN_INSTALL_ARGV="$(printf '%s\n' "$@")"     # recorded on the install record, minus secrets
for _a in "$@"; do
  [[ "$_a" == "--describe" ]] && { seren_describe; exit 0; }
done

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)            PORT="$2"; shift 2 ;;
    --host)            HOST="$2"; shift 2 ;;
    --lodestar-config) LODESTAR_CONFIG="$2"; shift 2 ;;
    --lodestar-url)    LODESTAR_URL="$2"; shift 2 ;;
    --voice)           VOICE="$2"; shift 2 ;;
    --claude-name)     CLAUDE_NAME="$2"; shift 2 ;;
    --claude-cwd)      CLAUDE_CWD="$2"; shift 2 ;;
    --claude-tools)    CLAUDE_TOOLS="$2"; shift 2 ;;
    --no-window)       NO_WINDOW=true; shift ;;
    --no-shortcut)     NO_SHORTCUT=true; shift ;;
    --wheel)           WHEEL="$2"; shift 2 ;;
    --local)           LOCAL="$2"; shift 2 ;;
    --ref)             REF="$2"; shift 2 ;;
    --repo)            REPO="$2"; shift 2 ;;
    --no-updates)      UPDATES_OFF=true; shift ;;
    --corp)            CORP=true; shift ;;
    --instance)        INSTANCE="$2"; shift 2 ;;
    --root)            ROOT="$2"; shift 2 ;;
    --venv)            VENV_DIR="$2"; shift 2 ;;
    --json)            seren_json_on; shift ;;
    --describe)        seren_describe; exit 0 ;;
    -h|--help)         awk 'NR>1{ if (/^#/) { sub(/^# ?/,""); print } else exit }' "$0"; exit 0 ;;
    *)                 die "unknown flag: $1  (try --help)" ;;
  esac
done
[[ "$VOICE" == "lodestar" || "$VOICE" == "claude" ]] || die "--voice is lodestar or claude"

seren_layout "symposium"
CFG_PATH="$APP_DIR/seren-symposium.yaml"
[[ "$HOST" == "127.0.0.1" || "$HOST" == "localhost" || "$HOST" == "::1" ]] ||   warn "--host $HOST is past loopback: Symposium will refuse to start unless ui.allow_open_lan is true in its config (it has no inbound auth)"
[[ -n "$INSTANCE" && "$PORT" == "7426" ]] && warn "Instance '$INSTANCE' uses default port 7426 - may collide."

echo -e "${G}==========================================${NC}"
$IS_MAC && echo -e "${G}  SerenSymposium setup (macOS)${NC}" || echo -e "${G}  SerenSymposium setup (Linux)${NC}"
echo -e "${G}==========================================${NC}"

# -- 1. find Python (3.10+) ----------------------------------------------------
PYBIN="$(find_python)"

[[ -n "$REF" && -z "$REPO" ]] && REPO="ChadRoesler/SerenSymposium"

# -- 2. resolve wheel ----------------------------------------------------------
PACKAGE="seren-symposium"
resolve_wheel

# -- 3. venv + install ---------------------------------------------------------
create_venv "$VENV_DIR"
VPY="$VENV_DIR/bin/python"
EXTRAS_LIST=(); $NO_WINDOW || EXTRAS_LIST+=("desktop"); $CORP && EXTRAS_LIST+=("corp")
EXTRAS=""; [[ ${#EXTRAS_LIST[@]} -gt 0 ]] && EXTRAS="[$(IFS=,; echo "${EXTRAS_LIST[*]}")]"
EXTRAS_DESC=""; $NO_WINDOW || EXTRAS_DESC+=" + window"; $CORP && EXTRAS_DESC+=" + truststore"
CORP_ARGS="$(pip_corp_args)"
pip_install "$VPY" "$WHEEL_SRC" "$EXTRAS" "$CORP_ARGS" "$EXTRAS_DESC"

# -- 4. sanity check (import + the shell's page) -------------------------------
sanity_check "$VPY" "seren_symposium" "ui/index.html"

# -- 5. config --------------------------------------------------------------
# Written whole, like every card's; what it leaves out on purpose - the
# Lodestar it was not told about, the claude settings it was not given, the
# projects - seren-keep-config.py (run by write_launcher) carries forward
# from the backup, so a reinstall never costs a project or a token.
step "Writing config at $CFG_PATH"
mkdir -p "$APP_DIR"
FIRST_INSTALL=true
if [[ -f "$CFG_PATH" ]]; then
  FIRST_INSTALL=false
  cp "$CFG_PATH" "$CFG_PATH.bak.$(date +%s)" && warn "Existing config backed up"
fi

LODESTAR_BLOCK=""
VIEWER_URL=""
if [[ -n "$LODESTAR_CONFIG" ]]; then
  if seren_read_sibling_config "$LODESTAR_CONFIG" && [[ -n "$SIB_URL" ]]; then
    LODESTAR_BLOCK="lodestar:"$'\n'"  url: $SIB_URL"$'\n'"$(seren_sibling_token_lines '  ')"
    VIEWER_URL="$SIB_URL"
    ok "Lodestar: $SIB_URL (from its config)"
  fi
elif [[ -n "$LODESTAR_URL" ]]; then
  LODESTAR_BLOCK="lodestar:"$'\n'"  url: $LODESTAR_URL"
  if [[ -n "${SEREN_LODESTAR_TOKEN:-}" ]]; then
    LODESTAR_BLOCK+=$'\n'"  bearer_token: \"$SEREN_LODESTAR_TOKEN\""
  else
    warn "SEREN_LODESTAR_TOKEN is not set, so Symposium will call $LODESTAR_URL without a bearer (fine for an open Lodestar; in Starwright, Configure > lodestar-token)"
  fi
  VIEWER_URL="${LODESTAR_URL%/}"
  ok "Lodestar: $LODESTAR_URL"
elif $FIRST_INSTALL; then
  warn "No --lodestar-config or --lodestar-url: Symposium will look for Lodestar at 127.0.0.1:6361"
fi

CLAUDE_BLOCK=""
[[ -n "$CLAUDE_NAME" ]] && CLAUDE_BLOCK+=$'\n'"  name: \"$CLAUDE_NAME\""
[[ -n "$CLAUDE_CWD" ]]  && CLAUDE_BLOCK+=$'\n'"  cwd: '$CLAUDE_CWD'"
if [[ -n "$CLAUDE_TOOLS" ]]; then
  # -p has nobody to answer a permission prompt: with a list, the CLI asks
  # (and so refuses) for everything not on it.
  TOOLS_YAML=""
  IFS=',' read -ra _tools <<<"$CLAUDE_TOOLS"
  for t in "${_tools[@]}"; do
    t="$(echo "$t" | xargs)"; [[ -n "$t" ]] && TOOLS_YAML+="${TOOLS_YAML:+, }\"$t\""
  done
  CLAUDE_BLOCK+=$'\n'"  permission_mode: \"default\""$'\n'"  allowed_tools: [$TOOLS_YAML]"
fi
[[ -n "$CLAUDE_BLOCK" ]] && CLAUDE_BLOCK="claude:$CLAUDE_BLOCK"
command -v claude >/dev/null 2>&1 || warn "No claude CLI on this box's PATH: the claude voice will show as unavailable (install Claude Code to use it)"

SESSIONS_BLOCK=""
[[ -n "$DATA_DIR" ]] && SESSIONS_BLOCK="sessions:"$'\n'"  dir: '$DATA_DIR/sessions'"

# The starter project, on a first install only. After that the projects are
# the operator's, and keep-config puts every one of them back.
FOLDERS_BLOCK=""
$FIRST_INSTALL && FOLDERS_BLOCK="folders:"$'\n'"  - name: \"Main\""$'\n'"    voice: \"$VOICE\""

VIEWER_BLOCK=""
[[ -n "$VIEWER_URL" ]] && VIEWER_BLOCK="viewers:"$'\n'"  cluster: \"$VIEWER_URL/viewer\""

cat > "$CFG_PATH" <<YAML
# SerenSymposium config - generated by seren-symposium-setup.sh
# Full reference: see seren-symposium.yaml.sample in the repo.
${LODESTAR_BLOCK}

ui:
  host: ${HOST}
  port: ${PORT}
$( $CORP && printf 'tls:\n  trust_system_store: true\n' )
${SESSIONS_BLOCK}

${CLAUDE_BLOCK}

${VIEWER_BLOCK}

${FOLDERS_BLOCK}
YAML

$UPDATES_OFF && cat >> "$CFG_PATH" <<'YAML'

# ── Update checking ───────────────────────────────────────────────────
# Turned OFF at install time by --no-updates. Flip this to true to turn it
# back on, or set SEREN_SYMPOSIUM_UPDATES_ENABLED=true in the environment.
updates:
  enabled: false
YAML
ok "Config written"

# -- 5b. launcher -----------------------------------------------------------
write_launcher "$APP_DIR" "seren-symposium" "$VPY" "seren_symposium" "$CFG_PATH"
# Locked AFTER the launcher: keep-config (which it runs) may have put back a
# Lodestar bearer this run was never given, and a file holding one is a file
# only its owner reads, however the bearer got there.
grep -qE '^[[:space:]]+bearer_token:[[:space:]]*"?[^"[:space:]]' "$CFG_PATH" && chmod 600 "$CFG_PATH"

# -- 6. an application-menu entry (Linux) -------------------------------------
# Not an autostart - Symposium is something you open, not something that runs.
SHORTCUT=""
if ! $NO_SHORTCUT && ! $NO_WINDOW && ! $IS_MAC; then
  apps="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
  mkdir -p "$apps"
  SHORTCUT="$apps/seren-symposium${INSTANCE:+-$INSTANCE}.desktop"
  cat > "$SHORTCUT" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Seren Symposium${INSTANCE:+ ($INSTANCE)}
Comment=The Seren desktop front door
Exec="$VPY" -m seren_symposium --config "$CFG_PATH"
Path=$APP_DIR
Terminal=false
Categories=Network;Chat;
DESKTOP
  ok "Application menu entry: $SHORTCUT"
fi

# -- done -------------------------------------------------------------------
echo
echo -e "${G}==========================================${NC}"
echo -e "${G}  SerenSymposium is set up ✓${NC}"
echo -e "${G}==========================================${NC}"
echo -e "  Open it:          ${B}$APP_DIR/run-seren-symposium.sh${NC}"
$NO_WINDOW && echo -e "  Then browse to:   ${B}http://127.0.0.1:${PORT}/${NC}"
echo -e "  Config:           ${B}$CFG_PATH${NC}"
echo -e "${G}Rip it and win. 🌭🔧${NC}"

# -- Starwright contract: structured completion event -------------------------
seren_emit_done "$SVC_NAME" "127.0.0.1" "$PORT" "false" ""
