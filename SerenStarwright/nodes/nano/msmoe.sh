#!/bin/bash
# ══════════════════════════════════════════════════════════════
# nano/msmoe.sh - Install Ms.MoE Maker (nano)
#
# Sourced by seren-prepare-node.sh. Defines install_msmoe().
#
# WHY THIS IS A NODE COMPONENT AND NOT A seren-*-setup.sh SERVICE.
# ms-moe-maker is a CLI you run, not a daemon that listens - no port, no
# host to bind, nothing to autostart. It went into services/ first and
# fought that shape the whole way: a port of 0, a meaningless done-event
# URL, and a verifier rule that had to be inverted to accept it.
#
# But the real argument is torch. The [train] extra wants torch, and on a
# Jetson you cannot simply let pip fetch one - you get a wheel with no CUDA
# and a builder that silently runs on the CPU. Staging the right wheel per
# platform is exactly what this side of Starwright already does for ComfyUI,
# so this is a sibling of comfy.sh and nothing new had to be invented.
#
# Nano: JetPack 6, CUDA 12.6, cp310, arch 87. 8GB unified memory is tight for training - the consolidator-sized models are the realistic target here, not a 7B.
#
# Own venv at ~/seren-venvs/msmoe (ensure_venv moves it to NVMe when there
# is one), so the training stack cannot clobber another component's pins.
#
# Service phase - always re-runs when flagged. Idempotent.
# ══════════════════════════════════════════════════════════════

install_msmoe() {
    local USER_HOME="/home/$TARGET_USER"

    ensure_venv msmoe

    # ── PyTorch, BEFORE ms-moe-maker ──
    # Order is the whole trick. `[train]` only asks for torch>=2.0, so a
    # CUDA wheel already in the venv satisfies it and pip leaves it alone.
    # Install ms-moe-maker first and pip resolves torch itself - from PyPI,
    # without CUDA, on a box whose only purpose is CUDA.
    if [ -n "${STAGED_TORCH_WHL:-}" ] && [ -f "$STAGED_TORCH_WHL" ]; then
        log "Installing prebuilt PyTorch ${PYTORCH_VERSION:-} into venv..."
        venv_pip msmoe install "$STAGED_TORCH_WHL"
    else
        warn "Prebuilt PyTorch wheel missing - falling back to the NVIDIA redist"
        venv_pip msmoe install torch \
            --extra-index-url https://developer.download.nvidia.com/compute/redist/jp/v60/ || \
            warn "PyTorch install failed; builds will not run (validate still will)"
    fi

    # ── Ms.MoE Maker ──
    # The [train] extra is the point on a build box: torch, transformers,
    # datasets, safetensors, accelerate, peft, trl, bitsandbytes, optuna.
    #
    # NOT fatal if it partially fails, and that is deliberate rather than
    # lazy: bitsandbytes has no aarch64 wheel for every version, so on a
    # Jetson it is the one most likely to need a source build. A failure
    # there should leave you with a working `validate` and a loud warning,
    # not a dead node-prep run. The verify block below says what landed.
    log "Installing ms-moe-maker[train] into venv..."
    venv_pip msmoe install "ms-moe-maker[train]" || \
        warn "Some [train] deps failed - see the check below for what is usable"

    # ── Verify, and be specific about it ──
    # A CPU-only torch is the failure this whole module exists to prevent, so
    # it gets asserted out loud rather than assumed from a successful pip.
    log "Verifying the build stack in the venv..."
    venv_python msmoe -c "
import importlib
try:
    import torch
    print(f'  PyTorch: {torch.__version__}')
    print(f'  CUDA available: {torch.cuda.is_available()}')
    if torch.cuda.is_available():
        print(f'  Device: {torch.cuda.get_device_name(0)}')
    else:
        print('  !! torch has no CUDA - this box cannot train. Check the wheel.')
except Exception as e:
    print(f'  !! torch unusable: {e}')
for mod in ('transformers', 'datasets', 'safetensors', 'accelerate',
            'peft', 'trl', 'bitsandbytes'):
    try:
        importlib.import_module(mod)
        print(f'  ok   {mod}')
    except Exception as e:
        print(f'  MISSING {mod} - {type(e).__name__}')
" 2>&1 || warn "Verification could not run - check the venv"

    # The CLI is what Theatre forks, so prove it answers before saying done.
    if venv_python msmoe -m ms_moe_maker --describe >/dev/null 2>&1; then
        log "ms-moe-maker --describe answers"
    else
        warn "ms-moe-maker is installed but --describe did not answer"
    fi

    # ── Where the work goes ──
    # Recipes and run directories, off eMMC when there is an NVMe. The runs
    # are the 45GB half; a 32GB eMMC cannot hold one.
    if [ -d /mnt/nvme ]; then
        sudo -u "$TARGET_USER" mkdir -p /mnt/nvme/msMoEMaker
        log "Run root: /mnt/nvme/msMoEMaker"
    else
        sudo -u "$TARGET_USER" mkdir -p "$USER_HOME/msMoEMaker"
        warn "No /mnt/nvme - run root is $USER_HOME/msMoEMaker. A full build"
        warn "writes tens of gigabytes; put it on real storage before a gauntlet."
    fi

    local venv_path; venv_path="$(_seren_venv_path msmoe)"
    log "Ms.MoE Maker installed. Venv: $venv_path"
    log "  Check a recipe:  $venv_path/bin/ms-moe-maker validate recipe.yaml"
    log "  Build:           $venv_path/bin/ms-moe-maker build recipe.yaml --json"
    # NOT written into any config from here. Which install Theatre forks is
    # Theatre's business, and a node-prep script reaching into another
    # service's yaml is how two things start disagreeing about one fact.
    log "  For SerenTheatre, set   pipeline:\n    venv: $venv_path"
}
