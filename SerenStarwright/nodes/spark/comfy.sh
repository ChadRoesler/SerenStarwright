#!/bin/bash
# ══════════════════════════════════════════════════════════════
# spark/comfy.sh - Install ComfyUI + PyTorch (DGX Spark)
#
# Spark has 128GB unified memory and Blackwell GB10. No --lowvram
# needed - full models fit comfortably. PyTorch uses JP7-native CUDA
# builds (Blackwell arch). No numpy pinning - JP7 PyTorch 3.x uses
# numpy 2.x ABI natively.
#
# PyTorch is the OFFICIAL cu130 aarch64 wheel (SPARK_TORCH, default
# torch==2.13.0 torchvision==0.28.0 from download.pytorch.org/whl/cu130):
# built for sm_80..sm_120, it runs the GB10 (sm_121) correctly. The staged
# source build (STAGED_TORCH_WHL, built for sm_121 only) computed attention
# WRONG on every path - Krea 2 drew colour noise and the log filled with
# "fmha_cutlassF... is for sm80-sm100, but was built for sm121" (found 15 Oct
# 2026). It is only tried with SPARK_TORCH_STAGED=1, and whichever torch
# goes in has to pass an attention check before ComfyUI is registered.
# ══════════════════════════════════════════════════════════════

SPARK_TORCH_INDEX="${SPARK_TORCH_INDEX:-https://download.pytorch.org/whl/cu130}"
SPARK_TORCH="${SPARK_TORCH:-torch==2.13.0 torchvision==0.28.0}"

# Scaled-dot-product attention on the GPU against a float64 answer worked
# out on the CPU, through every backend torch has here. A torch that gets it
# wrong turns every prompt into noise, so it is not a warning.
_spark_attention_ok() {
    venv_python_cuda comfy -W ignore -c "
import torch, torch.nn.functional as F
from torch.nn.attention import sdpa_kernel, SDPBackend
q = torch.randn(1, 8, 256, 64, dtype=torch.float64)
ref = F.scaled_dot_product_attention(q, q, q)
bad = []
for name, be in (('math', SDPBackend.MATH), ('efficient', SDPBackend.EFFICIENT_ATTENTION),
                 ('flash', SDPBackend.FLASH_ATTENTION), ('cudnn', SDPBackend.CUDNN_ATTENTION)):
    x = q.to('cuda', torch.bfloat16)
    try:
        with sdpa_kernel(be):
            out = F.scaled_dot_product_attention(x, x, x)
        torch.cuda.synchronize()
    except RuntimeError:
        continue                                  # not built here: torch picks another
    err = (out.double().cpu() - ref).abs().max().item()
    print(f'  attention {name}: max error {err:.4f}')
    if not err < 0.05:
        bad.append(name)
raise SystemExit(f'  attention WRONG on: {bad}' if bad else 0)
" 2>&1 | grep -v "^FATAL: kernel" | head -8
    return "${PIPESTATUS[0]}"
}

install_comfy() {
    local USER_HOME="/home/$TARGET_USER"

    ensure_venv comfy

    # ── PyTorch + torchvision ──
    if [ "${SPARK_TORCH_STAGED:-0}" = "1" ] && [ -n "${STAGED_TORCH_WHL:-}" ] && [ -f "$STAGED_TORCH_WHL" ]; then
        log "Installing the staged PyTorch build (SPARK_TORCH_STAGED=1)..."
        venv_pip comfy install "$STAGED_TORCH_WHL"
        [ -n "${STAGED_TVISION_WHL:-}" ] && [ -f "$STAGED_TVISION_WHL" ] && venv_pip comfy install "$STAGED_TVISION_WHL"
    else
        log "Installing PyTorch ($SPARK_TORCH) from $SPARK_TORCH_INDEX..."
        # shellcheck disable=SC2086 # SPARK_TORCH is a list of specs
        venv_pip comfy install --upgrade $SPARK_TORCH --index-url "$SPARK_TORCH_INDEX" || \
            { warn "PyTorch install failed from $SPARK_TORCH_INDEX"; return 1; }
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
    # torch is already in, from the right index: requirements must not swap it
    # for PyPI's (no GPU build there for aarch64 + CUDA 13).
    venv_pip comfy install -r requirements.txt --extra-index-url "$SPARK_TORCH_INDEX" 2>/dev/null || \
        warn "Some ComfyUI requirements failed - usually safe to ignore"

    # The model store (/mnt/nvme/comfyui-models) is made and wired by
    # seren_register_comfy, below.

    log "Verifying PyTorch CUDA in venv..."
    venv_python_cuda comfy -c "
import torch
print(f'  PyTorch: {torch.__version__}')
print(f'  CUDA available: {torch.cuda.is_available()}')
if torch.cuda.is_available():
    print(f'  Device: {torch.cuda.get_device_name(0)}')
    print(f'  VRAM: {torch.cuda.get_device_properties(0).total_memory / 1024**3:.1f} GB')
" 2>&1 || warn "PyTorch import failed in venv - check LD_LIBRARY_PATH"

    log "Checking the GPU computes attention right..."
    if ! _spark_attention_ok; then
        warn "this torch computes attention WRONG on the GB10: every picture would be noise."
        warn "Not registering ComfyUI. Reinstall without SPARK_TORCH_STAGED, or set SPARK_TORCH /"
        warn "SPARK_TORCH_INDEX to a build that passes."
        return 1
    fi

    seren_register_comfy || return 1

    log "ComfyUI installed at $APPS_ROOT/ComfyUI"
    log "Venv: ~/seren-venvs/comfy"
    log "Start with: cd $APPS_ROOT/ComfyUI && ~/seren-venvs/comfy/bin/python main.py --listen 0.0.0.0"
    log "(No --lowvram needed - Spark has 128GB unified memory)"
}
