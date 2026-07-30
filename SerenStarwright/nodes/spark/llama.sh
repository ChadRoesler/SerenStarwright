#!/bin/bash
# ══════════════════════════════════════════════════════════════
# spark/llama.sh — Install llama.cpp inference server (DGX Spark)
#
# Blackwell GB10 GPU — CUDA arch 120 (tentative, adjust per NVIDIA docs).
# Spark has 128GB unified memory — run with --parallel 2 or more,
# and cache types can be more generous than Jetson.
#
# The staged binary is Blackwell-tagged. LD_LIBRARY_PATH points to
# the JP7 CUDA path (no compat shim needed — JP7 ships matching driver).
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
        warn "Should include /usr/local/cuda/lib64 (set by foundation Phase 2)"
    fi

    if [ -d /mnt/nvme ]; then
        sudo -u "$TARGET_USER" mkdir -p /mnt/nvme/models
    fi

    # Generate a recommended launch config for the Spark
    sudo -u "$TARGET_USER" tee "$USER_HOME/start-llama-spark.sh" > /dev/null << 'STARTEOF'
#!/bin/bash
# start-llama-spark.sh — recommended launch for DGX Spark (128GB, Blackwell)
#
# Blackwell GB10 has ~96GB usable VRAM via unified memory. Run larger
# models (70B Q4, 120B Q3) with --parallel 2 for concurrent users.
#
# Adjust --ctx-size and --model path to match your actual model.
# ===================================================================
MODEL="${1:-/mnt/nvme/models/model.gguf}"
CTX_SIZE="${2:-32768}"
PARALLEL="${3:-2}"
PORT="${4:-8090}"

cd ~/llama.cpp/build/bin
export LD_LIBRARY_PATH=/usr/local/cuda/lib64:${LD_LIBRARY_PATH:-}

./llama-server \
  --model "$MODEL" \
  --ctx-size "$CTX_SIZE" \
  --parallel "$PARALLEL" \
  --port "$PORT" \
  --host 0.0.0.0 \
  --jinja \
  --cache-type-k q8_0 \
  --cache-type-v q8_0 \
  --n-gpu-layers 999
STARTEOF
    sudo -u "$TARGET_USER" chmod +x "$USER_HOME/start-llama-spark.sh"
    log "Spark launch script: ~/start-llama-spark.sh"
}
