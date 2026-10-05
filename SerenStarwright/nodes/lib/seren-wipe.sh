#!/bin/bash
# ══════════════════════════════════════════════════════════════
# seren-wipe.sh - Reset a node back to pre-seren state
#
# Removes everything seren-prepare-node.sh installs:
#   - All venvs at /mnt/nvme/seren-venvs/* and ~/seren-venvs/*
#   - Service repos and binaries: ~/Kokoro-FastAPI, ~/ComfyUI, ~/llama.cpp,
#     ~/whisper.cpp
#   - The node services' start/stop scripts (~/start_{whisper,llama,kokoro}.sh
#     and the stop_ twins), ~/seren-llama.env, and their manifests in
#     ~/.seren/services, so the Observatory stops listing what cannot start
#   - Staged prebuilts: ~/seren-prebuilts/
#   - User pip packages on NVMe: /mnt/nvme/pip-packages/, /mnt/nvme/pip-cache/
#   - Persistence dirs: ~/seren-memory/, ~/seren-logs/
#   - Phase tracker: ~/.seren/node-state.json (and the legacy
#     .seren-setup.state.json, for a node prepped before it moved), and the
#     node manifest ~/.seren/node.json, which the next prep writes again
#
# Optionally (with --models):
#   - Models and build output: ~/models or /mnt/nvme/models (the llama ggufs,
#     the whisper ggml files), /mnt/nvme/comfyui-models, and the Ms.MoE run
#     root (/mnt/nvme/msMoEMaker or ~/msMoEMaker). Kept by default: they are
#     tens of gigabytes and slow to fetch, and the installers skip a model that
#     is already there, so a re-prep after a plain wipe is quick.
#
# Optionally (with --deep):
#   - Removes /usr/local/bin/python3.10 + /usr/local/lib/python3.10
#   - Removes /usr/local/{bin,lib,include,share}/sqlite3 stuff (Xavier only)
#   - Removes seren-max-power.service systemd unit
#   - Removes /etc/sudoers.d/seren and /usr/local/sbin/seren-systemctl
#   - Removes hostname customization (resets to localhost)
#
# Does NOT touch:
#   - /etc/extlinux/extlinux.conf (Coral kernel cmdline modifications)
#   - /etc/modprobe.d/coral-blacklist.conf
#   - /lib/modules/$(uname -r)/.../{gasket,apex}.ko
#   - The NVMe partition itself or its mount config
#   - Kernel, JetPack, system Python, system SQLite
#
# Usage:
#   bash seren-wipe.sh                    # interactive, asks before doing anything
#   bash seren-wipe.sh --dry-run          # show what would be removed, do nothing
#   bash seren-wipe.sh --yes              # skip confirmation prompt (CAREFUL)
#   bash seren-wipe.sh --deep             # ALSO remove python/sqlite/sudoers/etc
#   bash seren-wipe.sh --models           # ALSO remove models and build output
#   bash seren-wipe.sh --deep --yes       # full reset, no prompts
#   bash seren-wipe.sh -u youruser          # specify target user (default: invoking user)
# ══════════════════════════════════════════════════════════════

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
log()  { echo -e "${GREEN}[WIPE]${NC} $1"; }
warn() { echo -e "${YELLOW}[WIPE]${NC} $1"; }
fail() { echo -e "${RED}[WIPE]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[WIPE]${NC} $1"; }

# ─────────────────────────────────────────────────────────────
# Flags
# ─────────────────────────────────────────────────────────────
TARGET_USER="${SUDO_USER:-${USER:-$(id -un)}}"
DRY_RUN=false
ASSUME_YES=false
DEEP=false
MODELS=false

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  -u, --user USER   Target user (default: invoking user)
      --dry-run     Show what would be removed without doing it
  -y, --yes         Skip confirmation prompt (use with care)
      --deep        Also remove python3.10, sqlite3.45, systemd unit,
                    sudoers, and reset hostname. Slower to recover from
                    (foundation rebuilds these from prebuilts/source).
      --models      Also remove models and build output (llama/whisper
                    models, ComfyUI models, the Ms.MoE run root). Kept by
                    default: big, slow to fetch, and reused by a re-prep.
  -h, --help        Show this help

Examples:
  $0                       # interactive shallow wipe
  $0 --dry-run             # see what would happen
  $0 --deep --yes          # nuke it all, no prompts
  $0 -u youruser --deep      # nuke for a different user
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -u|--user)   TARGET_USER="$2"; shift 2 ;;
        --dry-run)   DRY_RUN=true; shift ;;
        -y|--yes)    ASSUME_YES=true; shift ;;
        --deep)      DEEP=true; shift ;;
        --models)    MODELS=true; shift ;;
        -h|--help)   usage; exit 0 ;;
        *)           fail "Unknown option: $1" ;;
    esac
done

if ! id "$TARGET_USER" &>/dev/null; then
    fail "User '$TARGET_USER' does not exist"
fi

USER_HOME="/home/$TARGET_USER"
[ "$TARGET_USER" = "root" ] && USER_HOME="/root"
# Tests point both roots at a scratch folder (the SEREN_TEST_HOME convention
# common.sh uses), so a test run can never reach a real home or NVMe.
[ -n "${SEREN_TEST_HOME:-}" ] && USER_HOME="$SEREN_TEST_HOME"
NVME="${SEREN_TEST_NVME:-/mnt/nvme}"
# Where node prep put the components: the root a run named with --install-root
# (remembered in the node state), else the NVMe. Read with grep, not jq - a
# wipe has to work on a box where jq is one of the things already gone.
APPS_ROOT="$(grep -o '"_install_root"[[:space:]]*:[[:space:]]*"[^"]*"' "$USER_HOME/.seren/node-state.json" 2>/dev/null | head -1 | sed 's/.*:[[:space:]]*"//; s/"$//')"
[ -n "$APPS_ROOT" ] || APPS_ROOT="$NVME"

# ─────────────────────────────────────────────────────────────
# Build the target list - what we'd remove
# ─────────────────────────────────────────────────────────────
SHALLOW_TARGETS=(
    # Venvs (NVMe-backed + home symlinks)
    "$NVME/seren-venvs"
    "$USER_HOME/seren-venvs"

    # Staged prebuilts
    "$USER_HOME/seren-prebuilts"

    # Service repos
    "$USER_HOME/Kokoro-FastAPI"
    "$USER_HOME/ComfyUI"
    "$USER_HOME/llama.cpp"
    "$USER_HOME/whisper.cpp"
    # ...and under the install root, which is the NVMe unless --install-root
    # said otherwise (APPS_ROOT, read from the node state above).
    "$APPS_ROOT/Kokoro-FastAPI"
    "$APPS_ROOT/ComfyUI"
    "$APPS_ROOT/llama.cpp"
    "$APPS_ROOT/whisper.cpp"

    # The node services (whisper, llama, Kokoro): their start/stop scripts, the
    # llama env file, and the manifests the Observatory lists them from. Left
    # behind, a wiped node keeps listing services that cannot start. Named, not
    # globbed: ~/.seren/services also holds manifests other installers wrote.
    "$USER_HOME/start_whisper.sh"
    "$USER_HOME/stop_whisper.sh"
    "$USER_HOME/start_llama.sh"
    "$USER_HOME/stop_llama.sh"
    "$USER_HOME/start_kokoro.sh"
    "$USER_HOME/stop_kokoro.sh"
    "$USER_HOME/seren-llama.env"
    "$USER_HOME/.seren/services/whisper.json"
    "$USER_HOME/.seren/services/llama.json"
    "$USER_HOME/.seren/services/kokoro.json"
    "$USER_HOME/.seren/node.json"

    # User pip packages on NVMe (the .local symlinks point here)
    "$NVME/pip-packages"
    "$NVME/pip-cache"

    # Persistence dirs
    "$USER_HOME/seren-memory"
    "$USER_HOME/seren-logs"

    # Coral test helper
    "$USER_HOME/test-coral.sh"
)

# Phase tracker + log files.
#
# THE TRACKER MUST GO, and it has a fixed home now. Phase state moved from a file
# beside the script to ~/.seren/node-state.json precisely so it would survive a
# re-clone - which means a wipe that misses it leaves the node claiming to be
# prepared, and the next seren-prepare-node.sh run skips every foundation phase
# on a box that no longer has a foundation. Named explicitly rather than left to
# the find below, because "node-state.json" is a generic enough filename that
# matching it anywhere under a home directory could hit something unrelated.
# Models and build output (--models). Both the NVMe and the home spelling:
# the installers pick whichever exists, and a node may have moved between them.
MODEL_TARGETS=(
    "$USER_HOME/models"
    "$NVME/models"
    "$NVME/comfyui-models"
    "$USER_HOME/msMoEMaker"
    "$NVME/msMoEMaker"
)

STATE_FILES=()
[ -f "$USER_HOME/.seren/node-state.json" ] && STATE_FILES+=("$USER_HOME/.seren/node-state.json")

# The legacy per-checkout tracker and the logs are still discovered dynamically,
# since a checkout can live anywhere (~/setup, ~/seren-v5, /opt/seren, wherever).
while IFS= read -r f; do
    [ -n "$f" ] && STATE_FILES+=("$f")
done < <(
    find "$USER_HOME" -maxdepth 4 -type f \
        \( -name '.seren-setup.state.json' -o -name 'seren-setup.log' \) \
        2>/dev/null
)

DEEP_TARGETS=(
    # System Python 3.10 from tarball/source
    "/usr/local/bin/python3.10"
    "/usr/local/bin/python3.10-config"
    "/usr/local/bin/pip3.10"
    "/usr/local/bin/pydoc3.10"
    "/usr/local/bin/idle3.10"
    "/usr/local/bin/2to3-3.10"
    "/usr/local/lib/python3.10"
    "/usr/local/include/python3.10"
    "/usr/local/share/man/man1/python3.10.1"

    # System SQLite 3.45 from tarball/source (Xavier-only path)
    "/usr/local/bin/sqlite3"
    "/usr/local/lib/libsqlite3.so"
    "/usr/local/lib/libsqlite3.so.0"
    "/usr/local/lib/libsqlite3.so.0.8.6"
    "/usr/local/lib/libsqlite3.la"
    "/usr/local/lib/libsqlite3.a"
    "/usr/local/lib/pkgconfig/sqlite3.pc"
    "/usr/local/include/sqlite3.h"
    "/usr/local/include/sqlite3ext.h"
    "/usr/local/share/man/man1/sqlite3.1"
)

# ~/.local is a symlink (created by foundation phase 6) - wipe contents not the symlink
LOCAL_DIRS=(
    "$USER_HOME/.local/lib/python3.10"
    "$USER_HOME/.local/bin"
)

# ─────────────────────────────────────────────────────────────
# Show what we'd do
# ─────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}══════════════════════════════════════════${NC}"
echo -e "${GREEN}  Seren Wipe - preview${NC}"
echo -e "${GREEN}══════════════════════════════════════════${NC}"
echo ""
log "Target user:   $TARGET_USER"
log "Mode:          $($DEEP && echo 'DEEP (system-level)' || echo 'shallow (services + venvs)')"
log "Models:        $($MODELS && echo 'REMOVE (--models)' || echo 'kept')"
log "Dry run:       $DRY_RUN"
echo ""

print_target() {
    local path="$1"
    if [ -e "$path" ] || [ -L "$path" ]; then
        local size=""
        if [ -d "$path" ] && [ ! -L "$path" ]; then
            size=" ($(du -sh "$path" 2>/dev/null | cut -f1 || echo '?'))"
        fi
        echo -e "  ${YELLOW}✗${NC} $path$size"
    else
        echo -e "  ${BLUE}·${NC} $path (not present, skip)"
    fi
}

echo "Service-level removals (always):"
for t in "${SHALLOW_TARGETS[@]}"; do print_target "$t"; done
echo ""

echo "Phase tracker + logs (discovered):"
if [ ${#STATE_FILES[@]} -eq 0 ]; then
    echo -e "  ${BLUE}·${NC} (no state files found anywhere under $USER_HOME)"
else
    for t in "${STATE_FILES[@]}"; do print_target "$t"; done
fi
echo ""

echo "User-local pip leftovers (always):"
for t in "${LOCAL_DIRS[@]}"; do print_target "$t"; done
echo ""

if $MODELS; then
    echo "Models and build output (--models):"
    for t in "${MODEL_TARGETS[@]}"; do print_target "$t"; done
    echo ""
fi

if $DEEP; then
    echo "System-level removals (--deep):"
    for t in "${DEEP_TARGETS[@]}"; do print_target "$t"; done
    echo ""
    echo "Other --deep actions:"
    if [ -f /etc/systemd/system/seren-max-power.service ]; then
        echo -e "  ${YELLOW}✗${NC} disable + remove /etc/systemd/system/seren-max-power.service"
    fi
    if [ -f /etc/sudoers.d/seren ]; then
        echo -e "  ${YELLOW}✗${NC} remove /etc/sudoers.d/seren"
    fi
    if command -v hostname >/dev/null && [ "$(hostname)" != "localhost" ]; then
        echo -e "  ${YELLOW}✗${NC} reset hostname from '$(hostname)' to 'localhost'"
    fi
    echo ""
fi

echo "Will NOT touch:"
if ! $MODELS; then
    for t in "${MODEL_TARGETS[@]}"; do
        [ -e "$t" ] && echo -e "  ${BLUE}·${NC} $t (models and build output; --models removes them)"
    done
fi
echo -e "  ${BLUE}·${NC} extlinux.conf kernel cmdline (Coral cmdline args left in place)"
echo -e "  ${BLUE}·${NC} /etc/modprobe.d/coral-blacklist.conf"
echo -e "  ${BLUE}·${NC} /lib/modules/$(uname -r)/.../gasket.ko, apex.ko"
echo -e "  ${BLUE}·${NC} NVMe partition / mount / fstab entry"
echo -e "  ${BLUE}·${NC} NVMe swap file (/mnt/nvme/16GB.swap)"
echo -e "  ${BLUE}·${NC} system Python (apt-managed), system SQLite (apt-managed)"
echo -e "  ${BLUE}·${NC} JetPack, kernel, CUDA toolkit"
echo ""

if $DRY_RUN; then
    log "Dry run - exiting without removing anything."
    exit 0
fi

# ─────────────────────────────────────────────────────────────
# Confirm
# ─────────────────────────────────────────────────────────────
if ! $ASSUME_YES; then
    echo -ne "${RED}Proceed with wipe?${NC} Type 'yes' to continue: "
    read -r REPLY
    if [ "$REPLY" != "yes" ]; then
        log "Aborted."
        exit 0
    fi
fi

# ─────────────────────────────────────────────────────────────
# Execute
# ─────────────────────────────────────────────────────────────
echo ""
log "Executing wipe..."

remove_path() {
    local path="$1"
    if [ -e "$path" ] || [ -L "$path" ]; then
        sudo rm -rf "$path"
        log "removed: $path"
    fi
}

# Shallow removals
for t in "${SHALLOW_TARGETS[@]}"; do remove_path "$t"; done

# Phase tracker + logs (discovered earlier)
for t in "${STATE_FILES[@]}"; do remove_path "$t"; done

# User-local pip leftovers - careful with the .local/bin symlink itself
for t in "${LOCAL_DIRS[@]}"; do
    if [ -L "$t" ]; then
        # It's a symlink to NVMe - kill the symlink, the target is already gone
        sudo rm -f "$t"
        log "removed symlink: $t"
    else
        remove_path "$t"
    fi
done
# Also wipe the .cache/pip symlink
if [ -L "$USER_HOME/.cache/pip" ]; then
    sudo rm -f "$USER_HOME/.cache/pip"
    log "removed symlink: $USER_HOME/.cache/pip"
fi

# Models (--models)
if $MODELS; then
    for t in "${MODEL_TARGETS[@]}"; do remove_path "$t"; done
fi

# Deep removals
if $DEEP; then
    for t in "${DEEP_TARGETS[@]}"; do remove_path "$t"; done
    sudo ldconfig 2>/dev/null || true

    # systemd unit
    if [ -f /etc/systemd/system/seren-max-power.service ]; then
        sudo systemctl disable --now seren-max-power.service 2>/dev/null || true
        sudo rm -f /etc/systemd/system/seren-max-power.service
        sudo systemctl daemon-reload
        log "removed: seren-max-power.service"
    fi

    # sudoers, and the helper it names
    if [ -f /etc/sudoers.d/seren ]; then
        sudo rm -f /etc/sudoers.d/seren
        log "removed: /etc/sudoers.d/seren"
    fi
    if [ -f /usr/local/sbin/seren-systemctl ]; then
        sudo rm -f /usr/local/sbin/seren-systemctl
        log "removed: /usr/local/sbin/seren-systemctl"
    fi

    # hostname
    if command -v hostnamectl >/dev/null && [ "$(hostname)" != "localhost" ]; then
        sudo hostnamectl set-hostname localhost
        log "hostname reset to localhost"
    fi
fi

echo ""
echo -e "${GREEN}══════════════════════════════════════════${NC}"
echo -e "${GREEN}  Wipe Complete${NC}"
echo -e "${GREEN}══════════════════════════════════════════${NC}"
echo ""
log "You can now re-run: bash seren-prepare-node.sh -l -k -d -u $TARGET_USER"
echo ""
