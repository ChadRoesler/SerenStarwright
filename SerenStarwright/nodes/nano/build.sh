#!/bin/bash
# ══════════════════════════════════════════════════════════════
# nano/build.sh — Build artifacts from source (Nano, --build flag)
#
# Sourced by seren-prepare-node.sh when --build is passed. Same pattern as
# xavier/build.sh but skips python/sqlite (Nano gets those natively).
# ══════════════════════════════════════════════════════════════

PREBUILT_LLAMA_BIN="llama-server-orin-aarch64"
PREBUILT_TORCH_WHL="torch-${PYTORCH_VERSION}-cp310-cp310-linux_aarch64.whl"
PREBUILT_TVISION_WHL_LOCAL="torchvision-${TORCHVISION_VERSION}+fbb4cc5-cp310-cp310-linux_aarch64.whl"
PREBUILT_GASKET_KO="gasket-${JP_FAMILY}-${PLATFORM_TAG}-aarch64.ko"
PREBUILT_APEX_KO="apex-${JP_FAMILY}-${PLATFORM_TAG}-aarch64.ko"
PREBUILT_CORAL_MANIFEST="coral-${JP_FAMILY}-${PLATFORM_TAG}.manifest"

export PREBUILT_DIR="/home/$TARGET_USER/seren-prebuilts"

run_build_path() {
    sudo -u "$TARGET_USER" mkdir -p "$PREBUILT_DIR"
    cd "$PREBUILT_DIR"

    if [ ! -d repo ]; then
        log "Cloning prebuilts repo for source build..."
        sudo -u "$TARGET_USER" git clone "$PREBUILT_REPO" repo
    fi

    # Map service flags → build-prebuilts.sh flags
    local BUILD_FLAGS=()
    $INSTALL_LLAMA   && BUILD_FLAGS+=("--llama")
    if $INSTALL_COMFYUI; then
        BUILD_FLAGS+=("--pytorch" "--torchvision")
    fi
    $INSTALL_CORAL && BUILD_FLAGS+=("--coral")

    if [ ${#BUILD_FLAGS[@]} -eq 0 ]; then
        warn "No services need build artifacts — skipping build"
        return 0
    fi

    # Nano has 8GB unified — cap parallelism for pytorch builds
    if $INSTALL_COMFYUI; then
        log "Nano has 8GB unified memory — capping --max-jobs 2 for pytorch build"
        BUILD_FLAGS+=("--max-jobs" "2")
    fi

    log "Running build-prebuilts.sh ${BUILD_FLAGS[*]} — this takes hours."
    cd "$PREBUILT_DIR/repo"
    sudo -u "$TARGET_USER" bash ./build-prebuilts.sh "${BUILD_FLAGS[@]}"

    # Auto-discover and stage produced artifacts
    local PB_OUT
    if [ -d /mnt/nvme/prebuilt ]; then PB_OUT=/mnt/nvme/prebuilt
    else PB_OUT="/home/$TARGET_USER/prebuilt"; fi

    cd "$PREBUILT_DIR"

    if $INSTALL_LLAMA; then
        local FOUND_LLAMA
        FOUND_LLAMA=$(find "$PB_OUT" -maxdepth 1 -type f -name 'llama-server*orin*' | head -1 || true)
        if [ -n "$FOUND_LLAMA" ]; then
            cp -f "$FOUND_LLAMA" "$PREBUILT_DIR/$PREBUILT_LLAMA_BIN"
            chmod +x "$PREBUILT_DIR/$PREBUILT_LLAMA_BIN"
        else
            fail "Built llama-server not found in $PB_OUT"
            return 1
        fi
    fi

    if $INSTALL_COMFYUI; then
        local FOUND_TORCH FOUND_TVISION
        FOUND_TORCH=$(find "$PB_OUT" -maxdepth 1 -type f -name 'torch-*cp310*aarch64.whl' | head -1 || true)
        FOUND_TVISION=$(find "$PB_OUT" -maxdepth 1 -type f -name 'torchvision-*cp310*aarch64.whl' | head -1 || true)
        [ -n "$FOUND_TORCH" ]   && cp -f "$FOUND_TORCH"   "$PREBUILT_DIR/$PREBUILT_TORCH_WHL"
        [ -n "$FOUND_TVISION" ] && cp -f "$FOUND_TVISION" "$PREBUILT_DIR/$PREBUILT_TVISION_WHL_LOCAL"
    fi

    if $INSTALL_CORAL; then
        [ -f "$PB_OUT/$PREBUILT_GASKET_KO" ] && cp -f "$PB_OUT/$PREBUILT_GASKET_KO" "$PREBUILT_DIR/"
        [ -f "$PB_OUT/$PREBUILT_APEX_KO" ]   && cp -f "$PB_OUT/$PREBUILT_APEX_KO"   "$PREBUILT_DIR/"
        [ -f "$PB_OUT/$PREBUILT_CORAL_MANIFEST" ] && cp -f "$PB_OUT/$PREBUILT_CORAL_MANIFEST" "$PREBUILT_DIR/"
    fi

    chown -R "$TARGET_USER":"$TARGET_USER" "$PREBUILT_DIR"

    export STAGED_LLAMA_BIN="$PREBUILT_DIR/$PREBUILT_LLAMA_BIN"
    export STAGED_TORCH_WHL="$PREBUILT_DIR/$PREBUILT_TORCH_WHL"
    export STAGED_TVISION_WHL="$PREBUILT_DIR/$PREBUILT_TVISION_WHL_LOCAL"
    export STAGED_GASKET_KO="$PREBUILT_DIR/$PREBUILT_GASKET_KO"
    export STAGED_APEX_KO="$PREBUILT_DIR/$PREBUILT_APEX_KO"
    export STAGED_CORAL_MANIFEST="$PREBUILT_DIR/$PREBUILT_CORAL_MANIFEST"
}
