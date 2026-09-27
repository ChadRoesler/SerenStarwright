#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════
#  Whisper on a node: the binary, the model, start/stop, the manifest.
#
#  Design note: speech to text on the nodes before the node install
#  tests. The installer copies the staged whisper-server, fetches a model once,
#  writes start/stop scripts and registers a pid_file manifest the Observatory
#  drives - the first node service to do that last part. Proves, with a fake
#  binary and a model served from a folder (no network, no GPU):
#    - the binary, the model and both scripts land where the manifest says
#    - the manifest is valid JSON with the fields the Observatory reads
#    - start runs the server with the model, the port and the OpenAI path, and
#      records its pid; stop ends it and clears the pid
#    - a model already downloaded is not fetched again
#    - a missing staged binary fails with the reason
#
#  Run:  bash nodes/tests/test-whisper-install.sh   (Linux; CI runs it)
# ══════════════════════════════════════════════════════════════
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAILS=0
ok_()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad()  { FAILS=$((FAILS+1)); echo "  FAIL $1"; }
T="$(mktemp -d)"; trap 'bash "$T/home/stop_whisper.sh" >/dev/null 2>&1; rm -rf "$T"' EXIT

TARGET_USER="$(id -un)"
PREBUILT_DIR="$T/prebuilts"
# shellcheck disable=SC1091
source "$HERE/nodes/lib/common.sh"
exec 3>&1

# a stand-in whisper-server: answers --help, otherwise records its arguments and sleeps
mkdir -p "$T/stage" "$T/models" "$T/home"
cat > "$T/stage/whisper-server-jp6-orin-aarch64" <<'SH'
#!/bin/bash
[ "$1" = "--help" ] && { echo "usage: whisper-server"; exit 0; }
echo "$@" > "$(dirname "$0")/args.txt"
exec sleep 60
SH
chmod +x "$T/stage/whisper-server-jp6-orin-aarch64"
printf 'not really a model' > "$T/models/ggml-base.en.bin"

export SEREN_TEST_HOME="$T/home" USER_HOME="$T/home"
export STAGED_WHISPER_BIN="$T/stage/whisper-server-jp6-orin-aarch64"
export WHISPER_MODEL_BASE="file://$T/models"
# shellcheck disable=SC1091
source "$HERE/nodes/nano/whisper.sh"

echo "== install"
install_whisper > "$T/install.log" 2>&1 && ok_ "install_whisper succeeds" || { bad "install_whisper failed"; cat "$T/install.log"; }
H="$T/home"
[ -x "$H/whisper.cpp/build/bin/whisper-server" ] && ok_ "binary copied and executable" || bad "binary missing"
[ -f "$H/models/whisper/ggml-base.en.bin" ] && ok_ "the Orin Nano default model (base.en) fetched" || bad "model missing"
[ -x "$H/start_whisper.sh" ] && [ -x "$H/stop_whisper.sh" ] && ok_ "start and stop scripts written" || bad "scripts missing"

echo "== the manifest"
M="$H/.seren/services/whisper.json"
if python3 - "$M" "$H" <<'PY'
import json, sys
m = json.load(open(sys.argv[1])); h = sys.argv[2]
assert m["service"] == "whisper" and m["service_type"] == "pid_file", m
assert m["port"] == 8081 and m["endpoint"] == "/v1/audio/transcriptions", m
assert m["start_script"] == h + "/start_whisper.sh" and m["stop_script"] == h + "/stop_whisper.sh", m
assert m["pid_path"] == h + "/seren-logs/whisper.pid", m
ss = m["serviceSpecific"]
assert ss["model"] == "base.en" and ss["model_path"].endswith("ggml-base.en.bin") and len(ss["model_sha256"]) == 64, ss
PY
then ok_ "manifest: pid_file, port 8081, the OpenAI path, scripts, pid, model + sha256"; else bad "manifest wrong: $(cat "$M" 2>/dev/null)"; fi

echo "== start and stop"
bash "$H/start_whisper.sh" >/dev/null 2>&1; sleep 1
PID="$(cat "$H/seren-logs/whisper.pid" 2>/dev/null)"
if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then ok_ "start runs it and records the pid"; else bad "not running after start"; fi
ARGS="$(cat "$H/whisper.cpp/build/bin/args.txt" 2>/dev/null)"
[[ "$ARGS" == *"-m $H/models/whisper/ggml-base.en.bin"* && "$ARGS" == *"--port 8081"* && "$ARGS" == *"--inference-path /v1/audio/transcriptions"* ]] \
  && ok_ "started with the model, the port and the OpenAI path" || bad "args: $ARGS"
bash "$H/start_whisper.sh" | grep -q "already running" && ok_ "a second start does not start a second server" || bad "double start"
bash "$H/stop_whisper.sh"; sleep 1
if ! kill -0 "$PID" 2>/dev/null && [ ! -f "$H/seren-logs/whisper.pid" ]; then ok_ "stop ends it and clears the pid"; else bad "still running after stop"; fi

echo "== again, and without a binary"
rm "$T/models/ggml-base.en.bin"
install_whisper > "$T/install2.log" 2>&1 && grep -q "already here" "$T/install2.log" \
  && ok_ "a model already downloaded is kept, not fetched again" || bad "re-install: $(tail -3 "$T/install2.log")"
out="$(STAGED_WHISPER_BIN="$T/nope" install_whisper 2>&1)"; rc=$?
[[ $rc -ne 0 && "$out" == *"--whisper"* ]] && ok_ "a missing staged binary fails and names the prebuilts flag" || bad "missing binary: rc=$rc"

echo
echo "  $PASS passed, $FAILS failed"
exit $FAILS
