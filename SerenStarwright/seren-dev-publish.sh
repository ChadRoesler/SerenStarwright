#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════
#  seren-dev-publish.sh  -  every checkout in SerenCore, built into ONE folder
#
#  The quick revision loop. Edit any Seren project, run this, and every card
#  (bash or PowerShell, in the TUI or by hand) can install what is on disk
#  right now instead of a release:
#
#      bash seren-dev-publish.sh                  # build all, into the house
#      bash seren-dev-publish.sh --serve          # ...and serve it on :8765
#      bash seren-memory-setup.sh --local ../.dev-wheelhouse
#      bash seren-memory-setup.sh --local http://devbox:8765     # from a node
#
#  WHAT A "HOUSE" IS
#  A flat folder - one wheel per project, starwright.pyz, SHA256SUMS in
#  sha256sum's format, and MANIFEST (what git said each wheel was built from).
#  The cards read SHA256SUMS to pick the newest wheel for their package and
#  pin every other seren-* wheel in the house alongside it, so a dev
#  seren-meninges rides along with whichever service you are testing.
#  Served with python's http.server, the same folder works over the LAN: pip
#  reads the directory listing, the cards read SHA256SUMS. Nothing else.
#
#  WHERE THINGS ARE
#  SerenCore is the folder holding the checkouts, found as the grandparent of
#  this script (SerenCore/SerenStarwright/SerenStarwright/). Each project is
#  SerenCore/<Repo>/<Repo>/pyproject.toml - the nested layout the whole stack
#  uses. The house defaults to SerenCore/.dev-wheelhouse, outside every repo.
#
#  VERSIONS ARE WHATEVER setuptools-scm SAYS
#  A clean tagged checkout builds the release version; anything else is a
#  pre-release (3.0.1.dev2+gb31682c) or a dirty local (3.0.0+d20260923).
#  Nothing here pretends otherwise. MANIFEST records `git describe --dirty`
#  next to each wheel so a box can be asked what it is actually running.
#
#  FLAGS
#    --core DIR        The folder holding the checkouts   (default: ../..)
#    --house DIR       Where to publish                    (default: CORE/.dev-wheelhouse)
#    --only A,B        Build only these repos (SerenMemory,SerenLoci,... or starwright)
#    --skip A,B        Build everything except these
#    --no-isolation    python -m build --no-isolation (needs setuptools-scm installed;
#                      much faster on a box that has it, and works offline)
#    --clean           Empty the house first
#    --serve [PORT]    After building, serve the house on 0.0.0.0:PORT (default 8765)
#    -h, --help        This help
# ══════════════════════════════════════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOUSE=""
ONLY=""; SKIP=""
ISOLATION=true
CLEAN=false
SERVE=false; PORT=8765

while [[ $# -gt 0 ]]; do
  case "$1" in
    --core)  CORE="$(cd "$2" && pwd)"; shift 2 ;;
    --house) HOUSE="$2"; shift 2 ;;
    --only)  ONLY="$2"; shift 2 ;;
    --skip)  SKIP="$2"; shift 2 ;;
    --no-isolation) ISOLATION=false; shift ;;
    --clean) CLEAN=true; shift ;;
    --serve) SERVE=true; shift
             [[ $# -gt 0 && "$1" =~ ^[0-9]+$ ]] && { PORT="$1"; shift; } ;;
    -h|--help) awk 'NR>1{ if (/^#/) { sub(/^# ?/,""); print } else exit }' "$0"; exit 0 ;;
    *) echo "unknown flag: $1  (try --help)" >&2; exit 1 ;;
  esac
done
[[ -n "$HOUSE" ]] || HOUSE="$CORE/.dev-wheelhouse"

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; B='\033[0;34m'; NC='\033[0m'
step() { echo -e "\n${B}==>${NC} $1" >&2; }
ok()   { echo -e "${G}  ✓${NC} $1" >&2; }
warn() { echo -e "${Y}  !${NC} $1" >&2; }
die()  { echo -e "${R}ERROR:${NC} $1" >&2; exit 1; }

[[ -f "$CORE/SerenMeninges/SerenMeninges/pyproject.toml" ]] \
  || die "$CORE does not look like SerenCore (no SerenMeninges/SerenMeninges/pyproject.toml). Point --core at the folder holding the checkouts."

# -- a Python with `build` ------------------------------------------------------
# Prefer the interpreters the services run on; `python` last because on
# Windows `python3` is the Store stub and `python` is the real one.
PY=""
for c in python3.12 python3.11 python3.10 python3 python; do
  command -v "$c" >/dev/null 2>&1 || continue
  "$c" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' >/dev/null 2>&1 && { PY="$c"; break; }
done
[[ -n "$PY" ]] || die "no Python 3.10+ found"
"$PY" -c 'import build' 2>/dev/null || die "the 'build' module is missing:  $PY -m pip install build"
if ! $ISOLATION; then
  "$PY" -c 'import setuptools_scm, wheel' 2>/dev/null \
    || die "--no-isolation needs setuptools-scm and wheel in $PY:  $PY -m pip install setuptools setuptools-scm wheel"
fi
ok "Building with $PY ($("$PY" -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])'))"

# -- which projects -----------------------------------------------------------
wanted() {   # wanted NAME -> 0 if --only/--skip let it through
  local n="$1"
  if [[ -n "$ONLY" ]]; then
    [[ ",$ONLY," == *",$n,"* ]] || return 1
  fi
  [[ ",$SKIP," != *",$n,"* ]]
}
PROJECTS=()
for d in "$CORE"/Seren*/; do
  n="$(basename "$d")"
  [[ -f "$d/$n/pyproject.toml" ]] || continue
  wanted "$n" && PROJECTS+=("$n")
done
BUILD_TUI=false
wanted starwright && BUILD_TUI=true
[[ ${#PROJECTS[@]} -gt 0 || $BUILD_TUI == true ]] || die "nothing selected (check --only / --skip)"

mkdir -p "$HOUSE"
if $CLEAN; then
  step "Emptying $HOUSE"
  find "$HOUSE" -maxdepth 1 -type f \( -name '*.whl' -o -name '*.pyz' -o -name SHA256SUMS -o -name MANIFEST \) -delete
fi
MANIFEST="$HOUSE/MANIFEST"
[[ -f "$MANIFEST" ]] || printf '# file\tversion\tgit\tbuilt\n' > "$MANIFEST"

# MANIFEST is keyed by file name: a rebuilt project replaces its own row, a
# project left alone keeps the row from the run that built it, and a file
# that is no longer in the house loses its row at the end.
record() {   # record FILE VERSION GIT
  local tmp; tmp="$(mktemp)"
  grep -v -F "$1	" "$MANIFEST" > "$tmp" || true
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$tmp"
  mv "$tmp" "$MANIFEST"
}

# -- build each project ----------------------------------------------------------
BUILT=0; FAILED=()
for n in "${PROJECTS[@]}"; do
  pkg="$CORE/$n/$n"
  step "$n"
  out="$(mktemp -d)"
  args=(--wheel --outdir "$out")
  $ISOLATION || args+=(--no-isolation)
  if ! "$PY" -m build "${args[@]}" "$pkg" > "$out/build.log" 2>&1; then
    warn "$n failed to build - see $out/build.log"
    tail -5 "$out/build.log" >&2
    FAILED+=("$n"); continue
  fi
  whl="$(ls "$out"/*.whl 2>/dev/null | head -1)"
  [[ -n "$whl" ]] || { warn "$n built nothing"; FAILED+=("$n"); continue; }
  name="$(basename "$whl")"
  dist="${name%%-*}"; ver="${name#*-}"; ver="${ver%%-*}"
  # one wheel per project in the house: the old build of THIS project goes
  rm -f "$HOUSE/${dist}"-*.whl
  mv "$whl" "$HOUSE/$name"
  rm -rf "$out"
  git_desc="$(git -C "$CORE/$n" describe --tags --dirty --always 2>/dev/null || echo "no-git")"
  record "$name" "$ver" "$git_desc"
  ok "$name   ($git_desc)"
  BUILT=$((BUILT+1))
done

# -- Starwright itself ------------------------------------------------------------
if $BUILD_TUI; then
  step "starwright.pyz"
  if bash "$SCRIPT_DIR/build-starwright.sh" --out "$HOUSE/starwright.pyz" > "$HOUSE/.starwright-build.log" 2>&1; then
    git_desc="$(git -C "$SCRIPT_DIR" describe --tags --dirty --always 2>/dev/null || echo "no-git")"
    record "starwright.pyz" "$git_desc" "$git_desc"
    ok "starwright.pyz   ($git_desc)"
    rm -f "$HOUSE/.starwright-build.log"
  else
    warn "starwright.pyz failed to build - see $HOUSE/.starwright-build.log"
    FAILED+=(starwright)
  fi
fi

# -- index -----------------------------------------------------------------------
step "Indexing $HOUSE"
# sha256sum on Windows marks binary files with "*"; the readers tolerate it,
# but the index is cleaner without.
( cd "$HOUSE" && { ls *.whl *.pyz 2>/dev/null | sort | xargs -r sha256sum | sed "s/ \*/  /" > SHA256SUMS; } )
# drop MANIFEST rows for files that are gone
tmp="$(mktemp)"
while IFS=$'\t' read -r f rest; do
  [[ "$f" == "#"* || -f "$HOUSE/$f" ]] && printf '%s\t%s\n' "$f" "$rest"
done < "$MANIFEST" > "$tmp"; mv "$tmp" "$MANIFEST"
count="$(grep -c . "$HOUSE/SHA256SUMS" || true)"
ok "$count file(s) indexed, $BUILT built this run"
if [[ ${#FAILED[@]} -gt 0 ]]; then
  warn "did not build: ${FAILED[*]}"
fi

echo "" >&2
echo "Install from it:" >&2
echo "  bash services/bash/seren-memory-setup.sh --local $HOUSE" >&2
echo "  (or fill in 'dev wheelhouse' on Starwright's options screen)" >&2

# -- serve ------------------------------------------------------------------------
if $SERVE; then
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  [[ -n "$ip" ]] || ip="$(hostname)"
  echo "" >&2
  echo "Serving $HOUSE on port $PORT. From a node:" >&2
  echo "  --local http://$ip:$PORT" >&2
  echo "  curl -fsSLO http://$ip:$PORT/starwright.pyz && python3 starwright.pyz" >&2
  echo "Ctrl-C stops it." >&2
  exec "$PY" -m http.server "$PORT" --bind 0.0.0.0 --directory "$HOUSE"
fi
[[ ${#FAILED[@]} -eq 0 ]]
