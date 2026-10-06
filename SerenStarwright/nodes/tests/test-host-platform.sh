#!/usr/bin/env bash
# ════════════════════════════════════════════════════════
#  The generic host platform (a NUC, a tower, a VM), without one.
#
#  Proves:
#    - --platform host sets the release suffix host-<codename>-<arch>, and an
#      x86_64 Linux box with no Tegra release is detected as a host
#    - seren_host_python_ok says whether the box's own Python will do
#    - a host with an old Python stages python-*/libsqlite3-* from the
#      release's SHA256SUMS; a host with a good one stages nothing
#    - no release for the box is a warning and a source build, not a failure
#    - the dispatcher refuses GPU components and the destructive flags on a host
#    - --describe lists host and offers it no components
#
#  Run:  bash nodes/tests/test-host-platform.sh   (Git Bash on Windows is fine)
# ════════════════════════════════════════════════════════
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAILS=0
ok()   { PASS=$((PASS+1)); echo "  ok   $1"; }
bad()  { FAILS=$((FAILS+1)); echo "  FAIL $1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

GREEN=''; RED=''; YELLOW=''; BLUE=''; NC=''
log()  { :; }
info() { :; }
warn() { echo "[warn] $1" >&2; }
fail() { echo "[fail] $1" >&2; }
TARGET_USER="$(id -un)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export PREBUILT_DIR="$T/staged"
source "$HERE/nodes/lib/common.sh"

echo "── the platform ──"
SEREN_PLATFORM=host detect_platform >/dev/null 2>&1
check "--platform host is accepted" '[ "$PLATFORM" = host ] && [ "$PLATFORM_TAG" = host ]'
check "the release suffix is host-<codename>-<arch>" '[ "$RELEASE_SUFFIX" = "host-${JP_FAMILY}-$(uname -m)" ] && [ -n "$JP_FAMILY" ]'
check "no CUDA arch and no torch baseline" '[ -z "$CUDA_ARCH" ] && [ -z "$PYTORCH_VERSION" ]'
if SEREN_PLATFORM=toaster detect_platform >"$T/err" 2>&1; then bad "an unknown platform is refused"; else ok "an unknown platform is refused"; fi
check "and the refusal lists host" 'grep -q "xavier, nano, spark, host" "$T/err"'
(
  uname() { case "$1" in -s) echo Linux ;; -m) echo x86_64 ;; -r) echo 5.4.0 ;; *) command uname "$@" ;; esac; }
  _looks_like_spark() { return 1; }
  unset SEREN_PLATFORM
  if [ -f /etc/nv_tegra_release ]; then exit 0; fi          # a real Jetson running the suite
  detect_platform >/dev/null 2>&1 && [ "$PLATFORM" = host ]
) && ok "an x86_64 Linux box with no Tegra release is a host" || bad "an x86_64 Linux box with no Tegra release is a host"
(
  uname() { case "$1" in -s) echo Linux ;; -m) echo aarch64 ;; -r) echo 5.4.0 ;; *) command uname "$@" ;; esac; }
  _looks_like_spark() { return 1; }
  unset SEREN_PLATFORM
  if [ -f /etc/nv_tegra_release ]; then exit 0; fi
  ! detect_platform >/dev/null 2>&1
) && ok "an unannounced aarch64 board is NOT guessed to be a host" || bad "an unannounced aarch64 board is NOT guessed to be a host"

echo "── is the box's own Python enough ──"
# fake interpreters on PATH: what they report is what the check reads
mkpy() {   # mkpy DIR NAME PYVER SQLITEVER OKEXIT
  mkdir -p "$1"
  printf '#!/bin/sh\necho "%s %s, sqlite %s"\nexit %s\n' "$2" "$3" "$4" "$5" > "$1/$2"
  chmod +x "$1/$2"
}
mkpy "$T/old" python3 3.8.10 3.31.1 1
mkpy "$T/new" python3 3.12.3 3.45.1 0
( SEREN_HOST_PYTHON_CANDIDATES="$T/old/python3"; ! seren_host_python_ok ) \
  && ok "Python 3.8 with SQLite 3.31 is not enough" || bad "Python 3.8 with SQLite 3.31 is not enough"
( SEREN_HOST_PYTHON_CANDIDATES="$T/old/python3 $T/new/python3"; seren_host_python_ok && [ "$(seren_host_python_ok --say)" = "python3 3.12.3, sqlite 3.45.1" ] && [ "$(seren_host_python_ok --which)" = "$T/new/python3" ] ) \
  && ok "Python 3.12 with SQLite 3.45 is, and it says which" || bad "Python 3.12 with SQLite 3.45 is, and it says which"

echo "── staging from a host release ──"
REL="$T/release"; mkdir -p "$REL"
echo "python tarball" > "$REL/python-3.10.14-focal-x86_64.tar.gz"
echo "sqlite tarball" > "$REL/libsqlite3-3.45.1-focal-x86_64.tar.gz"
( cd "$REL" && sha256sum * > SHA256SUMS )
RELURL="file://$(cygpath -m "$REL" 2>/dev/null || echo "$REL")"
PLATFORM=host; JP_FAMILY=focal; PLATFORM_TAG=host; RELEASE_SUFFIX=host-focal-x86_64
PREBUILT_TAG="20261005_host-focal-x86_64"; PREBUILT_BASE="$RELURL"

seren_host_python_ok() { return 1; }                       # an Ubuntu 20.04 box
if run_prebuilts_download_foundation >/dev/null 2>"$T/err"; then ok "an old-Python host stages its foundation"; else bad "an old-Python host stages its foundation: $(cat "$T/err")"; fi
check "the Python tarball, under the host builder's name" '[ "$(basename "${STAGED_PYTHON_TARBALL:-}")" = "python-3.10.14-focal-x86_64.tar.gz" ]'
check "and the SQLite one" '[ "$(basename "${STAGED_SQLITE_TARBALL:-}")" = "libsqlite3-3.45.1-focal-x86_64.tar.gz" ]'

unset STAGED_PYTHON_TARBALL STAGED_SQLITE_TARBALL PREBUILT_INDEX
rm -rf "$PREBUILT_DIR"
seren_host_python_ok() { [ "${1:-}" = --say ] && echo "python3 3.12.3, sqlite 3.45.1"; return 0; }   # 24.04
run_prebuilts_download_foundation >/dev/null 2>&1
check "a host whose Python is new enough stages nothing" '[ -z "${STAGED_PYTHON_TARBALL:-}" ] && [ ! -d "$PREBUILT_DIR" ]'

seren_host_python_ok() { return 1; }
rm -f "$REL/SHA256SUMS"; unset PREBUILT_INDEX
if run_prebuilts_download_foundation >"$T/err" 2>&1; then ok "no usable release is not a failure"; else bad "no usable release is not a failure"; fi
check "it says the foundation will build from source" 'grep -q "build them from source" "$T/err"'
check "and nothing is staged" '[ -z "${STAGED_PYTHON_TARBALL:-}" ]'

echo "── the foundation module ──"
( run_phase() { echo "phase:$1"; }
  source "$HERE/nodes/host/foundation.sh"
  TRIM_OS=false; WIPE_NVME=false
  [ "$(run_foundation | tr '\n' ' ')" = "phase:01_host_base phase:02_host_sqlite phase:03_host_python310 " ] || exit 1
  [ "$(run_bootstrap_python | tr '\n' ' ')" = "phase:02_host_sqlite phase:03_host_python310 " ] || exit 1
  TRIM_OS=true;  ! run_foundation >/dev/null 2>&1 || exit 1
  TRIM_OS=false; WIPE_NVME=true; ! run_foundation >/dev/null 2>&1 || exit 1
) && ok "three phases, two for the bootstrap, and it refuses to trim or wipe" || bad "three phases, two for the bootstrap, and it refuses to trim or wipe"
( sudo() { echo "sudo $*"; }
  source "$HERE/nodes/host/foundation.sh"
  mkdir -p "$T/a/usr/local/bin" "$T/b/bin"; touch "$T/a/usr/local/bin/python3.10" "$T/b/bin/python3.10"
  tar czf "$T/host.tar.gz" -C "$T/a" usr; tar czf "$T/jetson.tar.gz" -C "$T/b" bin
  _host_untar "$T/host.tar.gz"   | grep -q -- "-C /$"          || exit 1
  _host_untar "$T/jetson.tar.gz" | grep -q -- "-C /usr/local$" || exit 1
) && ok "a tarball is unpacked whichever way it was rooted" || bad "a tarball is unpacked whichever way it was rooted"

echo "── the dispatcher ──"
D="$HERE/nodes/seren-prepare-node.sh"
out="$(bash "$D" --platform host --llama 2>&1)"; rc=$?
check "a GPU component on a host is refused, in a sentence" '[ $rc -ne 0 ] && echo "$out" | grep -q "installed from their cards"'
out="$(bash "$D" --platform host --prep --trim-os 2>&1)"; rc=$?
check "--trim-os on a host is refused" '[ $rc -ne 0 ] && echo "$out" | grep -q "without removing or formatting"'
out="$(bash "$D" --platform host --wipe-nvme 2>&1)"; rc=$?
check "--wipe-nvme on a host is refused" '[ $rc -ne 0 ] && echo "$out" | grep -q "without removing or formatting"'
desc="$(HOME="$T/home" bash "$D" --platform host --describe 2>/dev/null)"
check "--describe lists host among the platforms" 'echo "$desc" | grep -q "\"platforms\":\[\"xavier\",\"nano\",\"spark\",\"host\"\]"'
check "and reports this box as one" 'echo "$desc" | grep -q "\"platform\":\"host\""'
check "with no component offered" '! echo "$desc" | grep -q "\"available\":true"'

echo ""
echo "$PASS passed, $FAILS failed"
[ "$FAILS" = 0 ]
