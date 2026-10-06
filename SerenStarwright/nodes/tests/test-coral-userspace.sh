#!/usr/bin/env bash
# ════════════════════════════════════════════════════════
#  Coral userspace: a pinned, checksummed libedgetpu and tflite_runtime.
#
#  5 Oct 2026: Google's Coral apt repo answers 403 and PyPI's tflite-runtime has
#  no libedgetpu built for it, so node prep installs a pinned pair from GitHub
#  release assets. What must hold, without a Jetson or a network:
#    - a download is kept only when its SHA-256 is the pinned one; a different
#      file is removed and both hashes are said
#    - the pin for the Orin Nano's base is one line of five fields
#    - a base with no verified pair has no pin, and the installer says so
#      instead of guessing
#    - the dead apt repo is not consulted any more
#
#  Run:  bash nodes/tests/test-coral-userspace.sh   (Git Bash on Windows is fine)
# ════════════════════════════════════════════════════════
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAILS=0
ok()   { PASS=$((PASS+1)); echo "  ok   $1"; }
bad()  { FAILS=$((FAILS+1)); echo "  FAIL $1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

TARGET_USER="$(id -un)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
source "$HERE/nodes/lib/common.sh"
exec 3>/dev/null
log()  { :; }
warn() { echo "[warn] $1" >&2; }

echo "── a download is kept only when it is the pinned file ──"
echo "the tested binary" > "$T/asset.deb"
URL="file://$(cygpath -m "$T/asset.deb" 2>/dev/null || echo "$T/asset.deb")"
GOOD="$(sha256sum "$T/asset.deb" | awk '{print $1}')"
if _seren_fetch_verified "$URL" "$GOOD" "$T/out.deb" 2>"$T/err"; then ok "the pinned file is kept"; else bad "the pinned file is kept: $(cat "$T/err")"; fi
check "byte for byte" 'cmp -s "$T/asset.deb" "$T/out.deb"'
BADSHA="$(printf 'deadbeef%.0s' {1..8})"
if _seren_fetch_verified "$URL" "$BADSHA" "$T/out2.deb" 2>"$T/err"; then bad "a different file is refused"; else ok "a different file is refused"; fi
check "and nothing is left behind" '[ ! -e "$T/out2.deb" ]'
check "and both hashes are said" 'grep -q "$GOOD" "$T/err" && grep -q "$BADSHA" "$T/err"'
if _seren_fetch_verified "file://$T/nope.deb" "$GOOD" "$T/out3.deb" 2>"$T/err"; then bad "a missing asset fails"; else ok "a missing asset fails"; fi
check "with nothing left behind either" '[ ! -e "$T/out3.deb" ]'

echo "── the pins ──"
( _seren_os_codename() { echo jammy; }; dpkg() { echo arm64; }
  read -r ver deb dsha whl wsha extra <<< "$(_seren_edgetpu_pin)"
  [ "$ver" = "16.0tf2.17.1" ] && [ -z "${extra:-}" ] \
    && [[ "$deb" == https://github.com/feranick/libedgetpu/releases/download/*ubuntu22.04_arm64.deb ]] \
    && [[ "$whl" == https://github.com/feranick/TFlite-builds/releases/download/*cp310-cp310-linux_aarch64.whl ]] \
    && [ ${#dsha} = 64 ] && [ ${#wsha} = 64 ] && [[ "$deb" == *tf2.17.1* ]] && [[ "$whl" == *2.17.1* ]]
) && ok "the Orin Nano's base: one version of each, the same TensorFlow, two hashes" || bad "the Orin Nano's pin is malformed"
( _seren_os_codename() { echo focal; }; dpkg() { echo arm64; }; [ -z "$(_seren_edgetpu_pin)" ] ) \
  && ok "a base nobody has verified has no pin (a Xavier on 20.04)" || bad "an unverified base got a pin"
( SEREN_EDGETPU_PIN="1.0 u1 s1 u2 s2"; [ "$(_seren_edgetpu_pin)" = "1.0 u1 s1 u2 s2" ] ) \
  && ok "SEREN_EDGETPU_PIN overrides it" || bad "the override is ignored"

echo "── the installer ──"
F="$HERE/nodes/lib/common.sh"
check "the dead apt repo is not consulted" '! grep -q "coral-edgetpu-stable main" "$F" && ! grep -q "sources.list.d/coral-edgetpu" "$F"'
check "an unverified base is told, not guessed at" 'grep -q "No verified libedgetpu build for this base" "$F"'
check "this platform's own prebuilt pair is tried before any third party" \
  '[ "$(grep -n "installed from the prebuilt" "$F" | head -1 | cut -d: -f1)" -lt "$(grep -n "_seren_fetch_verified \"\$deb_url\"" "$F" | head -1 | cut -d: -f1)" ]'
check "and a packaged libedgetpu is removed so two cannot disagree" 'grep -q "apt-get remove -y libedgetpu1-std libedgetpu1-max" "$F"'
check "both platforms that have a TPU call the shared installer" 'grep -q seren_install_coral_userspace "$HERE/nodes/nano/coral.sh" && grep -q seren_install_coral_userspace "$HERE/nodes/xavier/coral.sh"'

echo ""
echo "$PASS passed, $FAILS failed"
[ "$FAILS" = 0 ]
