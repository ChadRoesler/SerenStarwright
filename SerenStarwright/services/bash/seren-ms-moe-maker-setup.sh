#!/usr/bin/env bash
# ==========================================================================
#  seren-ms-moe-maker-setup.sh  -  one-shot Ms.MoE Maker installer (Linux + macOS)
#
#  Builds a targeted Mixture of Experts from a recipe. Not a coding model — a
#  coding model shaped like your stack.
#
#  THIS IS A CLI, NOT A SERVICE. There is no port, no daemon, no config file to
#  write and nothing to autostart. It is in the services folder because that is
#  where Starwright looks, and Starwright is the right place to install it FROM.
#
#  ON THE FILENAME. `seren-ms-moe-maker-setup.sh`, not `-msmoemaker-`, because
#  verify-powershell.ps1 pairs each .ps1 with its bash counterpart by deriving
#  the filename from the name in --describe: it strips a leading `seren-` and
#  looks for `seren-<rest>-setup.sh`. The name is `ms-moe-maker`, so the file
#  has to spell it the same way or the parity check reports "no bash
#  counterpart" - which is a real signal about a real pairing, so the filename
#  bends rather than the check.
#
#  AND MS-MOE-MAKER KNOWS NOTHING ABOUT SEREN. No seren-* dependency, no
#  assumption that Lodestar exists, no Seren in its name. This installer is the
#  Seren side of an opt-in connection: the tool gains nothing by being installed
#  this way, and someone who has never heard of Seren installs it with pip. That
#  asymmetry is deliberate — mandate is not ethos.
#
#  USAGE
#    bash seren-ms-moe-maker-setup.sh
#    bash seren-ms-moe-maker-setup.sh --train
#    bash seren-ms-moe-maker-setup.sh --wheel ./ms_moe_maker-0.1.0-py3-none-any.whl
#
#  FLAGS
#    --train          Install the [train] extra (torch, transformers, datasets).
#                     Off by default on purpose: `validate`, `describe` and
#                     `corpus` all work without it, which is what lets you check
#                     a recipe on a laptop with no GPU and no CUDA.
#    --wheel PATH     Install from a local .whl
#    --ref TAG        Pin to a GitHub release tag
#    --repo SLUG      GitHub release repo
#    --instance NAME  Instance name (suffixes the venv)
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
# PORT=0 MEANS "there is no port". A pipeline is a command you run, not a thing
# that listens, and seren_describe already defaults default_port to 0 - so the
# contract has always had room for this and nothing has used it yet. Starwright
# renders it as `:0`, which is honest but ugly; see the note at the bottom.
PORT=0
WHEEL=""
REF=""
REPO=""
INSTANCE=""
TRAIN=false
VENV_DIR="$HOME/seren-venvs/msmoemaker"
APP_DIR="$HOME/msMoEMaker"

# -- Starwright contract: identity + machine-readable metadata ----------------
# SVC_NAME IS THE TOOL'S REAL NAME, not a seren- one. Starwright does not tie
# the name in --describe to the filename of the installer, so the grid can say
# what the thing is actually called - and calling it `seren-msmoemaker` would be
# this repo renaming somebody else's project on screen.
SVC_NAME="ms-moe-maker"
SVC_DISPLAY="Ms.MoE Maker"
SVC_DESC="Build a mixture of experts from deliberately chosen specialists."
# A GROUP OF ITS OWN, and this is safe: GROUPS in seren-starwright.py controls
# order and pretty names only, it is NOT an allowlist - _ordered_groups renders
# an unknown group under its own heading. seren-probe learned that the hard way
# by shipping group "infra" and simply not appearing.
SVC_GROUP="tools"
SVC_PACKAGE="ms-moe-maker"
# Ms.MoE's own accent, from its describe card's spirit rather than the Seren
# palette: this is a workshop tool, not a constellation service.
SVC_ACCENT="#c98b3e"
# REQUIRES NOTHING, of anyone. The heavy deps live in [train]; the base CLI runs
# on a laptop with no GPU, which is what makes `validate` useful before a build.
SVC_REQUIRES=""
# EXPLICIT, because seren_describe derives extras from a family-wide allowlist
# of mcp|corp|vector and structurally cannot know about `train`. Left to derive,
# --describe would advertise extras:[] while --train quietly worked, so
# Starwright would never offer the checkbox. This is the documented escape hatch.
#
# `dev` is NOT offered: it is for working ON ms-moe-maker, not with it.
SVC_EXTRAS="train"

# --describe must answer with ZERO side effects: no venv, no network, no python.
# Scanned ahead of the parse loop so no other flag can have run anything first.
for _a in "$@"; do
  [[ "$_a" == "--describe" ]] && { seren_describe; exit 0; }
done

while [[ $# -gt 0 ]]; do
  case "$1" in
    --train)     TRAIN=true; shift ;;
    --wheel)     WHEEL="$2"; shift 2 ;;
    --ref)       REF="$2"; shift 2 ;;
    --repo)      REPO="$2"; shift 2 ;;
    --instance)  INSTANCE="$2"; shift 2 ;;
    --venv)      VENV_DIR="$2"; shift 2 ;;
    --json)      seren_json_on; shift ;;
    --describe)  seren_describe; exit 0 ;;
    -h|--help)   awk 'NR>1{ if (/^#/) { sub(/^# ?/,""); print } else exit }' "$0"; exit 0 ;;
    *)           die "unknown flag: $1  (try --help)" ;;
  esac
done

VENV_DIR="$VENV_DIR$INSTANCE"
APP_DIR="$APP_DIR$INSTANCE"

echo -e "${G}==========================================${NC}"
$IS_MAC && echo -e "${G}  Ms.MoE Maker setup (macOS)${NC}" || echo -e "${G}  Ms.MoE Maker setup (Linux)${NC}"
echo -e "${G}==========================================${NC}"

# -- 1. find Python (3.10+) ----------------------------------------------------
PYBIN="$(find_python)"

[[ -n "$REF" && -z "$REPO" ]] && REPO="ChadRoesler/MsMoEMaker"

# -- 2. resolve wheel ----------------------------------------------------------
PACKAGE="ms-moe-maker"
resolve_wheel

# -- 3. venv + install ---------------------------------------------------------
create_venv "$VENV_DIR"
VPY="$VENV_DIR/bin/python"
EXTRAS=""
$TRAIN && EXTRAS="[train]"
pip_install "$VPY" "$WHEEL_SRC" "$EXTRAS" "" ""

# -- 4. sanity check -----------------------------------------------------------
# WHAT IS INVARIANT for this package, and nothing more: it imports, its console
# script is on the venv's path, and --describe answers. A warning that fires on
# a working install teaches people to ignore warnings, so torch is NOT checked -
# a base install without it is the common and correct case.
step "Sanity-checking the install"
CHECK="$("$VPY" - <<'PY'
try:
    import ms_moe_maker
    from ms_moe_maker import DESCRIBE
except Exception as e:
    print(f"IMPORT_FAILED: {e}"); raise SystemExit
missing = [k for k in ("name", "commands", "stages", "requires") if k not in DESCRIBE]
print("DESCRIBE_INCOMPLETE: " + ",".join(missing) if missing else "OK")
PY
)" || CHECK="FAILED"
case "$CHECK" in
  OK) ok "Package imports and --describe answers" ;;
  DESCRIBE_INCOMPLETE*) warn "Installed but $CHECK — a front-end reading the card will find gaps" ;;
  *) die "Install looks broken: $CHECK" ;;
esac

CLI="$VENV_DIR/bin/ms-moe-maker"
if [[ -x "$CLI" ]]; then
  ok "CLI at $CLI"
else
  die "the ms-moe-maker console script is missing from $VENV_DIR/bin - the wheel installed but its entry point did not"
fi

# -- 5. NO CONFIG IS WRITTEN, deliberately -------------------------------------
# Every other installer in this folder writes a seren-*.yaml. This one must not.
#
# ms-moe-maker is configured by a RECIPE you wrote, plus an optional
# ~/.msmoe/defaults.yaml describing the box. Generating either from here would
# be Seren imposing configuration on a tool that does not know Seren exists -
# and a defaults file invented by an installer is a set of numbers nobody chose,
# which is exactly the shape that made `rungs:` a bug in seren-theatre.
#
# `ms-moe-maker init` writes a recipe the user then edits. That is the right
# moment for it: after they have seen the machine, not during an install.
mkdir -p "$APP_DIR"
ok "Workspace at $APP_DIR (no config generated - see below)"

# -- 6. how seren-theatre finds it ---------------------------------------------
# The one genuinely Seren-shaped thing worth saying out loud. Theatre's
# [stagehand] extra forks this CLI, and WHICH install it forks is configuration
# on Theatre's side, not something this script can or should reach over and set.
step "If you are pairing this with SerenTheatre"
echo -e "  Point Theatre at this venv, in its ${B}seren-theatre.yaml${NC}:"
echo
echo -e "  ${B}pipeline:${NC}"
echo -e "  ${B}  venv: $VENV_DIR${NC}"
echo
echo -e "  Theatre RAISES rather than falling back to PATH if that is wrong,"
echo -e "  which is the point: a silent downgrade to a different install is how"
echo -e "  you end up watching one box and building on another."

# -- done -------------------------------------------------------------------
echo
echo -e "${G}==========================================${NC}"
echo -e "${G}  Ms.MoE Maker is set up ✓${NC}"
echo -e "${G}==========================================${NC}"
echo -e "  Describe it:     ${B}$CLI --describe${NC}"
echo -e "  Start a recipe:  ${B}$CLI init${NC}"
echo -e "  Check a recipe:  ${B}$CLI validate recipe.yaml${NC}   (no GPU needed)"
echo -e "  Build:           ${B}$CLI build recipe.yaml --json${NC}"
$TRAIN || echo -e "  ${Y}Installed WITHOUT [train]${NC} - validate/describe/corpus work; building"
$TRAIN || echo -e "  ${Y}needs${NC} ${B}--train${NC}${Y} (torch, transformers, datasets).${NC}"
echo -e "${G}Rip it and win. 🌭🔧${NC}"

# -- Starwright contract: structured completion event -------------------------
# Port 0 and the url it derives from it are meaningless for a CLI. Emitted
# anyway, because Starwright's --json consumer waits for a `done` event and an
# install that never sends one reads as an install that never finished. The
# honest fix is a `kind` in the describe contract so a front-end can tell a
# command from a service; filed rather than smuggled in here.
seren_emit_done "$SVC_NAME" "127.0.0.1" "$PORT" "false" ""
