#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════
#  seren-wipe.sh takes the node services with it, and keeps the models.
#
#  Found 27 Sept 2026 adding the llama and Kokoro manifests: the wipe predated
#  the node services, so a wiped node kept ~/start_*.sh, ~/seren-llama.env and
#  ~/.seren/services/*.json - manifests the Observatory listed and could not
#  start. the user's call on models the same day: kept unless --models.
#
#  Proves, against a scratch home and a scratch NVMe (SEREN_TEST_HOME,
#  SEREN_TEST_NVME; sudo is a stub that runs the command as us):
#    - --dry-run removes nothing and names the new targets
#    - a plain wipe removes whisper.cpp, the start/stop scripts, the llama env,
#      the three node manifests and node.json
#    - it leaves manifests other installers wrote in ~/.seren/services
#    - it keeps models, ComfyUI models and the Ms.MoE run root, and says so
#    - --models removes them
#
#  Run:  bash nodes/tests/test-wipe.sh   (Linux; CI runs it)
# ══════════════════════════════════════════════════════════════
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WIPE="$HERE/nodes/lib/seren-wipe.sh"
PASS=0; FAILS=0
ok_()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad()  { FAILS=$((FAILS+1)); echo "  FAIL $1"; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

mkdir -p "$T/bin"
printf '#!/usr/bin/env bash\nexec "$@"\n' > "$T/bin/sudo"; chmod +x "$T/bin/sudo"

# A node that has had the whole prep: services, their scripts and manifests,
# one manifest from somebody else, and a few gigabytes of stand-in models.
seed() {   # seed HOME NVME
  local h="$1" n="$2"
  mkdir -p "$h/whisper.cpp/build/bin" "$h/llama.cpp/build/bin" "$h/Kokoro-FastAPI" \
           "$h/.seren/services" "$h/seren-logs" "$h/models/whisper" \
           "$n/models" "$n/comfyui-models" "$n/msMoEMaker" "$n/seren-venvs/kokoro"
  for s in whisper llama kokoro; do
    : > "$h/start_$s.sh"; : > "$h/stop_$s.sh"; echo '{}' > "$h/.seren/services/$s.json"
  done
  echo '{}' > "$h/.seren/services/seren-memory.json"
  echo '{}' > "$h/.seren/node.json"
  echo '{}' > "$h/.seren/node-state.json"
  echo 'LLAMA_MODEL=qwen.gguf' > "$h/seren-llama.env"
  : > "$h/models/whisper/ggml-base.en.bin"
  : > "$n/models/qwen.gguf"
}
wipe() {   # wipe HOME NVME ARGS...
  local h="$1" n="$2"; shift 2
  SEREN_TEST_HOME="$h" SEREN_TEST_NVME="$n" PATH="$T/bin:$PATH" \
    bash "$WIPE" -u "$(id -un)" "$@" 2>&1
}

GONE=(whisper.cpp llama.cpp start_whisper.sh stop_whisper.sh start_llama.sh stop_llama.sh
      start_kokoro.sh stop_kokoro.sh seren-llama.env .seren/services/whisper.json
      .seren/services/llama.json .seren/services/kokoro.json .seren/node.json
      .seren/node-state.json seren-logs)

echo "== --dry-run"
H="$T/h1"; N="$T/n1"; seed "$H" "$N"
out="$(wipe "$H" "$N" --dry-run)"
[[ -f "$H/start_llama.sh" && -d "$H/whisper.cpp" ]] && ok_ "dry run removes nothing" || bad "dry run removed something"
grep -q "$H/.seren/services/llama.json" <<<"$out" && grep -q "$H/whisper.cpp" <<<"$out" \
  && ok_ "dry run names the node service files" || bad "dry run does not name them: $out"
grep -q "$N/models (models and build output; --models removes them)" <<<"$out" \
  && ok_ "dry run says the models stay" || bad "dry run does not say the models stay"

echo "== plain wipe"
out="$(wipe "$H" "$N" --yes)"
missed=""; for p in "${GONE[@]}"; do [[ -e "$H/$p" ]] && missed+=" $p"; done
[[ -z "$missed" ]] && ok_ "node services, scripts, env, manifests and node.json removed" \
                   || bad "left behind:$missed"
[[ -f "$H/.seren/services/seren-memory.json" ]] && ok_ "another installer's manifest kept" \
                                               || bad "removed seren-memory.json, which it did not write"
[[ -f "$H/models/whisper/ggml-base.en.bin" && -f "$N/models/qwen.gguf" && -d "$N/comfyui-models" && -d "$N/msMoEMaker" ]] \
  && ok_ "models and build output kept" || bad "a model or run root went without --models"
[[ ! -e "$N/seren-venvs" ]] && ok_ "NVMe venvs removed" || bad "NVMe venvs left behind"

echo "== --models"
H="$T/h2"; N="$T/n2"; seed "$H" "$N"
out="$(wipe "$H" "$N" --yes --models)"
left=""; for p in "$H/models" "$N/models" "$N/comfyui-models" "$N/msMoEMaker"; do [[ -e "$p" ]] && left+=" $p"; done
[[ -z "$left" ]] && ok_ "--models removes models and build output" || bad "--models left:$left"

echo
echo "  $PASS passed, $FAILS failed"
exit $FAILS
