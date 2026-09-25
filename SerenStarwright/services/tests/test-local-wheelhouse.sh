#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════
#  --local: installing a card from the dev wheelhouse.
#
#  Proves, with a real pip and no network:
#    - the newest wheel for the card's package is picked from SHA256SUMS
#    - every other seren-* wheel in the house becomes an exact pin, so a
#      dependency on seren-meninges resolves to the DEV build even though a
#      dev build is a pre-release pip would otherwise refuse
#    - a wheel that does not match the index is refused
#    - a file:// house behaves like a folder
#    - a house without an index is refused with the publisher's name
#    - --wheel still beats --local
#
#  Run:  bash services/tests/test-local-wheelhouse.sh   (Git Bash is fine)
# ══════════════════════════════════════════════════════════════
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAILS=0
ok_()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad()  { FAILS=$((FAILS+1)); echo "  FAIL $1"; }
check(){ if eval "$2"; then ok_ "$1"; else bad "$1"; fi; }

# A Python that can make a venv. `python3` on Windows is the Store stub, so
# prefer `python` where it is a real interpreter.
PY=""
for c in python python3; do
  command -v "$c" >/dev/null 2>&1 || continue
  "$c" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' >/dev/null 2>&1 && { PY="$c"; break; }
done
[[ -n "$PY" ]] || { echo "no python found"; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
# pip on Windows cannot read /tmp/...; hand every path over in a form both
# bash and pip accept. cygpath -m gives C:/... which MSYS bash reads too.
win() { cygpath -m "$1" 2>/dev/null || echo "$1"; }
export TMPDIR="$(win "$T")"
LIB="$HERE/services/lib/seren-install-lib.sh"

# Each scenario runs in its own bash: the library guards against a second
# source, and a card's `die` exits the shell it is in.
scenario() {   # scenario PACKAGE LOCAL [WHEEL] -- script
  local pkg="$1" local_="$2" wheel="${3:-}"
  local body="$4"
  PACKAGE="$pkg" LOCAL="$local_" WHEEL="$wheel" bash -c "
    SCRIPT_DIR='$HERE/services/bash'
    source '$LIB'
    die() { echo \"[die] \$1\" >&2; exit 1; }
    $body" 2>&1
}

# ── a hand-made wheelhouse: two projects, one depends on the other ──────────
HOUSE="$T/house"; mkdir -p "$HOUSE"
"$PY" - "$HOUSE" <<'PYW'
import base64, hashlib, sys, zipfile, pathlib
house = pathlib.Path(sys.argv[1])
def wheel(dist, ver, requires=()):
    name = f"{dist}-{ver}-py3-none-any.whl"
    info = f"{dist}-{ver}.dist-info"
    meta = f"Metadata-Version: 2.1\nName: {dist.replace('_','-')}\nVersion: {ver}\n"
    for r in requires:
        meta += f"Requires-Dist: {r}\n"
    files = {f"{dist}/__init__.py": f'__version__ = "{ver}"\n',
             f"{info}/METADATA": meta,
             f"{info}/WHEEL": "Wheel-Version: 1.0\nGenerator: test\nRoot-Is-Purelib: true\nTag: py3-none-any\n",
             f"{info}/top_level.txt": dist + "\n"}
    rec = ""
    for p, body in files.items():
        h = base64.urlsafe_b64encode(hashlib.sha256(body.encode()).digest()).rstrip(b"=").decode()
        rec += f"{p},sha256={h},{len(body.encode())}\n"
    rec += f"{info}/RECORD,,\n"
    with zipfile.ZipFile(house / name, "w", zipfile.ZIP_DEFLATED) as z:
        for p, body in files.items():
            z.writestr(p, body)
        z.writestr(f"{info}/RECORD", rec)
wheel("seren_meninges", "2.4.0")                       # a release someone left in the house
wheel("seren_meninges", "2.4.1.dev3+gabc1234")         # the dev build - a pre-release
wheel("seren_memory",   "3.0.1.dev2+gdef5678", ["seren-meninges>=2.4.0,<3"])
wheel("seren_loci",     "2.2.0+d20260923")
PYW
( cd "$HOUSE" && sha256sum *.whl > SHA256SUMS )
# a subdirectory entry that must never be picked
echo "$(printf 'deadbeef%.0s' {1..8})  old/seren_memory-9.9.9-py3-none-any.whl" >> "$HOUSE/SHA256SUMS"
HOUSE_W="$(win "$HOUSE")"

echo "── picking from a folder ──"
out="$(scenario seren-memory "$HOUSE_W" "" '
  resolve_wheel >/dev/null 2>&1 || exit 1
  echo "SRC=$(basename "$WHEEL_SRC")"; echo "ARGS=$EXTRA_PIP_ARGS"
  sed "s/^/PIN=/" "${EXTRA_PIP_ARGS##* }"')"
check "the newest seren_memory wheel is picked" 'grep -q "^SRC=seren_memory-3.0.1.dev2+gdef5678-py3-none-any.whl$" <<<"$out"'
check "find-links points at the house" 'grep -q "^ARGS=--find-links .*house -c " <<<"$out"'
check "the dev meninges is pinned, not the release beside it" 'grep -q "^PIN=seren-meninges==2.4.1.dev3+gabc1234$" <<<"$out" && ! grep -q "==2.4.0$" <<<"$out"'
check "loci is pinned too (every seren wheel in the house)" 'grep -q "^PIN=seren-loci==2.2.0+d20260923$" <<<"$out"'
check "the old/ subdirectory entry is ignored" '! grep -q "9.9.9" <<<"$out"'

echo "── a real pip install from the house (no network) ──"
"$PY" -m venv "$T/venv" >/dev/null 2>&1 || { bad "venv creation"; exit 1; }
VPY="$T/venv/bin/python"; [[ -x "$VPY" ]] || VPY="$(win "$T/venv/Scripts/python.exe")"
res="$(scenario seren-memory "$HOUSE_W" "" '
  resolve_wheel >/dev/null 2>&1 || exit 1
  pip_install "'"$VPY"'" "$WHEEL_SRC" "" "--no-index" "" || exit 1
  "'"$VPY"'" -m pip list --format=freeze 2>/dev/null | grep -i seren')"
check "seren-memory installed at the dev version" 'grep -qi "^seren[-_]memory==3.0.1.dev2+gdef5678$" <<<"$res"'
check "its seren-meninges dependency resolved to the DEV pre-release" 'grep -qi "^seren[-_]meninges==2.4.1.dev3+gabc1234$" <<<"$res"'
check "loci was pinned but not installed (a pin is not a request)" '! grep -qi "loci" <<<"$res"'

echo "── a rebuild with the SAME version still lands ──"
# A dirty tree is stamped with its commit and the day only, so two dev builds
# on one day share a version; --upgrade alone installed nothing and said ok.
"$PY" - "$HOUSE" <<'PYW'
import base64, hashlib, sys, zipfile, pathlib
house = pathlib.Path(sys.argv[1]); dist, ver = "seren_memory", "3.0.1.dev2+gdef5678"
info = f"{dist}-{ver}.dist-info"
files = {f"{dist}/__init__.py": f'__version__ = "{ver}"\nREBUILT = True\n',
         f"{info}/METADATA": f"Metadata-Version: 2.1\nName: seren-memory\nVersion: {ver}\nRequires-Dist: seren-meninges>=2.4.0,<3\n",
         f"{info}/WHEEL": "Wheel-Version: 1.0\nGenerator: test\nRoot-Is-Purelib: true\nTag: py3-none-any\n",
         f"{info}/top_level.txt": dist + "\n"}
rec = "".join(f"{k},sha256={base64.urlsafe_b64encode(hashlib.sha256(v.encode()).digest()).rstrip(b'=').decode()},{len(v.encode())}\n" for k, v in files.items()) + f"{info}/RECORD,,\n"
with zipfile.ZipFile(house / f"{dist}-{ver}-py3-none-any.whl", "w") as z:
    for k, v in files.items():
        z.writestr(k, v)
    z.writestr(f"{info}/RECORD", rec)
PYW
( cd "$HOUSE" && sha256sum *.whl > SHA256SUMS )
res="$(scenario seren-memory "$HOUSE_W" "" '
  resolve_wheel >/dev/null 2>&1 || exit 1
  pip_install "'"$VPY"'" "$WHEEL_SRC" "" "--no-index" "" >/dev/null 2>&1 || exit 1
  "'"$VPY"'" -c "import seren_memory as m; print(\"REBUILT\" if getattr(m, \"REBUILT\", False) else \"STALE\")"')"
check "the same-version rebuild replaced the installed code" 'grep -q "^REBUILT$" <<<"$res"'

echo "── a file:// house behaves like a folder ──"
out="$(scenario seren-loci "file://$HOUSE_W" "" '
  resolve_wheel >/dev/null 2>&1 || exit 1; echo "SRC=$(basename "$WHEEL_SRC")"')"
check "loci picked through file://" 'grep -q "^SRC=seren_loci-2.2.0+d20260923-py3-none-any.whl$" <<<"$out"'

echo "── tampering ──"
cp "$HOUSE/seren_loci-2.2.0+d20260923-py3-none-any.whl" "$T/loci.bak"
echo "not a wheel" > "$HOUSE/seren_loci-2.2.0+d20260923-py3-none-any.whl"
out="$(scenario seren-loci "$HOUSE_W" "" 'resolve_wheel && echo RESOLVED')"
check "a wheel that does not match the index is refused" '! grep -q RESOLVED <<<"$out" && grep -q "failed verification" <<<"$out"'
cp "$T/loci.bak" "$HOUSE/seren_loci-2.2.0+d20260923-py3-none-any.whl"

echo "── no package for this card ──"
out="$(scenario seren-probe "$HOUSE_W" "" 'resolve_wheel && echo RESOLVED')"
check "a house without this card's wheel says so" '! grep -q RESOLVED <<<"$out" && grep -q "no seren_probe-\*.whl" <<<"$out"'

echo "── precedence ──"
out="$(scenario seren-memory "$HOUSE_W" "$T/loci.bak" 'resolve_wheel >/dev/null 2>&1 && echo "SRC=$WHEEL_SRC ARGS=[$EXTRA_PIP_ARGS]"')"
check "--wheel still beats --local, and carries no house args" 'grep -q "loci.bak ARGS=\[\]$" <<<"$out"'

echo "── a house with no index ──"
rm -f "$HOUSE/SHA256SUMS"
out="$(scenario seren-memory "$HOUSE_W" "" 'resolve_wheel && echo RESOLVED')"
check "refused, and the message names the publisher" '! grep -q RESOLVED <<<"$out" && grep -q "seren-dev-publish.sh" <<<"$out"'

echo ""
echo "$PASS passed, $FAILS failed"
[[ "$FAILS" = 0 ]]
