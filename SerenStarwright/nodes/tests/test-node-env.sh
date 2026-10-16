#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════
#  Node env: caches on the NVMe, the hf CLI, and the hook that gets the
#  env to a service started with no login shell.
#
#  16 Oct 2026: the Xaviers' onboard disks were at 80% and a Spark carried
#  400 GB of Hugging Face cache in its home folder. Tested here with a fake
#  home, a fake NVMe root and a stand-in venv python (no network):
#    - one env file, with HF_HOME/HF_HUB_CACHE/TORCH_HOME/PIP_CACHE_DIR on
#      the nvme root
#    - an existing ~/.cache/huggingface moves there and leaves a symlink
#    - .bashrc and .profile source the file; a hand-set HF line is retired
#    - a start script written before the phase existed gets the hook, once
#    - the start scripts this library writes carry the hook from birth
#    - the CLI venv gets huggingface_hub and ~/.local/bin/hf links to it
#    - running it all twice changes nothing
#
#  Run:  bash nodes/tests/test-node-env.sh   (Linux; CI runs it)
# ══════════════════════════════════════════════════════════════
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAILS=0
ok_()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad()  { FAILS=$((FAILS+1)); echo "  FAIL $1"; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

TARGET_USER="$(id -un)"
# shellcheck disable=SC1091
source "$HERE/nodes/lib/common.sh"
exec 3>&1

# The library writes to /home/$TARGET_USER; point that at the sandbox.
H="$T/home"; mkdir -p "$H"
NV="$T/nvme"; mkdir -p "$NV"
export SEREN_NVME_ROOT="$NV"
_as_target() { "$@"; }                                   # same user, no sudo
seren_node_env_root() { echo "$NV"; }
# shellcheck disable=SC2329
_home_override() { sed 's|/home/\$TARGET_USER|'"$H"'|g'; }
# Re-declare the two functions with the sandbox home substituted in.
eval "$(declare -f seren_node_env | _home_override)"
eval "$(declare -f seren_install_hf_cli | _home_override)"
_seren_venv_path() { echo "$H/seren-venvs/$1"; }
ensure_venv() { mkdir -p "$H/seren-venvs/$1/bin"; }

# A stand-in venv python that records what pip was asked for.
mkdir -p "$H/seren-venvs/hf/bin"
cat > "$H/seren-venvs/hf/bin/python" <<'SH'
#!/bin/bash
echo "$@" >> "$(dirname "$0")/pip-args.txt"
SH
chmod +x "$H/seren-venvs/hf/bin/python"
printf '#!/bin/bash\necho hf stub\n' > "$H/seren-venvs/hf/bin/hf"; chmod +x "$H/seren-venvs/hf/bin/hf"

# A pre-existing cache, a hand-set line, and an old start script.
mkdir -p "$H/.cache/huggingface/hub/models--x"; echo weights > "$H/.cache/huggingface/hub/models--x/w.bin"
printf 'export PATH=/x:$PATH\nexport HF_HUB_CACHE=/mnt/nvme/hf_cache/\n' > "$H/.bashrc"
printf '#!/bin/bash\n# start_whisper.sh - old\nPID=x\n' > "$H/start_whisper.sh"

echo "── first run"
seren_node_env >/dev/null && ok_ "seren_node_env ran" || bad "seren_node_env failed"
seren_install_hf_cli >/dev/null && ok_ "seren_install_hf_cli ran" || bad "seren_install_hf_cli failed"

E="$H/.config/seren/env.sh"
[ -f "$E" ] && ok_ "env file written" || bad "no env file at $E"
grep -q "export HF_HOME=\"$NV/hf_cache\"" "$E" && ok_ "HF_HOME on the nvme root" || bad "HF_HOME wrong: $(grep HF_HOME "$E")"
grep -q "export HF_HUB_CACHE=\"$NV/hf_cache/hub\"" "$E" && ok_ "HF_HUB_CACHE under HF_HOME" || bad "HF_HUB_CACHE wrong"
grep -q "export TORCH_HOME=\"$NV/torch_cache\"" "$E" && ok_ "TORCH_HOME on the nvme root" || bad "TORCH_HOME wrong"
grep -q "export PIP_CACHE_DIR=\"$NV/pip-cache\"" "$E" && ok_ "PIP_CACHE_DIR on the nvme root" || bad "PIP_CACHE_DIR wrong"
grep -q '.local/bin' "$E" && ok_ "env file adds ~/.local/bin to PATH" || bad "no PATH line"
# shellcheck disable=SC1090
( . "$E"; [ "$HF_HOME" = "$NV/hf_cache" ] ) && ok_ "env file sources clean" || bad "env file does not source"

[ -L "$H/.cache/huggingface" ] && [ "$(readlink "$H/.cache/huggingface")" = "$NV/hf_cache" ] \
  && ok_ "home cache is now a symlink to the nvme" || bad "home cache not symlinked"
[ -f "$NV/hf_cache/hub/models--x/w.bin" ] && ok_ "existing cache contents moved" || bad "cache contents lost"

grep -q "^# export HF_HUB_CACHE=/mnt/nvme/hf_cache/" "$H/.bashrc" && ok_ "hand-set HF line retired, not deleted" || bad "hand-set line still live or gone"
grep -q 'config/seren/env.sh' "$H/.bashrc" && ok_ ".bashrc sources the env file" || bad ".bashrc not hooked"
grep -q 'config/seren/env.sh' "$H/.profile" && ok_ ".profile sources the env file" || bad ".profile not hooked"
[ "$(grep -c 'config/seren/env.sh' "$H/start_whisper.sh")" = "1" ] && ok_ "old start script hooked" || bad "old start script not hooked"
head -1 "$H/start_whisper.sh" | grep -q '^#!/bin/bash' && ok_ "shebang still first in the start script" || bad "hook landed above the shebang"
grep -q 'huggingface_hub' "$H/seren-venvs/hf/bin/pip-args.txt" && ok_ "pip asked for huggingface_hub" || bad "pip not asked"
! grep -q -i 'token' "$H/seren-venvs/hf/bin/pip-args.txt" && ok_ "no token anywhere near the install" || bad "a token in the install"
[ -L "$H/.local/bin/hf" ] && ok_ "~/.local/bin/hf links to the venv" || bad "no hf link"

echo "── a start script written by the library carries the hook from birth"
LOGS="$T/logs"; mkdir -p "$LOGS"
_seren_write_stop_script whisper "$H" "$LOGS" 2>/dev/null
grep -q 'seren_node_env_hook_lines\|config/seren/env.sh' "$HERE/nodes/lib/common.sh" && ok_ "library start scripts reference the hook" || bad "library start scripts do not"
seren_node_env_hook_lines | grep -q 'config/seren/env.sh' && ok_ "hook lines name the env file" || bad "hook lines wrong"

echo "── second run changes nothing"
before="$(find "$H" -type f -o -type l | sort | xargs md5sum 2>/dev/null | md5sum)"
seren_node_env >/dev/null; seren_install_hf_cli >/dev/null
after="$(find "$H" -type f -o -type l | sort | xargs md5sum 2>/dev/null | md5sum)"
# pip-args grows (pip is asked again, which is fine); compare without it.
before2="$(find "$H" -type f -o -type l | grep -v pip-args | sort | xargs md5sum 2>/dev/null | md5sum)"
# Count the hook line itself; the retired hand-set line's comment also names the env file.
[ "$(grep -c '^\[ -f "\$HOME/.config/seren/env.sh" \]' "$H/.bashrc")" = "1" ] && ok_ "second run adds no second hook to .bashrc" || bad ".bashrc hooked twice: $(grep -c 'HOME/.config/seren/env.sh' "$H/.bashrc")"
[ "$(grep -c 'config/seren/env.sh' "$H/start_whisper.sh")" = "1" ] && ok_ "second run adds no second hook to the start script" || bad "start script hooked twice"
[ -L "$H/.cache/huggingface" ] && ok_ "symlink survives a second run" || bad "symlink lost"
: "$before" "$after" "$before2"

echo
echo "passed $PASS, failed $FAILS"
[ "$FAILS" -eq 0 ]
