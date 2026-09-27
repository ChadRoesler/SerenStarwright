#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════
#  Kokoro on a node: start/stop and the Observatory manifest.
#
#  Design note: Kokoro was installed on every node and registered on
#  none. The install itself (git clone, pip, a 300MB model) needs the network
#  and is not what changed; the registration is, and it is tested here with a
#  fake repo and a fake venv python (no network, no GPU):
#    - both scripts land and the manifest is valid JSON with the fields the
#      Observatory reads, voices_path among them (/service/kokoro/voices)
#    - start runs uvicorn api.src.main:app from the repo, with the model dir
#      where the installers put the weights, and records the pid
#    - a second start does not start a second server; stop ends it and
#      clears the pid
#    - cpu hides the GPU, cuda does not; every platform registers
#    - a missing venv fails with the reason
#
#  Run:  bash nodes/tests/test-kokoro-install.sh   (Linux; CI runs it)
# ══════════════════════════════════════════════════════════════
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAILS=0
ok_()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad()  { FAILS=$((FAILS+1)); echo "  FAIL $1"; }
T="$(mktemp -d)"; trap 'bash "$T/home/stop_kokoro.sh" >/dev/null 2>&1; rm -rf "$T"' EXIT

TARGET_USER="$(id -un)"
# shellcheck disable=SC1091
source "$HERE/nodes/lib/common.sh"
exec 3>&1

H="$T/home"
R="$H/Kokoro-FastAPI"
mkdir -p "$R/api/src/voices/v1_0" "$R/src/models/v1_0" "$H/seren-venvs/kokoro/bin"
# a stand-in venv python: records its arguments and what it was started with, then sleeps
cat > "$H/seren-venvs/kokoro/bin/python" <<'SH'
#!/bin/bash
d="$(dirname "$0")"
echo "$@" > "$d/args.txt"
{ echo "cwd=$PWD"; echo "MODEL_DIR=$MODEL_DIR"; echo "VOICES_DIR=$VOICES_DIR"
  echo "PYTHONPATH=$PYTHONPATH"; echo "USE_GPU=$USE_GPU"; echo "CVD=${CUDA_VISIBLE_DEVICES-unset}"; } > "$d/env.txt"
exec sleep 60
SH
chmod +x "$H/seren-venvs/kokoro/bin/python"

export SEREN_TEST_HOME="$H" USER_HOME="$H"
unset KOKORO_PORT

echo "== register"
seren_register_kokoro cpu > "$T/reg.log" 2>&1 && ok_ "seren_register_kokoro succeeds" || { bad "register failed"; cat "$T/reg.log"; }
[ -x "$H/start_kokoro.sh" ] && [ -x "$H/stop_kokoro.sh" ] && ok_ "start and stop scripts written" || bad "scripts missing"

echo "== the manifest"
M="$H/.seren/services/kokoro.json"
if python3 - "$M" "$H" <<'PY'
import json, sys
m = json.load(open(sys.argv[1])); h = sys.argv[2]
assert m["service"] == "kokoro" and m["service_type"] == "pid_file", m
assert m["port"] == 8880 and m["endpoint"] == "/v1/audio/speech", m
assert m["start_script"] == h + "/start_kokoro.sh" and m["stop_script"] == h + "/stop_kokoro.sh", m
assert m["pid_path"] == h + "/seren-logs/kokoro.pid", m
assert m["venv_path"] == h + "/seren-venvs/kokoro", m
ss = m["serviceSpecific"]
assert ss["voices_path"] == h + "/Kokoro-FastAPI/api/src/voices/v1_0" and ss["device"] == "cpu", ss
PY
then ok_ "manifest: pid_file, port 8880, the speech path, scripts, pid, voices_path"; else bad "manifest wrong: $(cat "$M" 2>/dev/null)"; fi

echo "== start and stop"
bash "$H/start_kokoro.sh" >/dev/null 2>&1; sleep 1
PID="$(cat "$H/seren-logs/kokoro.pid" 2>/dev/null)"
if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then ok_ "start runs it and records the pid"; else bad "not running after start"; fi
ARGS="$(cat "$H/seren-venvs/kokoro/bin/args.txt" 2>/dev/null)"
[[ "$ARGS" == "-m uvicorn api.src.main:app --host 0.0.0.0 --port 8880" ]] \
  && ok_ "started as uvicorn api.src.main:app on 8880" || bad "args: $ARGS"
ENV="$(cat "$H/seren-venvs/kokoro/bin/env.txt" 2>/dev/null)"
[[ "$ENV" == *"cwd=$R"$'\n'* && "$ENV" == *"MODEL_DIR=$R/src/models"$'\n'* \
   && "$ENV" == *"VOICES_DIR=$R/api/src/voices/v1_0"$'\n'* && "$ENV" == *"PYTHONPATH=$R:$R/api"$'\n'* ]] \
  && ok_ "from the repo, with the model dir where the installers put the weights" || bad "env: $ENV"
[[ "$ENV" == *"USE_GPU=false"* && "$ENV" == *$'\n'"CVD=" ]] \
  && ok_ "cpu: USE_GPU off and the GPU hidden" || bad "cpu env: $ENV"
bash "$H/start_kokoro.sh" | grep -q "already running" && ok_ "a second start does not start a second server" || bad "double start"
bash "$H/stop_kokoro.sh"; sleep 1
if ! kill -0 "$PID" 2>/dev/null && [ ! -f "$H/seren-logs/kokoro.pid" ]; then ok_ "stop ends it and clears the pid"; else bad "still running after stop"; fi

echo "== cuda, every platform, and without a venv"
seren_register_kokoro cuda > "$T/reg2.log" 2>&1
bash "$H/start_kokoro.sh" >/dev/null 2>&1; sleep 1
ENV="$(cat "$H/seren-venvs/kokoro/bin/env.txt" 2>/dev/null)"
[[ "$ENV" == *"USE_GPU=true"* && "$ENV" == *"CVD=unset"* ]] && ok_ "cuda: USE_GPU on and the GPU visible" || bad "cuda env: $ENV"
bash "$H/stop_kokoro.sh"
dev_ok=true
for p in nano:cpu xavier:cpu spark:cuda; do
    grep -qx "    seren_register_kokoro ${p#*:}" "$HERE/nodes/${p%%:*}/kokoro.sh" || { dev_ok=false; echo "    ${p%%:*} does not register as ${p#*:}"; }
done
$dev_ok && ok_ "every platform's install_kokoro registers (Jetsons on cpu, the Spark on cuda)" || bad "a platform does not register"
mv "$H/seren-venvs/kokoro" "$T/venv.away"
out="$(seren_register_kokoro cpu 2>&1)"; rc=$?
[[ $rc -ne 0 && "$out" == *"seren-venvs/kokoro"* ]] && ok_ "a missing venv fails and names where it looked" || bad "missing venv: rc=$rc"

echo
echo "  $PASS passed, $FAILS failed"
exit $FAILS
