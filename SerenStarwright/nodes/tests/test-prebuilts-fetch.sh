#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════
#  Prebuilt staging, exercised against a fake release served from a folder.
#
#  Proves, without a Jetson or a network:
#    - names come from the release's SHA256SUMS, not from this tree
#    - the torchvision wheel keeps its real local-version tag (the '+')
#    - subdirectory entries (apt/, wheelhouse/) are never selected
#    - every staged file is verified; a tampered asset is refused, and the
#      llama binary is never chmod +x'd before verification
#    - a release with no SHA256SUMS is refused with a sentence
#    - the Spark stages like everyone else
#
#  Run:  bash nodes/tests/test-prebuilts-fetch.sh   (Git Bash on Windows is fine)
# ══════════════════════════════════════════════════════════════
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

# ── a fake release: flat assets + SHA256SUMS listing MORE than is uploaded ──
REL="$T/release"; mkdir -p "$REL"
echo "ELF llama"      > "$REL/llama-server-jp6-orin-aarch64"
echo "torch"          > "$REL/torch-2.11.0-cp310-cp310-linux_aarch64.whl"
echo "torchvision"    > "$REL/torchvision-0.26.0+336d36e-cp310-cp310-linux_aarch64.whl"
echo "bnb"            > "$REL/bitsandbytes-0.50.2+sm87-cp310-cp310-linux_aarch64.whl"
echo "gasket"         > "$REL/gasket-jp6-orin-aarch64.ko"
echo "apex"           > "$REL/apex-jp6-orin-aarch64.ko"
echo "kernel=x"       > "$REL/coral-jp6-orin.manifest"
( cd "$REL" && sha256sum * > SHA256SUMS
  # entries the folder had but the release never carries
  echo "$(printf 'deadbeef%.0s' {1..8})  apt-toolchain/gcc_11_arm64.deb" >> SHA256SUMS
  echo "$(printf 'deadbeef%.0s' {1..8})  wheelhouse/numpy-2.2.6-cp310-cp310-linux_aarch64.whl" >> SHA256SUMS
  echo "$(printf 'deadbeef%.0s' {1..8})  apt/cuda-nvcc-12-6_12.6.68-1_arm64.deb" >> SHA256SUMS )
RELURL="file://$(cygpath -m "$REL" 2>/dev/null || echo "$REL")"

# pretend resolve_release_tag already ran
PREBUILT_TAG="20260916_orin-jp6"; PREBUILT_BASE="$RELURL"
PLATFORM=nano; JP_FAMILY=jp6; PLATFORM_TAG=orin
INSTALL_LLAMA=true; INSTALL_COMFYUI=true; INSTALL_MSMOE=false; INSTALL_CORAL=true

echo "── staging from the index ──"
if run_prebuilts_download_services >/dev/null 2>"$T/err"; then ok "services staged"; else bad "services staged: $(cat "$T/err")"; fi
check "llama binary staged under the archive's name" '[ "$(basename "${STAGED_LLAMA_BIN:-}")" = "llama-server-jp6-orin-aarch64" ]'
# MSYS derives the x bit from content, so the mode check only means something on Linux.
check "and made executable only now" '[ "$(uname -s)" != Linux ] || [ -x "$STAGED_LLAMA_BIN" ]'
check "torchvision keeps its real +tag" '[ "$(basename "${STAGED_TVISION_WHL:-}")" = "torchvision-0.26.0+336d36e-cp310-cp310-linux_aarch64.whl" ]'
check "bitsandbytes staged as the optional spare" '[ -f "${STAGED_BNB_WHL:-/nope}" ]'
check "coral trio staged" '[ -f "$STAGED_GASKET_KO" ] && [ -f "$STAGED_APEX_KO" ] && [ -f "$STAGED_CORAL_MANIFEST" ]'
check "nothing from apt/ or wheelhouse/ was fetched" '! ls "$PREBUILT_DIR" | grep -qE "deb$|numpy"'
check "the index sits beside the staging" '[ -s "$PREBUILT_DIR/.release/SHA256SUMS-20260916_orin-jp6" ]'
check "a second run does not refetch (files verified in place)" 'run_prebuilts_download_services 2>&1 | grep -qv Downloading'

echo "── tampering ──"
echo "ELF llama (tampered)" > "$REL/llama-server-jp6-orin-aarch64"     # the release lies
rm -f "$PREBUILT_DIR/llama-server-jp6-orin-aarch64"
unset STAGED_LLAMA_BIN
if run_prebuilts_download_services >/dev/null 2>"$T/err"; then bad "a tampered asset is refused"; else ok "a tampered asset is refused"; fi
check "and nothing is left staged under that name" '[ ! -f "$PREBUILT_DIR/llama-server-jp6-orin-aarch64" ]'
check "the refusal names the file" 'grep -q "llama-server-jp6-orin-aarch64 failed verification" "$T/err"'
( cd "$REL" && sha256sum llama-server-* torch-* torchvision-* bitsandbytes-* gasket-* apex-* coral-* > SHA256SUMS )
unset PREBUILT_INDEX

echo "── a required asset that is missing ──"
mv "$REL/torch-2.11.0-cp310-cp310-linux_aarch64.whl" "$T/torch.bak"
( cd "$REL" && sha256sum llama-server-* torchvision-* bitsandbytes-* gasket-* apex-* coral-* > SHA256SUMS )
rm -f "$PREBUILT_DIR"/torch-*; unset STAGED_TORCH_WHL PREBUILT_INDEX
if run_prebuilts_download_services >"$T/err" 2>&1; then bad "a missing required wheel fails the run"; else ok "a missing required wheel fails the run"; fi
check "and says which pattern" 'grep -q "torch-\*.whl" "$T/err"'
mv "$T/torch.bak" "$REL/torch-2.11.0-cp310-cp310-linux_aarch64.whl"
( cd "$REL" && sha256sum llama-server-* torch-* torchvision-* bitsandbytes-* gasket-* apex-* coral-* > SHA256SUMS )
unset PREBUILT_INDEX

echo "── the Spark stages like everyone else ──"
PLATFORM=spark; JP_FAMILY=jp7; PLATFORM_TAG=spark; INSTALL_CORAL=false
unset STAGED_LLAMA_BIN STAGED_TORCH_WHL STAGED_TVISION_WHL STAGED_BNB_WHL
if run_prebuilts_download_services >/dev/null 2>"$T/err"; then ok "spark: services staged"; else bad "spark: services staged: $(cat "$T/err")"; fi
check "spark: foundation is a no-op that says so" 'run_prebuilts_download_foundation 2>&1; [ -z "${STAGED_PYTHON_TARBALL:-}" ]'

echo "── a release with no SHA256SUMS ──"
rm -f "$REL/SHA256SUMS"; unset PREBUILT_INDEX
if run_prebuilts_download_services >"$T/err" 2>&1; then bad "a release without an index is refused"; else ok "a release without an index is refused"; fi
check "and the message names the tag scheme change" 'grep -q "2026-09-23" "$T/err"'

echo "── url encoding ──"
check "'+' and '%' are encoded for the asset URL" '[ "$(seren_urlencode "a+b%c d")" = "a%2Bb%25c%20d" ]'

echo ""
echo "$PASS passed, $FAILS failed"
[ "$FAILS" = 0 ]
