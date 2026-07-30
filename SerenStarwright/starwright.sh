#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════
#  starwright.sh  -  launch Seren Starwright (the TUI installer)
#
#  Bootstraps its own venv and installs textual into it, then runs the TUI.
#
#  WHY A VENV RATHER THAN `pip install textual`:
#  Starwright's whole job is to be the FIRST thing you run on a fresh box, so
#  it can't assume a usable Python environment already exists. On Jetson (and
#  any modern Debian) a bare `pip install` into the system interpreter is
#  refused outright - PEP 668, "externally-managed-environment" - and the
#  advice to pass --break-system-packages is exactly the wrong thing to tell
#  someone whose next step is installing seven services. So we do what every
#  other installer in this repo does: our own venv, off in ~/seren-venvs.
#
#  Idempotent. Re-run it whenever; it reuses the venv if it's there.
#
#  USAGE
#    bash starwright.sh              # launch the TUI
#    bash starwright.sh --dump       # list discovered services, no TUI
#    bash starwright.sh --recreate   # rebuild the venv from scratch
# ══════════════════════════════════════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TUI="$SCRIPT_DIR/seren_starwright/seren-starwright.py"
VENV="${SEREN_STARWRIGHT_VENV:-$HOME/seren-venvs/starwright}"

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${G}  ✓${NC} $1" >&2; }
warn() { echo -e "${Y}  !${NC} $1" >&2; }
die()  { echo -e "${R}ERROR:${NC} $1" >&2; exit 1; }

[[ -f "$TUI" ]] || die "seren-starwright.py not found at $TUI"

ARGS=()
for a in "$@"; do
  case "$a" in
    --recreate) rm -rf "$VENV"; ok "removed $VENV" ;;
    *) ARGS+=("$a") ;;
  esac
done

# -- find a Python we can build a venv with -----------------------------------
# Same 3.10-3.12 window as the service installers: below that the typing
# syntax here won't parse, above it some downstream deps still have no wheels.
PYBIN=""
for c in python3.12 python3.11 python3.10 python3 python; do
  command -v "$c" >/dev/null 2>&1 || continue
  v="$("$c" -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null || echo "")"
  case "$v" in 3.10|3.11|3.12|3.13) PYBIN="$c"; break ;; esac
done
[[ -n "$PYBIN" ]] || die "No Python 3.10+ found.
  Debian/Ubuntu:  sudo apt install python3 python3-venv
  Fedora:         sudo dnf install python3"

if [[ ! -x "$VENV/bin/python" ]]; then
  echo "Bootstrapping Starwright into $VENV ..." >&2
  "$PYBIN" -m venv "$VENV" 2>/dev/null || die "venv creation failed.
  On Debian/Ubuntu you may need:  sudo apt install python3-venv"
  ok "venv created"
fi

VPY="$VENV/bin/python"
if ! "$VPY" -c "import textual" >/dev/null 2>&1; then
  echo "Installing textual ..." >&2
  "$VPY" -m pip install -q --upgrade pip
  "$VPY" -m pip install -q textual || die "could not install textual (no network?)"
  ok "textual installed"
fi

# --selftest runs the regression suite in this same venv, so you never have to
# think about where textual is installed.
for a in ${ARGS[@]+"${ARGS[@]}"}; do
  if [[ "$a" == "--selftest" ]]; then
    exec "$VPY" "$SCRIPT_DIR/test-starwright.py"
  fi
done

# exec: replace this shell so the TUI owns the terminal outright - otherwise a
# wrapper process sits between it and the tty and Ctrl-C gets muddled.
exec "$VPY" "$TUI" ${ARGS[@]+"${ARGS[@]}"}
