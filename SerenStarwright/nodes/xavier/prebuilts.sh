#!/bin/bash
# ══════════════════════════════════════════════════════════════
# xavier/prebuilts.sh — Download prebuilt Xavier artifacts
#
# Sourced by seren-prepare-node.sh when not in --build mode.
# Resolves release tag via API (or pinned via --tag), downloads
# the artifacts that the requested services actually need.
#
# Stages all artifacts under $PREBUILT_DIR for service modules
# to consume.
# ══════════════════════════════════════════════════════════════

# Asset filenames in the release
PREBUILT_LLAMA_BIN="llama-server-xavier-aarch64"
PREBUILT_TORCH_WHL="torch-${PYTORCH_VERSION}-cp310-cp310-linux_aarch64.whl"
# torchvision uses %2B in URL for the "+" in commit hash version
PREBUILT_TVISION_WHL_URL="torchvision-${TORCHVISION_VERSION}%2Bfbb4cc5-cp310-cp310-linux_aarch64.whl"
PREBUILT_TVISION_WHL_LOCAL="torchvision-${TORCHVISION_VERSION}+fbb4cc5-cp310-cp310-linux_aarch64.whl"

# Foundation prebuilts (Xavier-only — Nano has these via JetPack 6 / native apt)
PREBUILT_PYTHON_TARBALL="python3.10-jp5-xavier-aarch64.tar.gz"
PREBUILT_SQLITE_TARBALL="sqlite3.45-jp5-xavier-aarch64.tar.gz"

# Coral kernel modules (only if --coral)
PREBUILT_GASKET_KO="gasket-${JP_FAMILY}-${PLATFORM_TAG}-aarch64.ko"
PREBUILT_APEX_KO="apex-${JP_FAMILY}-${PLATFORM_TAG}-aarch64.ko"
PREBUILT_CORAL_MANIFEST="coral-${JP_FAMILY}-${PLATFORM_TAG}.manifest"

# Where artifacts get staged for service modules to pick up
export PREBUILT_DIR="/home/$TARGET_USER/seren-prebuilts"

run_prebuilts_download_foundation() {
    sudo -u "$TARGET_USER" mkdir -p "$PREBUILT_DIR"
    cd "$PREBUILT_DIR"

    resolve_release_tag

    # Foundation tarballs — Xavier-only, downloaded BEFORE foundation runs.
    # Best-effort: if not in release, foundation falls back to source.
    if [ ! -f "$PREBUILT_PYTHON_TARBALL" ]; then
        log "Downloading prebuilt Python 3.10 tarball..."
        if sudo -u "$TARGET_USER" wget -q --show-progress \
            "${PREBUILT_BASE}/${PREBUILT_PYTHON_TARBALL}" 2>/dev/null; then
            log "Python tarball staged"
        else
            warn "Python tarball not in release — foundation will source-build (~30 min)"
            rm -f "$PREBUILT_PYTHON_TARBALL"
        fi
    fi

    # SQLite tarball is always downloaded on Xavier — see foundation.sh
    # comment for the rpath rationale. Best-effort: foundation falls back
    # to source build if missing from release.
    if [ ! -f "$PREBUILT_SQLITE_TARBALL" ]; then
        log "Downloading prebuilt SQLite 3.45 tarball..."
        if sudo -u "$TARGET_USER" wget -q --show-progress \
            "${PREBUILT_BASE}/${PREBUILT_SQLITE_TARBALL}" 2>/dev/null; then
            log "SQLite tarball staged"
        else
            warn "SQLite tarball not in release — foundation will source-build (~10 min)"
            rm -f "$PREBUILT_SQLITE_TARBALL"
        fi
    fi

    # Export staged paths — foundation phases read these
    if [ -f "$PREBUILT_DIR/$PREBUILT_PYTHON_TARBALL" ]; then
        export STAGED_PYTHON_TARBALL="$PREBUILT_DIR/$PREBUILT_PYTHON_TARBALL"
    fi
    if [ -f "$PREBUILT_DIR/$PREBUILT_SQLITE_TARBALL" ]; then
        export STAGED_SQLITE_TARBALL="$PREBUILT_DIR/$PREBUILT_SQLITE_TARBALL"
    fi
}

run_prebuilts_download_services() {
    sudo -u "$TARGET_USER" mkdir -p "$PREBUILT_DIR"
    cd "$PREBUILT_DIR"

    resolve_release_tag

    # llama-server binary — only fetch if llama is requested
    if $INSTALL_LLAMA && [ ! -f "$PREBUILT_LLAMA_BIN" ]; then
        log "Downloading prebuilt llama-server..."
        sudo -u "$TARGET_USER" wget -q --show-progress \
            "${PREBUILT_BASE}/${PREBUILT_LLAMA_BIN}"
        chmod +x "$PREBUILT_LLAMA_BIN"
    fi

    # PyTorch + torchvision wheels — only if ComfyUI is requested
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

    # Coral kernel modules — only if --coral
    if $INSTALL_CORAL; then
        if [ ! -f "$PREBUILT_GASKET_KO" ]; then
            log "Downloading Coral gasket module..."
            sudo -u "$TARGET_USER" wget -q --show-progress \
                "${PREBUILT_BASE}/${PREBUILT_GASKET_KO}"
        fi
        if [ ! -f "$PREBUILT_APEX_KO" ]; then
            log "Downloading Coral apex module..."
            sudo -u "$TARGET_USER" wget -q --show-progress \
                "${PREBUILT_BASE}/${PREBUILT_APEX_KO}"
        fi
        sudo -u "$TARGET_USER" wget -q -O "$PREBUILT_CORAL_MANIFEST" \
            "${PREBUILT_BASE}/${PREBUILT_CORAL_MANIFEST}" 2>/dev/null || \
            warn "No Coral manifest in release — skipping kernel-version check"
    fi

    # Export staged paths — service modules read these
    export STAGED_LLAMA_BIN="$PREBUILT_DIR/$PREBUILT_LLAMA_BIN"
    export STAGED_TORCH_WHL="$PREBUILT_DIR/$PREBUILT_TORCH_WHL"
    export STAGED_TVISION_WHL="$PREBUILT_DIR/$PREBUILT_TVISION_WHL_LOCAL"
    export STAGED_GASKET_KO="$PREBUILT_DIR/$PREBUILT_GASKET_KO"
    export STAGED_APEX_KO="$PREBUILT_DIR/$PREBUILT_APEX_KO"
    export STAGED_CORAL_MANIFEST="$PREBUILT_DIR/$PREBUILT_CORAL_MANIFEST"
}

# Backward-compat wrapper — runs both
run_prebuilts_download() {
    run_prebuilts_download_foundation
    run_prebuilts_download_services
}
