#!/bin/bash
# ══════════════════════════════════════════════════════════════
# xavier/kokoro.sh — Install Kokoro-FastAPI TTS (Xavier)
#
# Sourced by seren-prepare-node.sh. Defines install_kokoro().
#
# Uses a dedicated venv at ~/seren-venvs/kokoro (NVMe-backed). This
# isolates Kokoro's pinned dep stack from other services:
#   - huggingface_hub==0.23.5  (avoid hf-xet, no aarch64 wheel on jp5)
#   - transformers==4.45.2     (last version compatible with hub 0.23.5)
#   - numpy==1.26.1            (matches our PyTorch 2.1.0 ABI)
#
# Service phase — always re-runs when -k is flagged. Idempotent.
# Start with: ~/seren-venvs/kokoro/bin/python -m uvicorn ...
# ══════════════════════════════════════════════════════════════

install_kokoro() {
    local USER_HOME="/home/$TARGET_USER"
    cd "$USER_HOME"

    # ── Repo ──
    if [ ! -d Kokoro-FastAPI ]; then
        log "Cloning Kokoro-FastAPI..."
        sudo -u "$TARGET_USER" git clone https://github.com/remsky/Kokoro-FastAPI.git
    else
        log "Kokoro-FastAPI already cloned — pulling latest..."
        sudo -u "$TARGET_USER" git -C Kokoro-FastAPI pull --ff-only 2>/dev/null || \
            warn "git pull failed — local changes? leaving repo as-is"
    fi

    # ── Venv ──
    ensure_venv kokoro

    # ── Pinned core deps (see file header for the why) ──
    log "Installing Kokoro deps into venv..."
    venv_pip kokoro install \
        fastapi uvicorn soundfile scipy phonemizer \
        "huggingface_hub==0.23.5" \
        "transformers==4.45.2" \
        "numpy==1.26.1" \
        pydub inflect loguru kokoro

    # Project requirements (best-effort — main deps already pinned above)
    cd "$USER_HOME/Kokoro-FastAPI"
    if [ -f requirements.txt ]; then
        venv_pip kokoro install -r requirements.txt 2>/dev/null || \
            warn "Some requirements.txt entries failed — main deps already pinned, likely fine"
    fi

    # ── Voice models from HuggingFace ──
    if [ ! -d "src/models/v1_0" ] || [ -z "$(ls -A src/models/v1_0 2>/dev/null)" ]; then
        log "Downloading Kokoro voice models (~300MB)..."
        venv_python kokoro -c "
from huggingface_hub import snapshot_download
snapshot_download(repo_id='hexgrad/Kokoro-82M', local_dir='src/models/v1_0')
" || warn "Voice download failed — re-run manually later"
    else
        log "Voice models already present — skipping download"
    fi

    # ── Verify import in the venv ──
    venv_python kokoro -c "import kokoro; print('  kokoro module imports OK')" 2>&1 || \
        warn "kokoro import failed — check pip install above"

    log "Kokoro-FastAPI installed at $USER_HOME/Kokoro-FastAPI"
    log "Venv: ~/seren-venvs/kokoro"
    log "Start with: cd ~/Kokoro-FastAPI && ~/seren-venvs/kokoro/bin/python -m uvicorn src.main:app --host 0.0.0.0 --port 8880"
}
