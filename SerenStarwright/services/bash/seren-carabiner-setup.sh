#!/usr/bin/env bash
# ==========================================================================
#  seren-carabiner-setup.sh  -  clip a model's harness onto Seren (Linux + macOS)
#
#  A carabiner (.kbh, SerenCarabiners) is one standalone file per harness -
#  claude.kbh for Claude Code - that answers register, wake, bookmark, due and
#  belay. This card puts one on THIS box, the box the harness runs on, and
#  configures it from the standard things Starwright already knows: where the
#  Workbench is (the one MCP door), where Margin is (the bookmark), which
#  folder the model works in, which python runs it from hooks.
#
#  It is not a service: no venv, no port, no unit. It writes:
#    <into>/<carabiner>.kbh          the carabiner itself
#    <into>/<carabiner>.yaml         how it rolls here (pushed out of the .kbh, filled in)
#    <into>/framing.md               the first words a woken session reads; yours to edit
#    <into>/connections/*.yaml       one per Seren service: host, port, token pointer
#  then runs `register apply`, `bookmark install` and `belay`.
#
#  USAGE
#    bash seren-carabiner-setup.sh --project ~/work --workbench-config ~/seren-workbench/seren-workbench.yaml
#    bash seren-carabiner-setup.sh --carabiner claude --kbh ./dist/claude.kbh --into ~/seren/kbh --project ~/work
#    bash seren-carabiner-setup.sh --ref v0.1.0 ...        # the .kbh from a SerenCarabiners release
#
#  FLAGS
#    --carabiner NAME        Which harness: claude            (default claude)
#    --project DIR           The folder the model works in; wakes run there
#                            (default: the home folder)
#    --python PATH           The python that runs the .kbh from hooks and
#                            ripples (default: the one found here)
#    --into DIR              Where the clip lives (default: <root>/kbh, or ~/seren-kbh)
#    --workbench-url URL     The Workbench on another box: its url, dropped into
#                            the clip's yaml as a ROUTE; the token comes from
#                            $SEREN_WORKBENCH_TOKEN (never on a command line)
#    --margin-url URL        Margin on another box, the same way; token from
#                            $SEREN_MARGIN_TOKEN
#    --workbench-config PATH The Workbench ON THIS BOX: its own config, read for
#                            the route (the TUI hands this over from the ledger)
#    --margin-config PATH    Margin on this box, the same way
#    --host HOST             With a config from another box: the host this box
#                            dials (a config says 0.0.0.0; this box needs a name)
#    --server NAME=FILE|URL  Another server to register; repeatable. A URL is a
#                            route (token from $KBH_TOKEN_<NAME>), else a
#                            connection file in <into>/connections
#    --kbh PATH              Install this .kbh file
#    --local DIR|URL         A dev wheelhouse (seren-dev-publish.sh) that holds
#                            <carabiner>.kbh beside the wheels
#    --ref TAG               The .kbh from a SerenCarabiners GitHub release
#    --repo SLUG             That repo                    (default ChadRoesler/SerenCarabiners)
#    --repo-dir PATH         A SerenCarabiners checkout to build the .kbh from
#                            (default: a sibling of this checkout)
#    --dry-wake              Belay also runs the harness binary once (--version)
#    --instance NAME         Instance name: the registered server is <instance>-workbench
#    --root DIR              Install root (Starwright layout); the clip goes in <root>/kbh
#    -h, --help              This help
# ==========================================================================
set -euo pipefail

OS="$(uname -s)"
IS_MAC=false
[[ "$OS" == "Darwin" ]] && IS_MAC=true
# The lib's find_upward walks up from here (it shadows the bootstrap one below).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; B='\033[0;34m'; NC='\033[0m'
step() { echo -e "\n${B}==>${NC} $1"; }
ok()   { echo -e "${G}  ✓${NC} $1"; }
warn() { echo -e "${Y}  !${NC} $1"; }
die()  { echo -e "${R}ERROR:${NC} $1"; exit 1; }

# -- locate a file by walking UP the tree ---------------------------------------
find_upward() {
  local rel="$1" dir
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  while [[ -n "$dir" && "$dir" != "/" ]]; do
    [[ -e "$dir/$rel" ]] && { echo "$dir/$rel"; return 0; }
    dir="$(dirname "$dir")"
  done
  return 1
}
LIB="$(find_upward "services/lib/seren-install-lib.sh")" || die "seren-install-lib.sh not found. Keep services/lib/ with shared scripts."
# shellcheck source=/dev/null
source "$LIB"

# -- defaults ----------------------------------------------------------------
CARABINER="claude"
PROJECT=""
PYTHON=""
INTO=""
WORKBENCH_CONFIG=""
MARGIN_CONFIG=""
WORKBENCH_URL=""
MARGIN_URL=""
CONNECT_TO=""
SERVERS=()
KBH=""
LOCAL=""
REF=""
REPO=""
REPO_DIR=""
DRY_WAKE=false
INSTANCE=""
ROOT=""
HOST=""
PORT=0

# -- Starwright contract: identity + machine-readable metadata ----------------
SVC_NAME="seren-carabiner"
SVC_DISPLAY="Seren Carabiner"
SVC_DESC="Clip a model's harness (Claude Code) onto Seren"
SVC_GROUP="carabiners"
SVC_PACKAGE="seren-carabiners"
# A climbing carabiner: anodised blue.
SVC_ACCENT="#2f6fb3"
SVC_REQUIRES=""
# Better with both, works with either: the Workbench is the door the harness
# is registered at, Margin is the bookmark. Starwright hands their configs
# over as --workbench-config / --margin-config when they are on the box or in
# the run; with neither, the clip is installed and belay says what is missing.
SVC_RECOMMENDS="seren-workbench seren-margin"
SVC_EXTRAS=""
SVC_CHOICES="carabiner=claude"

SEREN_INSTALL_ARGV="$(printf '%s\n' "$@")"
for _a in "$@"; do
  [[ "$_a" == "--describe" ]] && { seren_describe; exit 0; }
done

while [[ $# -gt 0 ]]; do
  case "$1" in
    --carabiner)        CARABINER="$2"; shift 2 ;;
    --project)          PROJECT="$2"; shift 2 ;;
    --python)           PYTHON="$2"; shift 2 ;;
    --into)             INTO="$2"; shift 2 ;;
    --workbench-config) WORKBENCH_CONFIG="$2"; shift 2 ;;
    --margin-config)    MARGIN_CONFIG="$2"; shift 2 ;;
    --workbench-url)    WORKBENCH_URL="$2"; shift 2 ;;
    --margin-url)       MARGIN_URL="$2"; shift 2 ;;
    --host)             CONNECT_TO="$2"; shift 2 ;;
    --server)           SERVERS+=("$2"); shift 2 ;;
    --kbh)              KBH="$2"; shift 2 ;;
    --local)            LOCAL="$2"; shift 2 ;;
    --ref)              REF="$2"; shift 2 ;;
    --repo)             REPO="$2"; shift 2 ;;
    --repo-dir)         REPO_DIR="$2"; shift 2 ;;
    --dry-wake)         DRY_WAKE=true; shift ;;
    --instance)         INSTANCE="$2"; shift 2 ;;
    --root)             ROOT="$2"; shift 2 ;;
    --json)             seren_json_on; shift ;;
    --describe)         seren_describe; exit 0 ;;
    -h|--help)          awk 'NR>1{ if (/^#/) { sub(/^# ?/,""); print } else exit }' "$0"; exit 0 ;;
    *)                  die "unknown flag: $1  (try --help)" ;;
  esac
done

[[ "$CARABINER" =~ ^[a-z][a-z0-9_]{1,31}$ ]] || die "--carabiner must be lower_snake_case: $CARABINER"
if [[ -z "$INTO" ]]; then
  if [[ -n "$ROOT" ]]; then ROOT="${ROOT/#\~/$HOME}"; INTO="$ROOT/kbh"; else INTO="$HOME/seren-kbh"; fi
fi
INTO="${INTO/#\~/$HOME}"
[[ -n "$PROJECT" ]] || PROJECT="$HOME"
PROJECT="${PROJECT/#\~/$HOME}"
[[ -d "$PROJECT" ]] || die "--project is not a folder: $PROJECT"
CONNECTIONS="$INTO/connections"
APP_DIR="$INTO"
CFG_PATH="$INTO/$CARABINER.yaml"
PACKAGE="$SVC_PACKAGE"

echo -e "${G}==========================================${NC}"
$IS_MAC && echo -e "${G}  Seren Carabiner setup (macOS)${NC}" || echo -e "${G}  Seren Carabiner setup (Linux)${NC}"
echo -e "${G}==========================================${NC}"

# -- 1. python -------------------------------------------------------------------
# The .kbh is standard-library Python 3.8+. The python named here is also the
# one written into <carabiner>.yaml, so hooks and ripples run the clip with
# it later; a service account's PATH is not the person's, so it is a path.
if [[ -z "$PYTHON" ]]; then PYTHON="$(find_python)"; fi
[[ -x "$PYTHON" || -n "$(command -v "$PYTHON" 2>/dev/null)" ]] || die "python not found: $PYTHON"
PYTHON="$(command -v "$PYTHON")"
ok "Python: $PYTHON"

# -- 2. the .kbh ------------------------------------------------------------------
# Precedence: --kbh > --local (a dev wheelhouse) > --ref (a release asset) >
# build from a checkout.
step "Resolving $CARABINER.kbh"
mkdir -p "$INTO" "$CONNECTIONS"
KBH_SRC=""
if [[ -n "$KBH" ]]; then
  [[ -f "$KBH" ]] || die ".kbh not found: $KBH"
  KBH_SRC="$KBH"
  ok "From file: $KBH"
elif [[ -n "$LOCAL" ]]; then
  case "$LOCAL" in
    http://*|https://*)
      KBH_SRC="$(mktemp -d)/${CARABINER}.kbh"
      curl -fsSL -o "$KBH_SRC" "${LOCAL%/}/${CARABINER}.kbh" || die "no ${CARABINER}.kbh at $LOCAL" ;;
    *)
      LOCAL="${LOCAL#file://}"
      [[ -f "$LOCAL/${CARABINER}.kbh" ]] || die "no ${CARABINER}.kbh in the wheelhouse $LOCAL"
      KBH_SRC="$LOCAL/${CARABINER}.kbh" ;;
  esac
  ok "From the dev wheelhouse at $LOCAL"
elif [[ -n "$REF" ]]; then
  [[ -n "$REPO" ]] || REPO="ChadRoesler/SerenCarabiners"
  url="https://github.com/${REPO}/releases/download/${REF}/${CARABINER}.kbh"
  KBH_SRC="$(mktemp -d)/${CARABINER}.kbh"
  curl -fsSL -o "$KBH_SRC" "$url" || die "could not fetch $url"
  ok "From release $REF of $REPO"
else
  if [[ -z "$REPO_DIR" ]]; then
    # A checkout beside this one, wherever "beside" is: walk up from here.
    REPO_DIR="$(dirname "$(find_upward "SerenCarabiners/build.py" 2>/dev/null || echo /nonexistent/build.py)")"
  fi
  [[ -f "$REPO_DIR/build.py" ]] || die "no SerenCarabiners checkout found (--repo-dir), and no --kbh or --ref given"
  BUILD_OUT="$(mktemp -d)"
  ( cd "$REPO_DIR" && KBH_DIST="$BUILD_OUT" "$PYTHON" build.py "$CARABINER" >/dev/null ) || die "building $CARABINER.kbh from $REPO_DIR failed"
  KBH_SRC="$BUILD_OUT/$CARABINER.kbh"
  ok "Built from $REPO_DIR"
fi
cp "$KBH_SRC" "$INTO/$CARABINER.kbh"
KBH_PATH="$INTO/$CARABINER.kbh"
"$PYTHON" "$KBH_PATH" list >/dev/null || die "$KBH_PATH does not run with $PYTHON"
ok "Installed $KBH_PATH"

# -- 3. routes ------------------------------------------------------------------------
# A route is a url and a token, written INTO the clip's yaml - nothing copied
# from the brain box (drop in the uri and the token). It
# comes one of two ways:
#   --<svc>-url URL      the service is elsewhere; the token is in
#                        $SEREN_<SVC>_TOKEN, and travels to the clip as
#                        $KBH_TOKEN_<NAME>: environment to environment, never argv
#   --<svc>-config PATH  the service is on this box (or its config was copied):
#                        the route is read out of its own config; --host names
#                        the host this box dials when the config says 0.0.0.0
# A sibling that keeps its token in the keyring cannot be a route (the clip
# cannot read that box's keyring), so it stays a connection FILE.
_route() {   # _route LABEL NAME URL CONFIG TOKEN_ENV_VAR -> sets ROUTE_VALUE, ROUTE_POINTER, and the KBH_TOKEN_* env
  local label="$1" name="$2" url="$3" cfg="$4" tokvar="$5" host port token="" pointer=""
  ROUTE_VALUE=""; ROUTE_POINTER=""
  if [[ -n "$url" ]]; then
    token="${!tokvar:-}"
  elif [[ -n "$cfg" ]]; then
    seren_read_sibling_config "$cfg" || { warn "$label: $cfg could not be read"; return 1; }
    [[ -n "$SIB_URL" ]] || { warn "$label: $cfg names no port"; return 1; }
    host="${SIB_URL#http://}"; port="${host##*:}"; host="${host%%:*}"
    [[ -n "$CONNECT_TO" ]] && host="$CONNECT_TO"
    url="http://${host}:${port}"
    token="$SIB_TOKEN"; pointer="$SIB_TOKEN_ENV"
    if [[ -z "$token$pointer" && -n "$SIB_TOKEN_KEYRING" ]]; then
      local file="$CONNECTIONS/${name}.yaml"
      { echo "# A Seren connection file for $label, written by seren-carabiner-setup from $cfg"; echo "server:"
        echo "  url: $url"; seren_sibling_token_lines "  "; } > "$file"
      chmod 600 "$file" 2>/dev/null || true
      ROUTE_VALUE="${name}.yaml"
      ok "$label: $url -> $file (its bearer is a keyring reference, so a file, not a route)"
      return 0
    fi
  else
    return 1
  fi
  local envname; envname="KBH_TOKEN_$(printf '%s' "$name" | tr -c 'A-Za-z0-9' '_' | tr 'a-z' 'A-Z')"
  envname="${envname%_}"
  [[ -n "$token" ]] && export "$envname=$token"
  ROUTE_VALUE="$url"; ROUTE_POINTER="$pointer"
  ok "$label: $url -> a route in the clip's yaml$([[ -n "$token" ]] && echo ', token embedded' || { [[ -n "$pointer" ]] && echo ", token from \$$pointer" || echo ', no token'; })"
  return 0
}
step "Routes"
SERVER_ARGS=()
BOOKMARK_ARG=()
PREFIX="${INSTANCE:+$INSTANCE-}"
WB_NAME="${PREFIX:-seren-}workbench"
if _route "Workbench" "$WB_NAME" "$WORKBENCH_URL" "$WORKBENCH_CONFIG" SEREN_WORKBENCH_TOKEN; then
  SERVER_ARGS+=(--server "$WB_NAME=$ROUTE_VALUE")
  [[ -n "$ROUTE_POINTER" ]] && SERVER_ARGS+=(--server-token-env "$WB_NAME=$ROUTE_POINTER")
else
  warn "No Workbench (--workbench-url or --workbench-config): nothing is registered with the harness. Add one and re-run, or kbh $CARABINER register add later."
fi
if _route "Margin" bookmark "$MARGIN_URL" "$MARGIN_CONFIG" SEREN_MARGIN_TOKEN; then
  BOOKMARK_ARG=(--bookmark "$ROUTE_VALUE")
  [[ -n "$ROUTE_POINTER" ]] && BOOKMARK_ARG+=(--bookmark-token-env "$ROUTE_POINTER")
else
  warn "No Margin (--margin-url or --margin-config): no bookmark at session start."
fi
for s in ${SERVERS[@]+"${SERVERS[@]}"}; do
  [[ "$s" == *=* ]] || die "--server wants NAME=FILE|URL: $s"
  case "${s#*=}" in http://*|https://*) ;; *) [[ -f "$CONNECTIONS/${s#*=}" ]] || warn "--server $s: $CONNECTIONS/${s#*=} does not exist yet" ;; esac
  SERVER_ARGS+=(--server "$s")
done

# -- 4. install: config + framing pushed out, hooks run -----------------------------
step "kbh $CARABINER install"
"$PYTHON" "$KBH_PATH" "$CARABINER" install --into "$INTO" --project "$PROJECT" --python "$PYTHON" \
  --connections "$CONNECTIONS" ${SERVER_ARGS[@]+"${SERVER_ARGS[@]}"} ${BOOKMARK_ARG[@]+"${BOOKMARK_ARG[@]}"} \
  || die "kbh $CARABINER install failed"

# -- 5. register + bookmark ------------------------------------------------------------
if [[ ${#SERVER_ARGS[@]} -gt 0 ]]; then
  step "kbh $CARABINER register apply"
  "$PYTHON" "$KBH_PATH" "$CARABINER" register apply --config "$CFG_PATH" || warn "register apply did not finish; see above (the harness may not be installed for this account yet)"
fi
if [[ ${#BOOKMARK_ARG[@]} -gt 0 ]]; then
  step "kbh $CARABINER bookmark install"
  "$PYTHON" "$KBH_PATH" "$CARABINER" bookmark install --config "$CFG_PATH" || warn "bookmark install did not finish; see above"
fi

# -- 6. belay ----------------------------------------------------------------------------
step "kbh $CARABINER belay"
BELAY_ARGS=(--config "$CFG_PATH")
$DRY_WAKE && BELAY_ARGS+=(--dry-wake)
if "$PYTHON" "$KBH_PATH" "$CARABINER" belay "${BELAY_ARGS[@]}"; then
  ok "climb on."
else
  warn "belay let go somewhere above - the clip is installed; fix what it names and run: $PYTHON $KBH_PATH $CARABINER belay"
fi

# -- 7. done ------------------------------------------------------------------------------
VENV_DIR=""
echo
echo -e "${G}  Seren Carabiner ($CARABINER) is clipped on.${NC}"
echo -e "  Clip:        ${KBH_PATH}"
echo -e "  Config:      ${CFG_PATH}   (edit; a new .kbh never overwrites it)"
echo -e "  Framing:     ${INTO}/framing.md   (the first words a woken session reads)"
[[ -n "$(ls -A "$CONNECTIONS" 2>/dev/null)" ]] && echo -e "  Connections: ${CONNECTIONS}" || rmdir "$CONNECTIONS" 2>/dev/null || true
echo -e "  Wake line for an Observatory's ripple:  $("$PYTHON" "$KBH_PATH" "$CARABINER" wake --config "$CFG_PATH" --yaml 0 2>/dev/null | head -1)"
seren_emit_done "$SVC_NAME" "127.0.0.1" 0 false ""
