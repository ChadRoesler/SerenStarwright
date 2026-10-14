#!/usr/bin/env bash
# ════════════════════════════════════════════════════════
#  ComfyUI on a node: start/stop and the Observatory manifest.
#
#  5 Oct 2026: ComfyUI installed "successfully" on the Xavier 32 and Lodestar
#  could not see it - the install wrote no start script and no manifest. The
#  install itself (a git clone and pip) needs the network and is not what
#  changed; the registration is, tested here with a fake repo and a fake venv
#  python (no network, no GPU):
#    - both scripts land and the manifest is the one the Observatory's
#      /service/comfy routes read (named "comfy", with the three model dirs)
#    - start runs main.py from the repo on 0.0.0.0, with this platform's CUDA
#      path set (the Xavier's compat shim), and records the pid
#    - a second start does not start a second server; stop ends it
#    - extra arguments (--lowvram on a Nano) reach main.py
#    - a missing venv fails with the reason; every platform's module registers
#      and asks torch about CUDA with the CUDA path set
#    - with a model store outside the checkout (/mnt/nvme/comfyui-models on a
#      node), ComfyUI is pointed at it (extra_model_paths.yaml) and so is the
#      manifest; a yaml someone wrote themselves is left alone
#    - the families a ComfyUI can draw reach the manifest; a ComfyUI made by
#      hand (the Spark's) is adopted where it is, with its own python
#    - the Xavier pins ComfyUI to the last release torch 2.1 runs
#
#  Run:  bash nodes/tests/test-comfy-install.sh   (Linux; CI runs it)
# ════════════════════════════════════════════════════════
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAILS=0
ok_()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad()  { FAILS=$((FAILS+1)); echo "  FAIL $1"; }
T="$(mktemp -d)"; trap 'bash "$T/home/stop_comfy.sh" >/dev/null 2>&1; rm -rf "$T"' EXIT

TARGET_USER="$(id -un)"
# shellcheck disable=SC1091
source "$HERE/nodes/lib/common.sh"
exec 3>&1

H="$T/home"
R="$H/ComfyUI"
mkdir -p "$R/models" "$H/seren-venvs/comfy/bin"
touch "$R/main.py"
cat > "$H/seren-venvs/comfy/bin/python" <<'SH'
#!/bin/bash
d="$(dirname "$0")"
echo "$@" > "$d/args.txt"
{ echo "cwd=$PWD"; echo "LD=$LD_LIBRARY_PATH"; } > "$d/env.txt"
exec sleep 60
SH
chmod +x "$H/seren-venvs/comfy/bin/python"

export SEREN_TEST_HOME="$H" USER_HOME="$H"
unset COMFY_PORT
PLATFORM=xavier

echo "== register"
seren_register_comfy > "$T/reg.log" 2>&1 && ok_ "seren_register_comfy succeeds" || { bad "register failed"; cat "$T/reg.log"; }
[ -x "$H/start_comfy.sh" ] && [ -x "$H/stop_comfy.sh" ] && ok_ "start and stop scripts written" || bad "scripts missing"

echo "== the manifest"
M="$H/.seren/services/comfy.json"
if python3 - "$M" "$H" <<'PY'
import json, sys
m = json.load(open(sys.argv[1])); h = sys.argv[2]
assert m["service"] == "comfy" and m["service_type"] == "pid_file", m
assert m["port"] == 8188 and m["health_path"] == "/system_stats", m
assert m["start_script"] == h + "/start_comfy.sh" and m["stop_script"] == h + "/stop_comfy.sh", m
assert m["pid_path"] == h + "/seren-logs/comfy.pid" and m["log_path"] == h + "/seren-logs/comfy.log", m
s = m["serviceSpecific"]
assert s["checkpoints_dir"] == h + "/ComfyUI/models/checkpoints", s
assert s["loras_dir"] == h + "/ComfyUI/models/loras" and s["vae_dir"] == h + "/ComfyUI/models/vae", s
PY
then ok_ "named comfy, with the port, the scripts and the three model dirs"; else bad "manifest wrong: $(cat "$M" 2>/dev/null)"; fi

echo "== a model store outside the checkout"
S="$T/nvme/comfyui-models"
COMFY_MODELS="$S" seren_register_comfy > "$T/reg2.log" 2>&1 && ok_ "registers with COMFY_MODELS" || { bad "register failed"; cat "$T/reg2.log"; }
[ -d "$S/checkpoints" ] && [ -d "$S/loras" ] && [ -d "$S/diffusion_models" ] && [ -d "$S/text_encoders" ] \
  && ok_ "the store's folders are made" || bad "store folders missing: $(ls "$S" 2>/dev/null)"
X="$R/extra_model_paths.yaml"
grep -q "written by seren-prepare-node" "$X" && grep -q "base_path: $S" "$X" && grep -q "is_default: true" "$X" \
  && ok_ "ComfyUI is pointed at it (extra_model_paths.yaml)" || bad "extra_model_paths.yaml: $(cat "$X" 2>/dev/null)"
if python3 - "$M" "$S" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))["serviceSpecific"]; d = sys.argv[2]
assert s["models_dir"] == d and s["checkpoints_dir"] == d + "/checkpoints" and s["loras_dir"] == d + "/loras", s
PY
then ok_ "and so is the manifest (models_dir, the catalog's folder)"; else bad "manifest: $(cat "$M")"; fi
printf 'mine:\n    base_path: /data/models\n' > "$X"
COMFY_MODELS="$S" seren_register_comfy > "$T/reg3.log" 2>&1
grep -q "^mine:" "$X" && ! grep -q "seren-prepare-node" "$X" && grep -q "left as it is" "$T/reg3.log" \
  && ok_ "a yaml someone wrote is left alone, and they are told" || bad "own yaml clobbered: $(cat "$X")"
rm -f "$X"
seren_register_comfy > /dev/null 2>&1                     # back to the plain layout for what follows

echo "== families, and adopting a ComfyUI made by hand"
COMFY_FAMILIES="sdxl,sd15" seren_register_comfy > /dev/null 2>&1
grep -q '"families": "sdxl,sd15"' "$M" && ok_ "the families it draws reach the manifest" || bad "no families: $(cat "$M")"
A="$T/opt/image_gen/ComfyUI"; AP="$T/opt/dgx-env/bin/python3"
mkdir -p "$A/models" "$(dirname "$AP")"; touch "$A/main.py"; cp "$H/seren-venvs/comfy/bin/python" "$AP"
COMFY_DIR="$A" COMFY_PYTHON="$AP" seren_register_comfy --reserve-vram 8 > "$T/adopt.log" 2>&1 \
  && grep -q "cd \"$A\"" "$H/start_comfy.sh" && grep -q "\"$AP\" main.py --listen 0.0.0.0 --port 8188 --reserve-vram 8" "$H/start_comfy.sh" \
  && grep -q "\"checkpoints_dir\": \"$A/models/checkpoints\"" "$M" && ! grep -q '"families"' "$M" \
  && [ ! -e "$A/extra_model_paths.yaml" ] \
  && ok_ "an install made by hand is adopted where it is, with its own python" \
  || { bad "adopting failed"; cat "$T/adopt.log"; grep -n "main.py\|cd " "$H/start_comfy.sh"; }
grep -q 'COMFY_REF:-v0.3.65' "$HERE/nodes/xavier/comfy.sh" && grep -q 'COMFY_FAMILIES:-sdxl,sd15' "$HERE/nodes/xavier/comfy.sh" \
  && ! grep -q "COMFY_REF" "$HERE/nodes/spark/comfy.sh" \
  && ok_ "the Xavier pins ComfyUI to what torch 2.1 runs, and says it draws SDXL and SD 1.5" || bad "the Xavier pin is missing"
seren_register_comfy > /dev/null 2>&1                     # back to the plain layout for what follows

echo "== start, start again, stop"
bash "$H/start_comfy.sh" >/dev/null 2>&1; sleep 1
PIDF="$H/seren-logs/comfy.pid"
[ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null && ok_ "start records a live pid" || bad "no live pid"
grep -q "^main.py --listen 0.0.0.0 --port 8188" "$H/seren-venvs/comfy/bin/args.txt" && ok_ "main.py on 0.0.0.0:8188" || bad "args: $(cat "$H/seren-venvs/comfy/bin/args.txt" 2>/dev/null)"
grep -q "^cwd=$R$" "$H/seren-venvs/comfy/bin/env.txt" && ok_ "from the repo" || bad "cwd wrong"
grep -q "^LD=/usr/local/cuda-12.2/compat:/usr/local/cuda-12.2/lib64" "$H/seren-venvs/comfy/bin/env.txt" \
  && ok_ "with the Xavier's compat shim on the library path" || bad "LD: $(cat "$H/seren-venvs/comfy/bin/env.txt")"
first="$(cat "$PIDF")"
bash "$H/start_comfy.sh" 2>&1 | grep -q "already running" && [ "$(cat "$PIDF")" = "$first" ] \
  && ok_ "a second start does not start a second server" || bad "second start misbehaved"
bash "$H/stop_comfy.sh" >/dev/null 2>&1
! kill -0 "$first" 2>/dev/null && [ ! -f "$PIDF" ] && ok_ "stop ends it and clears the pid" || bad "still running after stop"

echo "== a Nano passes --lowvram, on its own CUDA path"
PLATFORM=nano
seren_register_comfy --lowvram >/dev/null 2>&1
grep -q -- "--port 8188 --lowvram" "$H/start_comfy.sh" && ok_ "extra arguments reach main.py" || bad "no --lowvram in the start script"
grep -q 'LD_LIBRARY_PATH="/usr/local/cuda-12.6/lib64:' "$H/start_comfy.sh" && ok_ "and the Nano's CUDA path" || bad "wrong CUDA path for a Nano"

echo "== failure, and every platform"
rm -f "$H/seren-venvs/comfy/bin/python"
if seren_register_comfy > "$T/miss.log" 2>&1; then bad "a missing venv should fail"; else ok_ "a missing venv fails"; fi
grep -q "not where its start script would look" "$T/miss.log" && ok_ "and says why" || bad "no reason given"
for p in xavier nano spark; do
  f="$HERE/nodes/$p/comfy.sh"
  grep -q "seren_register_comfy" "$f" && grep -q "venv_python_cuda comfy" "$f" \
    && ok_ "$p registers ComfyUI and checks CUDA with the CUDA path set" || bad "$p/comfy.sh does not"
done
grep -q '"numpy<2"' "$HERE/nodes/xavier/comfy.sh" && ! grep -q '"numpy<2"' "$HERE/nodes/nano/comfy.sh" \
  && ok_ "numpy is held below 2 on the Xavier only (torch 2.1.0)" || bad "the numpy pin is not where it belongs"
grep -q "start_comfy.sh" "$HERE/nodes/lib/seren-wipe.sh" && grep -q "services/comfy.json" "$HERE/nodes/lib/seren-wipe.sh" \
  && ok_ "a node wipe removes what this wrote" || bad "seren-wipe does not know about comfy"

echo ""
echo "$PASS passed, $FAILS failed"
[ "$FAILS" = 0 ]
