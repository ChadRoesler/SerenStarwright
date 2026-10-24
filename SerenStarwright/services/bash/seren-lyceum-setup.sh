#!/usr/bin/env bash
# ==========================================================================
#  seren-lyceum-setup.sh  -  one-shot SerenLyceum installer (Linux + macOS)
#
#  Sources seren-install-lib.sh (shared installer library). Identity lines,
#  the TRAINING ENVIRONMENT and the sibling hippocampus are the unique parts.
#
#  The Lyceum is two environments, on purpose. The service (this venv) never
#  imports torch: it writes a job's folder and forks the trainer in the
#  TRAINING venv (seren-lyceum[train] + a torch built for this box's GPU),
#  detached, so a restart of the service never kills a run. --train builds
#  that second venv; --train-python points at one that already exists. With
#  neither, this box does not train locally (the UI says so) and can still
#  send jobs to a cloud.
#
#  The unit is installed with KillMode=process for the same reason: systemd
#  stops a whole cgroup by default, and the trainer is in it.
#
#  USAGE
#    bash seren-lyceum-setup.sh --train --service --gen-token --host 0.0.0.0
#    bash seren-lyceum-setup.sh --root /mnt/nvme/seren/wren --instance wren \
#         --port 7258 --train --llama-cpp /mnt/nvme/llama.cpp --label "the Spark" \
#         --hippocampus-url http://192.0.2.200:7254 --hippocampus-token ... --service
#
#  FLAGS
#    --port N               Port to listen on            (default 7428)
#    --host HOST            Bind address                 (default 127.0.0.1)
#    --token TOKEN          Set a bearer token (needed when --host is not loopback)
#    --gen-token            Generate a random bearer token
#    --train                Build the training venv (torch + seren-lyceum[train])
#    --train-python PATH    Use this training interpreter instead of building one
#    --torch-index URL      Where torch comes from     (default: CUDA 13.0 wheels,
#                           https://download.pytorch.org/whl/cu130; cpu for none)
#    --llama-cpp PATH       A llama.cpp checkout with llama-quantize built, for
#                           the GGUF at the end of a run (default: node setup's
#                           /mnt/nvme/llama.cpp when it is there)
#    --hf-home PATH         Hugging Face's home: the models and the login
#                           (default: node setup's HF_HOME, else ~/.cache/huggingface).
#                           A login already there (node setup, `hf auth login`)
#                           is used; the Lyceum asks only when there is none.
#    --label TEXT           How the UI names this box ("the Spark")
#    --hippocampus-url URL  A hippocampus to import lessons from
#    --hippocampus-token T  Its bearer (the token it was installed with)
#    --hippocampus-config P Its own config: url AND bearer, read from the file
#    --repo-dir PATH        SerenLyceum repo checkout   (default: sibling ../SerenLyceum)
#    --wheel PATH           Install from a local .whl
#    --local DIR|URL        Install from a dev wheelhouse (seren-dev-publish.sh)
#    --pypi                 Install seren-lyceum from PyPI
#    --ref TAG              Pin to a GitHub release tag
#    --repo SLUG            GitHub release repo
#    --service              Autostart via systemd/launchd
#    --instance NAME        Instance name
#    --root DIR             Install root: venvs, apps, stores, logs in one folder
#    --venv PATH            Override venv location
#    --no-updates           Turn update checking OFF in the generated config
#    -h, --help             This help
# ==========================================================================
set -euo pipefail

OS="$(uname -s)"
IS_MAC=false
[[ "$OS" == "Darwin" ]] && IS_MAC=true

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; B='\033[0;34m'; NC='\033[0m'
step() { echo -e "\n${B}==>${NC} $1"; }
ok()   { echo -e "${G}  ✓${NC} $1"; }
warn() { echo -e "${Y}  !${NC} $1"; }
die()  { echo -e "${R}ERROR:${NC} $1" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -- bootstrap find_upward (needed before sourcing the lib) --------------------
find_upward() {
  local rel="$1" dir="${2:-$SCRIPT_DIR}"
  while [[ "$dir" != "/" && -n "$dir" ]]; do
    [[ -e "$dir/$rel" ]] && { echo "$dir/$rel"; return 0; }
    dir="$(dirname "$dir")"
  done
  return 1
}

# -- source the shared installer library ---------------------------------------
lib="$(find_upward "services/lib/seren-install-lib.sh" || true)"
[[ -z "$lib" ]] && die "seren-install-lib.sh not found. Keep the services/lib/ folder with the shared scripts."
source "$lib"

# -- defaults ---------------------------------------------------------------
PORT=7428
HOST="127.0.0.1"
REPO_DIR="$(find_upward "SerenLyceum" || true)"   # sibling checkout (build source)
WHEEL=""
LOCAL=""
USE_PYPI=false
REF=""
REPO=""
INSTALL_SERVICE=false
SERVICE_USER=""
UPDATES_OFF=false
INSTANCE=""
ROOT=""
VENV_DIR="$HOME/seren-venvs/lyceum"
APP_DIR="$HOME/seren-lyceum"
TOKEN=""
GEN_TOKEN=false
TRAIN=false
TRAIN_PY=""
TORCH_INDEX="https://download.pytorch.org/whl/cu130"
LLAMA_CPP=""
HF_HOME_DIR=""
LABEL=""
HIP_URL=""
HIP_TOKEN=""
HIP_CONFIG=""

# -- Starwright contract: identity + machine-readable metadata ----------------
# Consumed by `--describe`; flags are derived from the case branches below.
# seren_lyceum/app.py carries the same accent (ACCENT) and config.py the
# same default port (DEFAULT_PORT).
SVC_NAME="seren-lyceum"
SVC_DISPLAY="Seren Lyceum"
SVC_DESC="Train your own model: a dataset in, a model out"
SVC_GROUP="auxiliary"
SVC_PACKAGE="seren-lyceum"
# Pithos clay: the jar Diogenes lived in, outside the schools.
SVC_ACCENT="#a17056"
# Requires nothing. A hippocampus is where its first dataset comes from in
# this family, so it is recommended, not required: a Lyceum trains on any
# JSONL a person hands it.
SVC_REQUIRES=""
SVC_RECOMMENDS="seren-hippocampus"
# Not pip extras in the [mcp]/[corp] sense: --train builds a second venv.
SVC_EXTRAS=""
SVC_SECRETS="hippocampus-token=SEREN_HIPPOCAMPUS_TOKEN"
SVC_CONFIG_KEYS="label=local.label llama-cpp=local.llama_cpp hf-home=local.hf_home train-python=local.python hippocampus-url=hippocampus.url hippocampus-token=hippocampus.bearer_token"

# --describe must answer with ZERO side effects: no venv, no network, no python.
SEREN_INSTALL_ARGV="$(printf '%s
' "$@")"     # recorded on the install record, minus secrets
for _a in "$@"; do
  [[ "$_a" == "--describe" ]] && { seren_describe; exit 0; }
done

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)      PORT="$2"; shift 2 ;;
    --host)      HOST="$2"; shift 2 ;;
    --token)     TOKEN="$2"; shift 2 ;;
    --gen-token) GEN_TOKEN=true; shift ;;
    --train)     TRAIN=true; shift ;;
    --train-python) TRAIN_PY="$2"; shift 2 ;;
    --torch-index)  TORCH_INDEX="$2"; shift 2 ;;
    --llama-cpp) LLAMA_CPP="$2"; shift 2 ;;
    --hf-home)   HF_HOME_DIR="$2"; shift 2 ;;
    --label)     LABEL="$2"; shift 2 ;;
    --hippocampus-url)    HIP_URL="$2"; shift 2 ;;
    --hippocampus-token)  HIP_TOKEN="$2"; shift 2 ;;
    --hippocampus-config) HIP_CONFIG="$2"; shift 2 ;;
    --repo-dir)  REPO_DIR="$2"; shift 2 ;;
    --wheel)     WHEEL="$2"; shift 2 ;;
    --local)     LOCAL="$2"; shift 2 ;;
    --pypi)      USE_PYPI=true; shift ;;
    --ref)       REF="$2"; shift 2 ;;
    --repo)      REPO="$2"; shift 2 ;;
    --service)   INSTALL_SERVICE=true; shift ;;
    --no-updates) UPDATES_OFF=true; shift ;;
    --service-user) SERVICE_USER="$2"; shift 2 ;;
    --instance)  INSTANCE="$2"; shift 2 ;;
    --root)      ROOT="$2"; shift 2 ;;
    --venv)      VENV_DIR="$2"; shift 2 ;;
    --json)      seren_json_on; shift ;;
    --describe)  seren_describe; exit 0 ;;
    -h|--help)   awk 'NR>1{ if (/^#/) { sub(/^# ?/,""); print } else exit }' "$0"; exit 0 ;;
    *)           die "unknown flag: $1  (try --help)" ;;
  esac
done
# a secret may arrive in the environment instead (Starwright's password box)
[[ -z "$HIP_TOKEN" && -n "${SEREN_HIPPOCAMPUS_TOKEN:-}" ]] && HIP_TOKEN="$SEREN_HIPPOCAMPUS_TOKEN"

seren_layout "lyceum"
CFG_PATH="$APP_DIR/seren-lyceum.yaml"
# The training venv sits beside the service's: <root>/venvs/lyceum-train under
# a root, ~/seren-venvs/lyceum<instance>-train without one.
TRAIN_VENV="${VENV_DIR}-train"
CONNECT_HOST="$HOST"
[[ "$HOST" == "0.0.0.0" ]] && CONNECT_HOST="127.0.0.1"
[[ -n "$INSTANCE" && "$PORT" == "7428" ]] && warn "Instance '$INSTANCE' uses default port 7428 - may collide."

if (exec 9<>"/dev/tcp/${CONNECT_HOST}/${PORT}") 2>/dev/null; then
  warn "Something is already answering on ${CONNECT_HOST}:${PORT}."
  warn "If that's an older SerenLyceum, carry on - this will upgrade it."
fi

echo -e "${G}==========================================${NC}"
$IS_MAC && echo -e "${G}  SerenLyceum setup (macOS)${NC}" || echo -e "${G}  SerenLyceum setup (Linux)${NC}"
echo -e "${G}==========================================${NC}"

# -- 1. find Python -----------------------------------------------------------
PYBIN="$(find_python)"
[[ -n "$REF" && -z "$REPO" ]] && REPO="ChadRoesler/SerenLyceum"

# -- 2. resolve what to install ------------------------------------------------
PACKAGE="seren-lyceum"
WHEEL_SRC=""
CLEANUP_WHEEL=false
if [[ -n "$WHEEL" ]]; then
  [[ -f "$WHEEL" ]] || die "wheel not found: $WHEEL"
  WHEEL_SRC="$WHEEL"
  ok "Installing from local wheel: $(basename "$WHEEL")"
elif [[ -n "$LOCAL" || -n "$REPO" ]]; then
  resolve_wheel
elif $USE_PYPI; then
  WHEEL_SRC="seren-lyceum"
  ok "Installing the latest seren-lyceum from PyPI"
else
  step "Building a wheel from the SerenLyceum checkout"
  PKG_DIR="${REPO_DIR}/SerenLyceum"
  [[ -f "${PKG_DIR}/pyproject.toml" ]] || die "SerenLyceum checkout not found at ${PKG_DIR}
  Point --repo-dir at your SerenLyceum repo, or use --wheel / --pypi / --ref."
  BUILD_VENV="$(mktemp -d)/build-venv"
  "$PYBIN" -m venv "$BUILD_VENV"
  "$BUILD_VENV/bin/pip" install -q --upgrade pip build
  rm -f "${PKG_DIR}/dist/"*.whl 2>/dev/null || true
  "$BUILD_VENV/bin/python" -m build --wheel "$PKG_DIR"
  rm -rf "${BUILD_VENV%/*}"
  WHEEL_SRC="$(ls -t "${PKG_DIR}/dist/"*.whl 2>/dev/null | head -1 || true)"
  [[ -n "$WHEEL_SRC" && -f "$WHEEL_SRC" ]] || die "build completed but no wheel in ${PKG_DIR}/dist/"
  ok "Built $(basename "$WHEEL_SRC")"
fi

# -- 3. the service's venv ------------------------------------------------------
create_venv "$VENV_DIR"
VPY="$VENV_DIR/bin/python"
pip_install "$VPY" "$WHEEL_SRC" "" "" ""

step "Sanity-checking the install"
CHECK="$("$VPY" - <<'PY'
try:
    import seren_lyceum                                # noqa: F401
    from seren_lyceum.app import create_app            # noqa: F401
except Exception as e:
    print(f"IMPORT_FAILED: {e}"); raise SystemExit
print("OK")
PY
)" || CHECK="FAILED"
[[ "$CHECK" == "OK" ]] && ok "Package imports and the app factory is reachable" || die "Install looks broken: $CHECK"

# -- 4. the training environment -------------------------------------------------
# A second venv: torch built for this GPU, and seren-lyceum[train] on top. An
# existing one is reused - torch is gigabytes, and a reinstall that rebuilt it
# every time would be the slowest part of upgrading a web page.
if [[ -n "$TRAIN_PY" ]]; then
  [[ -x "$TRAIN_PY" ]] || die "--train-python is not an interpreter: $TRAIN_PY"
  ok "Training with the environment you named: $TRAIN_PY"
elif $TRAIN; then
  step "The training environment ($TRAIN_VENV)"
  create_venv "$TRAIN_VENV"
  TRAIN_PY="$TRAIN_VENV/bin/python"
  if "$TRAIN_PY" -c 'import torch' 2>/dev/null; then
    ok "torch is already there: $("$TRAIN_PY" -c 'import torch; print(torch.__version__)')"
  else
    step "Installing torch from $TORCH_INDEX (the big one)"
    "$TRAIN_PY" -m pip install -q --upgrade pip || warn "could not upgrade pip in the training venv"
    "$TRAIN_PY" -m pip install torch --index-url "$TORCH_INDEX" || die "torch did not install from $TORCH_INDEX
  A GPU needs a torch built for it; pick the index with --torch-index (cpu: https://download.pytorch.org/whl/cpu)."
  fi
  pip_install "$TRAIN_PY" "$WHEEL_SRC" "[train]" "" " (the trainer)"
elif [[ -x "$TRAIN_VENV/bin/python" ]]; then
  TRAIN_PY="$TRAIN_VENV/bin/python"
  ok "Keeping the training environment that is there: $TRAIN_VENV"
  pip_install "$TRAIN_PY" "$WHEEL_SRC" "" "" " (the trainer, upgraded beside the service)"
else
  warn "No training environment (--train builds one): this box will not train locally."
fi
if [[ -n "$TRAIN_PY" ]]; then
  CHECKED="$("$TRAIN_PY" -m seren_lyceum.trainer.cli --check 2>/dev/null | tail -1 || true)"
  case "$CHECKED" in
    *'"ok": true'*) ok "The trainer answers: $(sed -E 's/.*"gpu": "?([^",]*)"?.*/\1/' <<<"$CHECKED")" ;;
    *) warn "The trainer's own check did not pass - the UI's This box tab says why: ${CHECKED:0:200}" ;;
  esac
fi

# -- 5. what node setup already knows ----------------------------------------------
# Node setup writes ~/.config/seren/env.sh (HF_HOME on the nvme) and builds
# llama.cpp at /mnt/nvme/llama.cpp. Reference them rather than ask again.
NODE_ENV="$HOME/.config/seren/env.sh"
if [[ -z "$HF_HOME_DIR" && -r "$NODE_ENV" ]]; then
  HF_HOME_DIR="$(bash -c ". '$NODE_ENV' >/dev/null 2>&1; echo \"\${HF_HOME:-}\"")"
  [[ -n "$HF_HOME_DIR" ]] && ok "Hugging Face's home from node setup: $HF_HOME_DIR"
fi
[[ -z "$HF_HOME_DIR" && -n "${HF_HOME:-}" ]] && HF_HOME_DIR="$HF_HOME"
if [[ -n "$HF_HOME_DIR" && -s "$HF_HOME_DIR/token" ]]; then
  ok "A Hugging Face login is there already; the Lyceum will use it"
elif [[ -n "$HF_HOME_DIR" ]]; then
  ok "No Hugging Face login yet - most models need none; the Lyceum asks when one does"
fi
if [[ -z "$LLAMA_CPP" && -d /mnt/nvme/llama.cpp ]]; then
  LLAMA_CPP="/mnt/nvme/llama.cpp"
  ok "llama.cpp from node setup: $LLAMA_CPP"
fi
if [[ -n "$LLAMA_CPP" ]] && ! ls "$LLAMA_CPP"/build/bin/llama-quantize >/dev/null 2>&1; then
  warn "No llama-quantize in $LLAMA_CPP/build/bin: runs will end without a GGUF until it is built"
  warn "  cmake --build $LLAMA_CPP/build --target llama-quantize -j"
fi

# -- 6. the sibling hippocampus ------------------------------------------------------
HIP_TOKEN_LINES=""
if [[ -n "$HIP_CONFIG" ]]; then
  seren_read_sibling_config "$HIP_CONFIG" || die "could not read the hippocampus's config: $HIP_CONFIG"
  [[ -z "$HIP_URL" ]] && HIP_URL="$SIB_URL"
  HIP_TOKEN_LINES="$(seren_sibling_token_lines "  ")"
fi
[[ -n "$HIP_TOKEN" ]] && HIP_TOKEN_LINES="$(printf '  bearer_token: "%s"' "$HIP_TOKEN")"
[[ -n "$HIP_URL" ]] && ok "Lessons from the hippocampus at $HIP_URL$([[ -n "$HIP_TOKEN_LINES" ]] && echo ", with its bearer")"

# -- 7. config --------------------------------------------------------------
step "Writing config at $CFG_PATH"
mkdir -p "$APP_DIR"
$GEN_TOKEN && TOKEN="$("$VPY" -c 'import secrets; print(secrets.token_urlsafe(32))')"
if [[ -z "$TOKEN" ]] && ! $GEN_TOKEN; then seren_reuse_token "$CFG_PATH" || true; fi
[[ -f "$CFG_PATH" ]] && cp "$CFG_PATH" "$CFG_PATH.bak.$(date +%s)" && warn "Existing config backed up"
case "$HOST" in
  127.*|localhost|::1) ;;
  *) [[ -z "$TOKEN" ]] && warn "--host $HOST with no bearer: SerenLyceum will REFUSE TO START. Re-run with --gen-token (or --token)." ;;
esac
STATE_DIR="${DATA_DIR:-$HOME/.seren-lyceum}"
cat > "$CFG_PATH" <<YAML
# SerenLyceum config - generated by seren-lyceum-setup.sh
# Full reference: see seren-lyceum.yaml.sample in the repo.
server:
  host: ${HOST}
  port: ${PORT}
  # Required once host is not loopback; empty = no auth (loopback only).
  bearer_token: "${TOKEN}"

storage:
  # Jobs (a folder each), datasets, and what was found in them.
  state_dir: '${STATE_DIR}'

local:
  # The training environment's interpreter. Empty = this box does not train.
  python: '${TRAIN_PY}'
  llama_cpp: '${LLAMA_CPP}'
  hf_home: '${HF_HOME_DIR}'
  label: "${LABEL}"
  max_parallel: 1
YAML
if [[ -n "$HIP_URL" ]]; then
  cat >> "$CFG_PATH" <<YAML

# The hippocampus whose lessons can be imported as a dataset.
hippocampus:
  url: ${HIP_URL}
${HIP_TOKEN_LINES}
YAML
fi
$UPDATES_OFF && cat >> "$CFG_PATH" <<'YAML'

# Update checking turned OFF at install time by --no-updates. It never
# upgrades anything; flip to true to have the info route say when one exists.
updates:
  enabled: false
YAML
[[ -n "$TOKEN" || -n "$HIP_TOKEN_LINES" ]] && chmod 600 "$CFG_PATH"
ok "Config written"

write_launcher "$APP_DIR" "seren-lyceum" "$VPY" "seren_lyceum" "$CFG_PATH"

# -- 8. optional autostart ----------------------------------------------------
$INSTALL_SERVICE && setup_autostart "$SCRIPT_DIR" "seren-lyceum" "$APP_DIR" "$TOKEN" "$SVC_SUFFIX" "$VENV_DIR" "$SERVICE_USER"

# -- done -------------------------------------------------------------------
echo
echo -e "${G}==========================================${NC}"
echo -e "${G}  SerenLyceum is set up ✓${NC}"
echo -e "${G}==========================================${NC}"
if ! $INSTALL_SERVICE; then
  echo -e "  Start it:        ${B}$APP_DIR/run-seren-lyceum.sh${NC}"
fi
echo -e "  Viewer:          ${B}http://${CONNECT_HOST}:${PORT}/viewer${NC}"
echo -e "  Health:          ${B}http://${CONNECT_HOST}:${PORT}/health${NC}"
[[ -n "$TOKEN" ]] && echo -e "  Bearer token:    ${Y}${TOKEN}${NC}"
[[ -n "$TRAIN_PY" ]] && echo -e "  Trains with:     ${B}${TRAIN_PY}${NC}"
echo
echo -e "  ${Y}We just train: you bring the data, you pick the model.${NC}"
echo -e "${G}Rip it and win. 🌭🔧${NC}"

seren_emit_done "$SVC_NAME" "$CONNECT_HOST" "$PORT" "$INSTALL_SERVICE" "${TOKEN:-}"
