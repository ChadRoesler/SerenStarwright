#!/bin/bash
# ══════════════════════════════════════════════════════════════
# nano/comfy.sh — Install ComfyUI + PyTorch (Nano)
#
# Uses a venv at ~/seren-venvs/comfy. PyTorch 2.3.1 + torchvision
# 0.18.1 from prebuilt jp6 wheels (cp310, arch 87).
#
# WARNING: ComfyUI on 8GB unified memory is very tight. Recommended
# only on Orin Nano Super (8GB) — base 4GB Nano cannot run meaningful
# image gen models.
# ══════════════════════════════════════════════════════════════

install_comfy() {
    local USER_HOME="/home/$TARGET_USER"

    ensure_venv comfy

    # ── PyTorch ──
    if [ -n "${STAGED_TORCH_WHL:-}" ] && [ -f "$STAGED_TORCH_WHL" ]; then
        log "Installing prebuilt PyTorch ${PYTORCH_VERSION} (cp310, arch ${CUDA_ARCH}) into venv..."
        venv_pip comfy install "$STAGED_TORCH_WHL"
    else
        warn "Prebuilt PyTorch wheel missing — falling back to NVIDIA jp6 redist"
        venv_pip comfy install torch \
            --extra-index-url https://developer.download.nvidia.com/compute/redist/jp/v60/ || \
            warn "PyTorch install failed; ComfyUI will run CPU-only"
    fi

    # ── torchvision ──
    if [ -n "${STAGED_TVISION_WHL:-}" ] && [ -f "$STAGED_TVISION_WHL" ]; then
        log "Installing prebuilt torchvision ${TORCHVISION_VERSION}..."
        venv_pip comfy install "$STAGED_TVISION_WHL"
    else
        warn "torchvision wheel missing — image models that need it may fail to load"
    fi

    # ── ComfyUI repo ──
    cd "$USER_HOME"
    if [ ! -d ComfyUI ]; then
        log "Cloning ComfyUI..."
        sudo -u "$TARGET_USER" git clone https://github.com/comfyanonymous/ComfyUI.git
    else
        log "ComfyUI already cloned — pulling latest..."
        sudo -u "$TARGET_USER" git -C ComfyUI pull --ff-only 2>/dev/null || \
            warn "git pull failed — local changes? leaving repo as-is"
    fi

    cd ComfyUI
    log "Installing ComfyUI Python deps into venv..."
    venv_pip comfy install -r requirements.txt 2>/dev/null || \
        warn "Some ComfyUI requirements failed — usually safe to ignore"

    if [ -d /mnt/nvme ]; then
        sudo -u "$TARGET_USER" mkdir -p /mnt/nvme/comfyui-models
    fi

    log "Verifying PyTorch CUDA in venv..."
    venv_python comfy -c "
import torch
print(f'  PyTorch: {torch.__version__}')
print(f'  CUDA available: {torch.cuda.is_available()}')
if torch.cuda.is_available():
    print(f'  Device: {torch.cuda.get_device_name(0)}')
" 2>&1 || warn "PyTorch import failed in venv — check LD_LIBRARY_PATH"

    log "ComfyUI installed at $USER_HOME/ComfyUI"
    log "Venv: ~/seren-venvs/comfy"
    log "Start with: cd ~/ComfyUI && ~/seren-venvs/comfy/bin/python main.py --listen 0.0.0.0 --lowvram"
    log "(--lowvram is recommended on 8GB Nano)"
}
