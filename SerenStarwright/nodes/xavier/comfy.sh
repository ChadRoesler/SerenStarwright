#!/bin/bash
# ══════════════════════════════════════════════════════════════
# xavier/comfy.sh - Install ComfyUI + PyTorch (Xavier)
#
# Sourced by seren-prepare-node.sh. Defines install_comfy().
#
# Uses a dedicated venv at ~/seren-venvs/comfy. ComfyUI custom nodes
# pull in wildly varying dep stacks - isolating them is critical.
#
# PyTorch 2.1.0 + torchvision 0.16.0 (cp310, arch 72) installed from
# the prebuilt wheels staged by prebuilts.sh or build.sh.
#
# ComfyUI is PINNED here (COMFY_REF, default v0.3.65): 2.1 is JetPack 5's
# last torch, and ComfyUI after v0.3.65 calls torch.compiler.is_compiling
# (torch 2.3), after v0.7.0 needs comfy-kitchen (torch 2.4). Latest never
# started on this box (found 14 Oct 2026, zero starts since the 4 Oct
# prep). v0.3.65 draws SDXL (Pony, Illustrious) and SD 1.5 - and the
# manifest says so (families), so Lodestar sends the rest elsewhere.
#
# Service phase - always re-runs when -c is flagged. Idempotent.
# Start with: cd $APPS_ROOT/ComfyUI && ~/seren-venvs/comfy/bin/python main.py --listen 0.0.0.0
# ══════════════════════════════════════════════════════════════

install_comfy() {
    local USER_HOME="/home/$TARGET_USER"

    # ── Venv ──
    ensure_venv comfy

    # ── PyTorch ──
    if [ -n "${STAGED_TORCH_WHL:-}" ] && [ -f "$STAGED_TORCH_WHL" ]; then
        log "Installing prebuilt PyTorch ${PYTORCH_VERSION} (cp310, arch ${CUDA_ARCH}) into venv..."
        venv_pip comfy install "$STAGED_TORCH_WHL"
    else
        warn "Prebuilt PyTorch wheel missing - falling back to NVIDIA jp512 index"
        venv_pip comfy install torch \
            --extra-index-url https://developer.download.nvidia.com/compute/redist/jp/v512/ || \
            warn "PyTorch install failed; ComfyUI will run CPU-only"
    fi

    # ── torchvision ──
    if [ -n "${STAGED_TVISION_WHL:-}" ] && [ -f "$STAGED_TVISION_WHL" ]; then
        log "Installing prebuilt torchvision ${TORCHVISION_VERSION}..."
        venv_pip comfy install "$STAGED_TVISION_WHL"
    else
        warn "torchvision wheel missing - image models that need it may fail to load"
    fi

    # ── ComfyUI repo ──
    local APPS_ROOT; APPS_ROOT="$(seren_apps_root)"
    seren_note_home_copy ComfyUI
    cd "$APPS_ROOT"
    local REF="${COMFY_REF:-v0.3.65}"
    if [ ! -d ComfyUI ]; then
        log "Cloning ComfyUI..."
        sudo -u "$TARGET_USER" git clone https://github.com/comfyanonymous/ComfyUI.git
    else
        sudo -u "$TARGET_USER" git -C ComfyUI fetch --tags -q 2>/dev/null || warn "git fetch failed - using the tags already here"
    fi
    log "ComfyUI at $REF (the last that runs on torch 2.1)..."
    sudo -u "$TARGET_USER" git -C ComfyUI checkout -q "$REF" || \
        warn "could not check out $REF - local changes? leaving the repo as it is"

    cd ComfyUI
    log "Installing ComfyUI Python deps into venv..."
    venv_pip comfy install -r requirements.txt 2>/dev/null || \
        warn "Some ComfyUI requirements failed - usually safe to ignore (optional deps)"

    # numpy BELOW 2, after the requirements, on this platform only. The Xavier's
    # torch is 2.1.0, built against numpy 1.x; ComfyUI's requirements pull numpy
    # 2.x, and then torch cannot hand a tensor to numpy ("Failed to initialize
    # NumPy: _ARRAY_API not found") - which is every image ComfyUI saves.
    venv_pip comfy install "numpy<2" || warn "could not pin numpy<2 - torch 2.1.0 and numpy 2.x do not work together"
    # A later ComfyUI's requirements leave comfy-kitchen behind, and it fails
    # on import under torch 2.1 rather than being skipped.
    venv_pip comfy uninstall -y comfy-kitchen >/dev/null 2>&1 || true

    # The model store (/mnt/nvme/comfyui-models) is made and wired by
    # seren_register_comfy, below.

    # ── Verify CUDA in venv ──
    log "Verifying PyTorch CUDA in venv..."
    venv_python_cuda comfy -c "
import torch
print(f'  PyTorch: {torch.__version__}')
print(f'  CUDA available: {torch.cuda.is_available()}')
if torch.cuda.is_available():
    print(f'  Device: {torch.cuda.get_device_name(0)}')
" 2>&1 || warn "PyTorch import failed in venv - check LD_LIBRARY_PATH"

    COMFY_FAMILIES="${COMFY_FAMILIES:-sdxl,sd15}" seren_register_comfy || return 1

    log "ComfyUI installed at $APPS_ROOT/ComfyUI"
    log "Venv: ~/seren-venvs/comfy"
    log "Start with: cd $APPS_ROOT/ComfyUI && ~/seren-venvs/comfy/bin/python main.py --listen 0.0.0.0"
}
