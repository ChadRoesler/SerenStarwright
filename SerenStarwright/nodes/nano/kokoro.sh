#!/bin/bash
# ══════════════════════════════════════════════════════════════
# nano/kokoro.sh — Install Kokoro-FastAPI TTS (Nano)
#
# Same pattern as xavier/kokoro.sh but Nano can use a more permissive
# dep set since Ubuntu 22.04 + cp310 builds hf-xet cleanly:
#   - huggingface_hub: latest (no hf-xet build problem)
#   - transformers:    latest (no version pinning needed)
#   - numpy<2:         still pinned to match jp6 PyTorch 2.3.1 ABI
#
# PEP 668 doesn't apply inside venvs — no --break-system-packages needed.
# ══════════════════════════════════════════════════════════════

install_kokoro() {
    local USER_HOME="/home/$TARGET_USER"
    cd "$USER_HOME"

    if [ ! -d Kokoro-FastAPI ]; then
        log "Cloning Kokoro-FastAPI..."
        sudo -u "$TARGET_USER" git clone https://github.com/remsky/Kokoro-FastAPI.git
    else
        log "Kokoro-FastAPI already cloned — pulling latest..."
        sudo -u "$TARGET_USER" git -C Kokoro-FastAPI pull --ff-only 2>/dev/null || \
            warn "git pull failed — local changes? leaving repo as-is"
    fi

    ensure_venv kokoro

    log "Installing Kokoro deps into venv..."
    venv_pip kokoro install \
        fastapi uvicorn soundfile scipy phonemizer \
        huggingface_hub transformers \
        "numpy<2" \
        pydub inflect loguru kokoro

    cd "$USER_HOME/Kokoro-FastAPI"
    if [ -f requirements.txt ]; then
        venv_pip kokoro install -r requirements.txt 2>/dev/null || \
            warn "Some requirements.txt entries failed — main deps already installed"
    fi

    if [ ! -d "src/models/v1_0" ] || [ -z "$(ls -A src/models/v1_0 2>/dev/null)" ]; then
        log "Downloading Kokoro voice models (~300MB)..."
        venv_python kokoro -c "
from huggingface_hub import snapshot_download
snapshot_download(repo_id='hexgrad/Kokoro-82M', local_dir='src/models/v1_0')
" || warn "Voice download failed — re-run manually later"
    else
        log "Voice models already present — skipping download"
    fi

    venv_python kokoro -c "import kokoro; print('  kokoro module imports OK')" 2>&1 || \
        warn "kokoro import failed — check pip install above"

    log "Kokoro-FastAPI installed at $USER_HOME/Kokoro-FastAPI"
    log "Venv: ~/seren-venvs/kokoro"
    log "Start with: cd ~/Kokoro-FastAPI && ~/seren-venvs/kokoro/bin/python -m uvicorn src.main:app --host 0.0.0.0 --port 8880"
}
