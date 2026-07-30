#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════
#  build-starwright.sh  -  bundle Seren Starwright into ONE runnable file
#
#  Produces dist/starwright.pyz - a ~2.4MB zipapp (PEP 441) with textual,
#  rich and their whole dependency tree inside it. Runs on any box with
#  python3, with nothing installed:
#
#      python3 starwright.pyz
#      ./starwright.pyz              (it's chmod +x with a shebang)
#
#  WHY THIS WORKS, AND WHEN IT WOULDN'T:
#  zipapp can only bundle PURE PYTHON. Python cannot dlopen a C extension
#  from inside a zip archive, so a single .so anywhere in the dependency
#  tree breaks it. Starwright's tree (textual -> rich, markdown-it-py,
#  pygments, platformdirs, linkify-it-py, mdurl, uc-micro-py,
#  typing_extensions) is pure Python end to end - verified, zero .so/.pyd.
#  The check below FAILS THE BUILD if that ever stops being true, rather
#  than shipping an archive that explodes on someone's Jetson.
#
#  If it ever does stop being true, the answers are `shiv` or `pex` - same
#  single-file shape, but they unpack to a cache dir on first run so the
#  native bits land on a real filesystem.
#
#  WHAT THIS IS *NOT*:
#  Unlike `dotnet publish --self-contained`, this does NOT bundle the Python
#  runtime - the target needs a python3. That's free here: every seren-*
#  installer already requires Python 3.10-3.12, so a box without Python
#  can't install anything anyway. For a true zero-runtime binary you'd want
#  PyInstaller or Nuitka, at the cost of a separate build per platform
#  (arm64 Jetson, x86 NUC, Windows) and 15-40MB apiece.
#
#  ALSO NOT BUNDLED: the installers themselves. Starwright *runs* the
#  scripts in Bash/ and Powershell/, so it still needs this repo next to it
#  (or $SEREN_SETUP_SCRIPTS pointing at one). That's deliberate - the
#  scripts are the part you most want to be able to read and patch in the
#  field, and freezing them into a binary is the opposite of that.
#
#  USAGE
#    bash build-starwright.sh
#    bash build-starwright.sh --out /somewhere/starwright.pyz
# ══════════════════════════════════════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SCRIPT_DIR/seren_starwright/seren-starwright.py"
OUT="$SCRIPT_DIR/dist/starwright.pyz"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    -h|--help) sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

G='\033[0;32m'; R='\033[0;31m'; NC='\033[0m'
ok()  { echo -e "${G}  ✓${NC} $1" >&2; }
die() { echo -e "${R}ERROR:${NC} $1" >&2; exit 1; }

[[ -f "$SRC" ]] || die "seren-starwright.py not found at $SRC"

PYBIN=""
for c in python3.12 python3.11 python3.10 python3; do
  command -v "$c" >/dev/null 2>&1 && { PYBIN="$c"; break; }
done
[[ -n "$PYBIN" ]] || die "no python3 found"

echo "Bundling with $PYBIN ..." >&2
"$PYBIN" -m pip install --quiet --target "$BUILD" textual || die "pip install failed"
cp "$SRC" "$BUILD/__main__.py"

# -- bundle the installers themselves -----------------------------------------
# Starwright RUNS these; without them the archive is a UI with nothing behind
# it. Copied into _seren_scripts/ and unpacked at runtime to
# ~/.seren-starwright/<archive>-<stamp>/ ONLY when no real checkout is found.
#
# On-disk always wins over the bundle - see _find_base_dir. So a dev in a
# checkout keeps editing live scripts and never touches this copy; someone who
# curled one file onto a bare Jetson gets a working installer. And because the
# fallback extracts to real files at a printed path, the scripts stay readable
# and patchable in the field, which was the whole objection to bundling them.
# -- locate the repo root and read its declared layout ------------------------
# Walk UP for the marker rather than assuming it sits beside this script. The
# repo uses the nested Visual Studio layout, so the marker is a level above
# build-starwright.sh - and hardcoding either arrangement is how this broke.
REPO_ROOT=""
_d="$SCRIPT_DIR"
while [[ -n "$_d" && "$_d" != "/" ]]; do
  [[ -f "$_d/.starwright-root" ]] && { REPO_ROOT="$_d"; break; }
  _d="$(dirname "$_d")"
done
[[ -n "$REPO_ROOT" ]] || die "no .starwright-root found at or above $SCRIPT_DIR"
ok "repo root: $REPO_ROOT"

# Honour the layout the marker declares instead of guessing it.
_layout_get() {
  sed -e 's/#.*//' "$REPO_ROOT/.starwright-root" \
    | awk -F= -v k="$1" '$1 ~ "^[[:space:]]*"k"[[:space:]]*$" {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit }'
}
SERVICES_REL="$(_layout_get services)"; SERVICES_REL="${SERVICES_REL:-services}"
NODES_REL="$(_layout_get nodes)";       NODES_REL="${NODES_REL:-nodes}"

BUNDLE="$BUILD/_seren_scripts"
mkdir -p "$BUNDLE"
# Source path (as the repo arranges it) -> bundle path (always flat).
for pair in \
  "$SERVICES_REL/bash:services/bash" \
  "$SERVICES_REL/powershell:services/powershell" \
  "$SERVICES_REL/lib:services/lib" \
  "$NODES_REL:nodes" \
  "$NODES_REL/lib:nodes/lib" \
  "$NODES_REL/xavier:nodes/xavier" \
  "$NODES_REL/nano:nodes/nano" \
  "$NODES_REL/spark:nodes/spark"; do
  src="$REPO_ROOT/${pair%%:*}"
  dst="$BUNDLE/${pair##*:}"
  [[ -d "$src" ]] || continue
  mkdir -p "$dst"
  # Only the installer surface. Not seren-starwright.py (it IS the archive) and
  # not the TUI's own launcher/builder - nothing in here should re-bundle.
  find "$src" -maxdepth 1 -type f \( -name "*.sh" -o -name "*.ps1" \) \
       ! -name "seren-starwright.py" -exec cp {} "$dst/" \;
done

# The bundle gets its OWN marker, GENERATED - not a copy of the repo's.
#
# This is the subtle one. The repo may nest its project (services live under
# SerenStarwright/services), but the bundle always lays them out FLAT. Copying
# the repo's marker verbatim would put "services = SerenStarwright/services"
# into an archive whose services are at "services" - producing a bundle that
# extracts cleanly and then discovers nothing. The bundle's layout is this
# script's decision, so this script declares it.
cat > "$BUNDLE/.starwright-root" <<'MARKER'
# Generated by build-starwright.sh for the bundled copy of the installers.
# The bundle layout is always flat, whatever shape the source repo is in.
services = services
nodes    = nodes
MARKER

NBUNDLED="$(find "$BUNDLE" -type f | wc -l | tr -d ' ')"
[[ "$NBUNDLED" -gt 1 ]] || die "bundled zero scripts - is $REPO_ROOT the repo root?"
ok "bundled $((NBUNDLED - 1)) script(s) + a generated flat-layout marker"

# -- version stamp ------------------------------------------------------------
# Once a .pyz is sitting on a Jetson there is no repo to interrogate, so "which
# build is this?" is unanswerable unless the answer travels inside the archive.
# $SEREN_STARWRIGHT_VERSION lets CI pass the tag it is building; otherwise fall
# back to git, then to a timestamp so the field is never empty.
STAMP="${SEREN_STARWRIGHT_VERSION:-}"
if [[ -z "$STAMP" ]]; then
  STAMP="$(git -C "$REPO_ROOT" describe --tags --always --dirty 2>/dev/null || true)"
fi
[[ -n "$STAMP" ]] || STAMP="untagged-$(date -u +%Y%m%dT%H%M%SZ)"
printf '%s\n' "$STAMP" > "$BUILD/_starwright_version.txt"
ok "version stamp: $STAMP"

# Trim what only matters at install time; keeps the archive ~2.4MB not ~11MB.
find "$BUILD" \( -name "*.dist-info" -o -name "__pycache__" -o -name "tests" \) \
     -type d -exec rm -rf {} + 2>/dev/null || true

# -- the guard that keeps this honest ----------------------------------------
NATIVE="$(find "$BUILD" \( -name "*.so" -o -name "*.pyd" \) | head -5)"
if [[ -n "$NATIVE" ]]; then
  echo "$NATIVE" >&2
  die "compiled extension(s) in the dependency tree - zipapp cannot load these
  from inside an archive. Switch to shiv or pex, which unpack to a cache dir:
      pip install shiv && shiv -c seren-starwright -o starwright.pyz textual"
fi
ok "dependency tree is pure Python (no .so/.pyd)"

mkdir -p "$(dirname "$OUT")"
"$PYBIN" -m zipapp "$BUILD" -o "$OUT" -p "/usr/bin/env python3" -c
chmod +x "$OUT"
OUT_ABS="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
ok "built $OUT ($(du -h "$OUT" | cut -f1))"

# -- prove it actually runs, rather than assuming ------------------------------
# FROM A NEUTRAL DIRECTORY, WITH THE ROOT OVERRIDES CLEARED. An on-disk checkout
# always beats the bundled copy, so running --dump from inside the repo proves
# the REPO works and says nothing about the ARCHIVE - it passes just as happily
# with a bundle that discovers nothing. Fatal, not a warning: a .pyz that can't
# find its own scripts is dead on a bare Jetson, which is the only box it exists
# for. Same shape the release workflow already uses.
#
# MATCH A SERVICE ROW, NOT THE STRING "seren-". The failure path prints
#   no installers found under ~/.seren-starwright/<key>/_seren_scripts
# which contains "seren-" itself, so a `grep -q seren-` passes on the error
# message and reports a broken archive as healthy. It did exactly that here.
# A real row is:  brain      seren-memory    :7420   extras=[...]
SMOKE_DIR="$(mktemp -d)"
SMOKE_RE='^[a-z]+[[:space:]]+seren-[a-z-]+[[:space:]]+:[0-9]+'
if ( cd "$SMOKE_DIR" && env -u SEREN_STARWRIGHT_ROOT -u SEREN_SHIPWRIGHT_ROOT \
        -u SEREN_SETUP_SCRIPTS "$PYBIN" "$OUT_ABS" --dump 2>/dev/null \
        | grep -qE "$SMOKE_RE" ); then
  ok "smoke test passed (bundled scripts found with no checkout present)"
  rm -rf "$SMOKE_DIR"
else
  rm -rf "$SMOKE_DIR"
  die "the built archive discovered no services when run outside a checkout.
  The bundled scripts or the generated .starwright-root marker are wrong - this
  .pyz would be dead on a bare Jetson. Not shipping it."
fi

echo >&2
echo -e "${G}Run it:${NC}  $OUT" >&2
echo -e "${G}Rip it and win. 🌭🔧${NC}" >&2
