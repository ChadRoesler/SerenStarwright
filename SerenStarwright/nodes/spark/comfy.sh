#!/bin/bash
# ══════════════════════════════════════════════════════════════
# spark/comfy.sh - Install ComfyUI + PyTorch (DGX Spark)
#
# Spark has 128GB unified memory and Blackwell GB10. No --lowvram
# needed - full models fit comfortably. PyTorch uses JP7-native CUDA
# builds (Blackwell arch). No numpy pinning - JP7 PyTorch 3.x uses
# numpy 2.x ABI natively.
#
# If prebuilt wheels exist for Blackwell, use them; otherwise fall
# back to NVIDIA JP7 redist or pip.
# ══════════════════════════════════════════════════════════════

install_comfy() {
    local USER_HOME="/home/$TARGET_USER"

    ensure_venv comfy

    # ── PyTorch ──
    if [ -n "${STAGED_TORCH_WHL:-}" ] && [ -f "$STAGED_TORCH_WHL" ]; then
        log "Installing prebuilt PyTorch (Blackwell) into venv..."
        venv_pip comfy install "$STAGED_TORCH_WHL"
    else
        warn "Prebuilt PyTorch wheel missing - falling back to NVIDIA JP7 redist"
        venv_pip comfy install torch \
            --extra-index-url https://developer.download.nvidia.com/compute/redist/jp/v70/ || \
            warn "PyTorch install failed; ComfyUI will run CPU-only"
    fi

    # ── torchvision ──
    if [ -n "${STAGED_TVISION_WHL:-}" ] && [ -f "$STAGED_TVISION_WHL" ]; then
        log "Installing prebuilt torchvision..."
        venv_pip comfy install "$STAGED_TVISION_WHL"
    else
        warn "torchvision wheel missing - will use JP7 redist"
        venv_pip comfy install torchvision \
            --extra-index-url https://developer.download.nvidia.com/compute/redist/jp/v70/ 2>/dev/null || \
            warn "torchvision install failed - may affect some models"
    fi

    # ── ComfyUI repo ──
    local APPS_ROOT; APPS_ROOT="$(seren_apps_root)"
    seren_note_home_copy ComfyUI
    cd "$APPS_ROOT"
    if [ ! -d ComfyUI ]; then
        log "Cloning ComfyUI..."
        sudo -u "$TARGET_USER" git clone https://github.com/comfyanonymous/ComfyUI.git
    else
        log "ComfyUI already cloned - pulling latest..."
        sudo -u "$TARGET_USER" git -C ComfyUI pull --ff-only 2>/dev/null || \
            warn "git pull failed - local changes? leaving repo as-is"
    fi

    cd ComfyUI
    log "Installing ComfyUI Python deps into venv..."
    venv_pip comfy install -r requirements.txt 2>/dev/null || \
        warn "Some ComfyUI requirements failed - usually safe to ignore"

    if [ -d /mnt/nvme ]; then
        sudo -u "$TARGET_USER" mkdir -p /mnt/nvme/comfyui-models
    fi

    log "Verifying PyTorch CUDA in venv..."
    venv_python_cuda comfy -c "
import torch
print(f'  PyTorch: {torch.__version__}')
print(f'  CUDA available: {torch.cuda.is_available()}')
if torch.cuda.is_available():
    print(f'  Device: {torch.cuda.get_device_name(0)}')
    print(f'  VRAM: {torch.cuda.get_device_properties(0).total_memory / 1024**3:.1f} GB')
" 2>&1 || warn "PyTorch import failed in venv - check LD_LIBRARY_PATH"

    seren_register_comfy || return 1

    log "ComfyUI installed at $APPS_ROOT/ComfyUI"
    log "Venv: ~/seren-venvs/comfy"
    log "Start with: cd $APPS_ROOT/ComfyUI && ~/seren-venvs/comfy/bin/python main.py --listen 0.0.0.0"
    log "(No --lowvram needed - Spark has 128GB unified memory)"
}
