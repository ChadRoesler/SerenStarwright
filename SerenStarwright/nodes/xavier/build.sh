#!/bin/bash
# ══════════════════════════════════════════════════════════════
# xavier/build.sh - Build artifacts from source (--build flag)
#
# Sourced by seren-prepare-node.sh when --build is passed. Clones the
# SerenSystemPrebuilts repo, runs build-jetson-prebuilts.sh with flags
# matching the requested services, and stages output the same way
# prebuilts.sh does (so service modules don't care which path ran).
#
# This takes HOURS. Use a tmux session.
# ══════════════════════════════════════════════════════════════

# Asset filenames - match what build-jetson-prebuilts.sh produces
PREBUILT_LLAMA_BIN="llama-server-xavier-aarch64"
PREBUILT_TORCH_WHL="torch-${PYTORCH_VERSION}-cp310-cp310-linux_aarch64.whl"
PREBUILT_TVISION_WHL_LOCAL="torchvision-${TORCHVISION_VERSION}+fbb4cc5-cp310-cp310-linux_aarch64.whl"
PREBUILT_GASKET_KO="gasket-${JP_FAMILY}-${PLATFORM_TAG}-aarch64.ko"
PREBUILT_APEX_KO="apex-${JP_FAMILY}-${PLATFORM_TAG}-aarch64.ko"
PREBUILT_CORAL_MANIFEST="coral-${JP_FAMILY}-${PLATFORM_TAG}.manifest"
PREBUILT_PYTHON_TARBALL="python3.10-jp5-xavier-aarch64.tar.gz"
PREBUILT_SQLITE_TARBALL="sqlite3.45-jp5-xavier-aarch64.tar.gz"

export PREBUILT_DIR="/home/$TARGET_USER/seren-prebuilts"

run_build_path() {
    sudo -u "$TARGET_USER" mkdir -p "$PREBUILT_DIR"
    cd "$PREBUILT_DIR"

    # Clone the prebuilts repo (default branch - build-jetson-prebuilts.sh lives at root
    # with its lib/ and phases/ beside it; the script refuses to run without them)
    if [ ! -d repo ]; then
        log "Cloning prebuilts repo for source build..."
        sudo -u "$TARGET_USER" git clone "$PREBUILT_REPO" repo
    fi

    # Map service flags → build-jetson-prebuilts.sh flags
    # Only build the artifacts services actually need.
    local BUILD_FLAGS=()
    $INSTALL_LLAMA   && BUILD_FLAGS+=("--llama")
    if $INSTALL_COMFYUI; then
        BUILD_FLAGS+=("--pytorch" "--torchvision")
    fi
    $INSTALL_CORAL && BUILD_FLAGS+=("--coral")

    if [ ${#BUILD_FLAGS[@]} -eq 0 ]; then
        warn "No services need build artifacts - skipping build"
        return 0
    fi

    log "Running build-jetson-prebuilts.sh ${BUILD_FLAGS[*]} - this takes hours."
    log "Tail $LOG_FILE in another terminal to watch progress."
    cd "$PREBUILT_DIR/repo"
    sudo -u "$TARGET_USER" bash ./build-jetson-prebuilts.sh "${BUILD_FLAGS[@]}"

    # Auto-discover produced artifacts and stage them in $PREBUILT_DIR
    # (build-jetson-prebuilts.sh writes to /mnt/nvme/prebuilt by default)
    # The builder writes into a PER-PLATFORM folder now: <output>/xavier-${JP_FAMILY}/.
    local PB_OUT
    if [ -d /mnt/nvme/prebuilt ]; then PB_OUT=/mnt/nvme/prebuilt
    else PB_OUT="/home/$TARGET_USER/prebuilt"; fi
    [ -d "$PB_OUT/xavier-${JP_FAMILY}" ] && PB_OUT="$PB_OUT/xavier-${JP_FAMILY}"

    cd "$PREBUILT_DIR"

    if $INSTALL_LLAMA; then
        local FOUND_LLAMA
        FOUND_LLAMA=$(find "$PB_OUT" -maxdepth 1 -type f -name 'llama-server*xavier*' | head -1 || true)
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
        # UNDER THEIR OWN NAMES. A wheel copied to a hardcoded filename fails
        # pip's name/metadata check the moment the built version or the
        # torchvision local tag differs from the guess (it did: +fbb4cc5 is the
        # Xavier's commit and this file used it for every platform).
        [ -n "$FOUND_TORCH" ]   && cp -f "$FOUND_TORCH"   "$PREBUILT_DIR/" && PREBUILT_TORCH_WHL="$(basename "$FOUND_TORCH")"
        [ -n "$FOUND_TVISION" ] && cp -f "$FOUND_TVISION" "$PREBUILT_DIR/" && PREBUILT_TVISION_WHL_LOCAL="$(basename "$FOUND_TVISION")"
    fi

    if $INSTALL_CORAL; then
        [ -f "$PB_OUT/$PREBUILT_GASKET_KO" ] && cp -f "$PB_OUT/$PREBUILT_GASKET_KO" "$PREBUILT_DIR/"
        [ -f "$PB_OUT/$PREBUILT_APEX_KO" ]   && cp -f "$PB_OUT/$PREBUILT_APEX_KO"   "$PREBUILT_DIR/"
        [ -f "$PB_OUT/$PREBUILT_CORAL_MANIFEST" ] && cp -f "$PB_OUT/$PREBUILT_CORAL_MANIFEST" "$PREBUILT_DIR/"
    fi

    chown -R "$TARGET_USER":"$TARGET_USER" "$PREBUILT_DIR"

    # Export staged paths for service modules (same shape as prebuilts.sh)
    export STAGED_LLAMA_BIN="$PREBUILT_DIR/$PREBUILT_LLAMA_BIN"
    export STAGED_TORCH_WHL="$PREBUILT_DIR/$PREBUILT_TORCH_WHL"
    export STAGED_TVISION_WHL="$PREBUILT_DIR/$PREBUILT_TVISION_WHL_LOCAL"
    export STAGED_GASKET_KO="$PREBUILT_DIR/$PREBUILT_GASKET_KO"
    export STAGED_APEX_KO="$PREBUILT_DIR/$PREBUILT_APEX_KO"
    export STAGED_CORAL_MANIFEST="$PREBUILT_DIR/$PREBUILT_CORAL_MANIFEST"
}
