#!/bin/bash
# ══════════════════════════════════════════════════════════════
# nano/prebuilts.sh — Download prebuilt Nano artifacts
#
# Sourced by seren-prepare-node.sh when not in --build mode. Same pattern as
# xavier/prebuilts.sh but with Nano-tagged filenames and jp6 PyTorch.
#
# No foundation prebuilts on Nano (Python/SQLite are native), so the
# foundation download function is a no-op.
# ══════════════════════════════════════════════════════════════

# Asset filenames in the release
PREBUILT_LLAMA_BIN="llama-server-orin-aarch64"
PREBUILT_TORCH_WHL="torch-${PYTORCH_VERSION}-cp310-cp310-linux_aarch64.whl"
# torchvision uses %2B in URL for "+" in commit hash version
PREBUILT_TVISION_WHL_URL="torchvision-${TORCHVISION_VERSION}%2Bfbb4cc5-cp310-cp310-linux_aarch64.whl"
PREBUILT_TVISION_WHL_LOCAL="torchvision-${TORCHVISION_VERSION}+fbb4cc5-cp310-cp310-linux_aarch64.whl"

# Coral kernel modules (only if --coral)
PREBUILT_GASKET_KO="gasket-${JP_FAMILY}-${PLATFORM_TAG}-aarch64.ko"
PREBUILT_APEX_KO="apex-${JP_FAMILY}-${PLATFORM_TAG}-aarch64.ko"
PREBUILT_CORAL_MANIFEST="coral-${JP_FAMILY}-${PLATFORM_TAG}.manifest"

# Where artifacts get staged
export PREBUILT_DIR="/home/$TARGET_USER/seren-prebuilts"

run_prebuilts_download_foundation() {
    # No-op on Nano — Python 3.10 and SQLite both ship via apt on Ubuntu 22.04
    info "Foundation prebuilts skipped on Nano (Python/SQLite are native)"
}

run_prebuilts_download_services() {
    sudo -u "$TARGET_USER" mkdir -p "$PREBUILT_DIR"
    cd "$PREBUILT_DIR"

    resolve_release_tag

    if $INSTALL_LLAMA && [ ! -f "$PREBUILT_LLAMA_BIN" ]; then
        log "Downloading prebuilt llama-server (orin)..."
        sudo -u "$TARGET_USER" wget -q --show-progress \
            "${PREBUILT_BASE}/${PREBUILT_LLAMA_BIN}"
        chmod +x "$PREBUILT_LLAMA_BIN"
    fi

    if $INSTALL_COMFYUI; then
        if [ ! -f "$PREBUILT_TORCH_WHL" ]; then
            log "Downloading prebuilt PyTorch ${PYTORCH_VERSION}..."
            sudo -u "$TARGET_USER" wget -q --show-progress \
                "${PREBUILT_BASE}/${PREBUILT_TORCH_WHL}"
        fi
        if [ ! -f "$PREBUILT_TVISION_WHL_LOCAL" ]; then
            log "Downloading prebuilt torchvision ${TORCHVISION_VERSION}..."
            sudo -u "$TARGET_USER" wget -q --show-progress \
                -O "$PREBUILT_TVISION_WHL_LOCAL" \
                "${PREBUILT_BASE}/${PREBUILT_TVISION_WHL_URL}"
        fi
    fi

    if $INSTALL_CORAL; then
        if [ ! -f "$PREBUILT_GASKET_KO" ]; then
            log "Downloading Coral gasket module (jp6/orin)..."
            sudo -u "$TARGET_USER" wget -q --show-progress \
                "${PREBUILT_BASE}/${PREBUILT_GASKET_KO}"
        fi
        if [ ! -f "$PREBUILT_APEX_KO" ]; then
            log "Downloading Coral apex module (jp6/orin)..."
            sudo -u "$TARGET_USER" wget -q --show-progress \
                "${PREBUILT_BASE}/${PREBUILT_APEX_KO}"
        fi
        sudo -u "$TARGET_USER" wget -q -O "$PREBUILT_CORAL_MANIFEST" \
            "${PREBUILT_BASE}/${PREBUILT_CORAL_MANIFEST}" 2>/dev/null || \
            warn "No Coral manifest in release — skipping kernel-version check"
    fi

    # Export staged paths
    export STAGED_LLAMA_BIN="$PREBUILT_DIR/$PREBUILT_LLAMA_BIN"
    export STAGED_TORCH_WHL="$PREBUILT_DIR/$PREBUILT_TORCH_WHL"
    export STAGED_TVISION_WHL="$PREBUILT_DIR/$PREBUILT_TVISION_WHL_LOCAL"
    export STAGED_GASKET_KO="$PREBUILT_DIR/$PREBUILT_GASKET_KO"
    export STAGED_APEX_KO="$PREBUILT_DIR/$PREBUILT_APEX_KO"
    export STAGED_CORAL_MANIFEST="$PREBUILT_DIR/$PREBUILT_CORAL_MANIFEST"
}

run_prebuilts_download() {
    run_prebuilts_download_foundation
    run_prebuilts_download_services
}
