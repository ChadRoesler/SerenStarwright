#!/bin/bash
# ══════════════════════════════════════════════════════════════
# xavier/llama.sh — Install llama.cpp inference server (Xavier)
#
# Sourced by seren-prepare-node.sh. Defines install_llama() which copies
# the staged llama-server binary into ~/llama.cpp/build/bin/.
#
# Expects $STAGED_LLAMA_BIN set by prebuilts.sh or build.sh.
# Service phases ALWAYS run when explicitly flagged (no phase tracking)
# so re-running just re-stages the binary, which is the right behavior.
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

    # Verify it loads — needs LD_LIBRARY_PATH from cuda phase
    log "llama-server installed at $BIN_DIR/llama-server"
    if "$BIN_DIR/llama-server" --version 2>&1 | head -3; then
        log "llama-server reports version OK"
    else
        warn "Could not invoke --version. Check LD_LIBRARY_PATH at runtime."
        warn "Should include /usr/local/cuda-12.2/compat (set by foundation Phase 5)"
    fi

    # Drop a models dir on NVMe
    if [ -d /mnt/nvme ]; then
        sudo -u "$TARGET_USER" mkdir -p /mnt/nvme/models
    fi
}
