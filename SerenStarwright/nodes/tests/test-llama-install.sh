#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════
#  llama.cpp on a node: the binary, the settings file, start/stop, the manifest.
#
#  Design note: llama was installed on every node and registered on
#  none, so the Observatory showed nothing and Lodestar could not start it.
#  One "llama" manifest now; the model it serves is a line in
#  ~/seren-llama.env. Proves, with a fake llama-server (no network, no GPU):
#    - the binary and both scripts land where the manifest says, and the
#      settings file carries the platform's defaults and the only model here
#    - the manifest is valid JSON with the fields the Observatory reads,
#      models_dir among them (its /service/llama/models lists that)
#    - start runs the server with the model and the sizes from the settings
#      file and records the pid; a second start does not start a second
#      server; stop ends it and clears the pid
#    - a start with no model there refuses and names the setting
#    - a re-install keeps the user's edits, and --llama-model changes only
#      the model line
#    - the Spark's defaults are the ones start-llama-spark.sh used to carry
#    - a missing staged binary fails with the reason
#
#  Run:  bash nodes/tests/test-llama-install.sh   (Linux; CI runs it)
# ══════════════════════════════════════════════════════════════
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAILS=0
ok_()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad()  { FAILS=$((FAILS+1)); echo "  FAIL $1"; }
T="$(mktemp -d)"
trap 'bash "$T/home/stop_llama.sh" >/dev/null 2>&1; bash "$T/spark/stop_llama.sh" >/dev/null 2>&1; rm -rf "$T"' EXIT

TARGET_USER="$(id -un)"
PREBUILT_DIR="$T/prebuilts"
# shellcheck disable=SC1091
source "$HERE/nodes/lib/common.sh"
exec 3>&1

# a stand-in llama-server: answers --version, otherwise records its arguments and sleeps
mkdir -p "$T/stage" "$T/home/models"
cat > "$T/stage/llama-server-jp6-orin-aarch64" <<'SH'
#!/bin/bash
[ "$1" = "--version" ] && { echo "version: 0 (fake)"; exit 0; }
echo "$@" > "$(dirname "$0")/args.txt"
exec sleep 60
SH
chmod +x "$T/stage/llama-server-jp6-orin-aarch64"
printf 'not really a model' > "$T/home/models/qwen-test.gguf"

export SEREN_TEST_HOME="$T/home" USER_HOME="$T/home"
export STAGED_LLAMA_BIN="$T/stage/llama-server-jp6-orin-aarch64"
unset LLAMA_MODEL LLAMA_PORT
# shellcheck disable=SC1091
source "$HERE/nodes/nano/llama.sh"

echo "== install"
install_llama > "$T/install.log" 2>&1 && ok_ "install_llama succeeds" || { bad "install_llama failed"; cat "$T/install.log"; }
H="$T/home"
[ -x "$H/llama.cpp/build/bin/llama-server" ] && ok_ "binary copied and executable" || bad "binary missing"
[ -x "$H/start_llama.sh" ] && [ -x "$H/stop_llama.sh" ] && ok_ "start and stop scripts written" || bad "scripts missing"
E="$H/seren-llama.env"
if ( . "$E" && [ "$LLAMA_MODEL" = "$H/models/qwen-test.gguf" ] && [ "$LLAMA_CTX" = 4096 ] \
       && [ "$LLAMA_PARALLEL" = 1 ] && [ "$LLAMA_NGL" = 999 ] ); then
    ok_ "settings file: the only .gguf here, and the Orin Nano's sizes (4k, one slot)"
else bad "settings: $(cat "$E" 2>/dev/null)"; fi

echo "== the manifest"
M="$H/.seren/services/llama.json"
if python3 - "$M" "$H" <<'PY'
import json, sys
m = json.load(open(sys.argv[1])); h = sys.argv[2]
assert m["service"] == "llama" and m["service_type"] == "pid_file", m
assert m["port"] == 8090 and m["endpoint"] == "/v1/chat/completions", m
assert m["start_script"] == h + "/start_llama.sh" and m["stop_script"] == h + "/stop_llama.sh", m
assert m["pid_path"] == h + "/seren-logs/llama.pid", m
ss = m["serviceSpecific"]
assert ss["models_dir"] == h + "/models" and ss["config_path"] == h + "/seren-llama.env", ss
assert "model" not in ss, "the model lives in the settings file, not a copy here"
PY
then ok_ "manifest: pid_file, port 8090, chat path, scripts, pid, models_dir + settings path"; else bad "manifest wrong: $(cat "$M" 2>/dev/null)"; fi

echo "== start and stop"
bash "$H/start_llama.sh" >/dev/null 2>&1; sleep 1
PID="$(cat "$H/seren-logs/llama.pid" 2>/dev/null)"
if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then ok_ "start runs it and records the pid"; else bad "not running after start"; fi
ARGS="$(cat "$H/llama.cpp/build/bin/args.txt" 2>/dev/null)"
[[ "$ARGS" == *"--model $H/models/qwen-test.gguf"* && "$ARGS" == *"--port 8090"* && "$ARGS" == *"--ctx-size 4096"* \
   && "$ARGS" == *"--n-gpu-layers 999"* && "$ARGS" == *"--parallel 1"* && "$ARGS" == *"--jinja"* ]] \
  && ok_ "started with the model, the port and the sizes from the settings file" || bad "args: $ARGS"
bash "$H/start_llama.sh" | grep -q "already running" && ok_ "a second start does not start a second server" || bad "double start"
bash "$H/stop_llama.sh"; sleep 1
if ! kill -0 "$PID" 2>/dev/null && [ ! -f "$H/seren-logs/llama.pid" ]; then ok_ "stop ends it and clears the pid"; else bad "still running after stop"; fi

echo "== no model, re-install, --llama-model"
cp "$E" "$T/env.bak"
sed -i "s|^LLAMA_MODEL=.*|LLAMA_MODEL=$H/models/gone.gguf|" "$E"
out="$(bash "$H/start_llama.sh" 2>&1)"; rc=$?
[[ $rc -ne 0 && "$out" == *"gone.gguf"* && "$out" == *"LLAMA_MODEL"* && ! -f "$H/seren-logs/llama.pid" ]] \
  && ok_ "a start with no model refuses and names the setting" || bad "no-model start: rc=$rc $out"
cp "$T/env.bak" "$E"
sed -i 's/^LLAMA_CTX=.*/LLAMA_CTX=2048/' "$E"
install_llama > "$T/install2.log" 2>&1
( . "$E" && [ "$LLAMA_CTX" = 2048 ] && [ "$LLAMA_MODEL" = "$H/models/qwen-test.gguf" ] ) \
  && ok_ "a re-install keeps the settings file as the user left it" || bad "re-install: $(cat "$E")"
printf 'another' > "$H/models/other.gguf"
LLAMA_MODEL=other.gguf install_llama > "$T/install3.log" 2>&1
( . "$E" && [ "$LLAMA_MODEL" = "$H/models/other.gguf" ] && [ "$LLAMA_CTX" = 2048 ] ) \
  && [ "$(grep -c '^LLAMA_MODEL=' "$E")" = 1 ] \
  && ok_ "--llama-model NAME sets the model from the models dir and touches nothing else" || bad "--llama-model: $(cat "$E")"

echo "== the Spark's defaults, and without a binary"
mkdir -p "$T/spark"
(
    export SEREN_TEST_HOME="$T/spark" USER_HOME="$T/spark"
    # shellcheck disable=SC1091
    source "$HERE/nodes/spark/llama.sh"
    install_llama > "$T/install-spark.log" 2>&1
)
( . "$T/spark/seren-llama.env" && [ "$LLAMA_CTX" = 32768 ] && [ "$LLAMA_PARALLEL" = 2 ] ) \
  && ok_ "Spark: 32k context, two slots (what start-llama-spark.sh ran)" || bad "spark env: $(cat "$T/spark/seren-llama.env" 2>/dev/null)"
printf 'x' > "$T/spark/models/model.gguf"
bash "$T/spark/start_llama.sh" >/dev/null 2>&1; sleep 1
SARGS="$(cat "$T/spark/llama.cpp/build/bin/args.txt" 2>/dev/null)"
[[ "$SARGS" == *"--cache-type-k q8_0 --cache-type-v q8_0"* && "$SARGS" == *"--parallel 2"* ]] \
  && ok_ "Spark: the q8_0 KV cache flags reach the server as separate arguments" || bad "spark args: $SARGS"
bash "$T/spark/stop_llama.sh"
[ ! -e "$T/spark/start-llama-spark.sh" ] && ok_ "Spark: no second launcher written" || bad "start-llama-spark.sh still written"
out="$(STAGED_LLAMA_BIN="$T/nope" install_llama 2>&1)"; rc=$?
[[ $rc -ne 0 && "$out" == *"Staged llama-server binary missing"* ]] && ok_ "a missing staged binary fails and says so" || bad "missing binary: rc=$rc"

echo
echo "  $PASS passed, $FAILS failed"
exit $FAILS
