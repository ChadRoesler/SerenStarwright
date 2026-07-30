#!/bin/bash
# ══════════════════════════════════════════════════════════════
# nano/llama.sh — Install llama.cpp inference server (Nano)
#
# Same pattern as xavier/llama.sh — copies the staged binary into
# ~/llama.cpp/build/bin/. Only difference is the binary is the
# orin-tagged variant (arch 87) and runtime LD_LIBRARY_PATH points
# to CUDA 12.6 instead of 12.2.
# ══════════════════════════════════════════════════════════════

install_llama() {
    local USER_HOME="/home/$TARGET_USER"
    local LLAMA_DIR="$USER_HOME/llama.cpp"
    local BIN_DIR="$LLAMA_DIR/build/bin"

    if [ -z "${STAGED_LLAMA_BIN:-}" ] || [ ! -f "$STAGED_LLAMA_BIN" ]; then
        fail "Staged llama-server binary missing. Prebuilts/build phase didn't run or failed."
        fail "Expected at: ${STAGED_LLAMA_BIN:-<unset>}"
        return 1
    fi

    sudo -u "$TARGET_USER" mkdir -p "$BIN_DIR"
    sudo -u "$TARGET_USER" cp -f "$STAGED_LLAMA_BIN" "$BIN_DIR/llama-server"
    chmod +x "$BIN_DIR/llama-server"

    log "llama-server installed at $BIN_DIR/llama-server"
    if "$BIN_DIR/llama-server" --version 2>&1 | head -3; then
        log "llama-server reports version OK"
    else
        warn "Could not invoke --version. Check LD_LIBRARY_PATH at runtime."
        warn "Should include /usr/local/cuda-12.6/lib64 (set by foundation Phase 2)"
    fi

    if [ -d /mnt/nvme ]; then
        sudo -u "$TARGET_USER" mkdir -p /mnt/nvme/models
    fi
}
