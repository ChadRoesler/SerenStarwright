#!/bin/bash
# ══════════════════════════════════════════════════════════════
# seren-prepare-node.sh — Unified Seren node preparation
#
# Dispatcher script. Detects platform (Xavier / Orin Nano / DGX Spark),
# parses flags, does preflight + sudoers + hostname, then sources the
# appropriate platform module to run prereq + service phases.
#
# NOT Jetson-only. The Spark is not a Tegra part and doesn't have nvpmodel,
# jetson_clocks or a JetPack; anything that says "Jetson" below is talking
# about the Jetson platforms specifically, not about nodes in general.
#
# Modular layout:
#   seren-prepare-node.sh    ← you are here
#   common.sh                ← shared helpers
#   xavier/foundation.sh     ← Xavier OS prereqs
#   xavier/{llama,kokoro,chroma,comfy,coral}.sh
#   xavier/{prebuilts,build}.sh
#   nano/   (same structure)
#   spark/  (same structure, no build path - prebuilts only)
#
# Usage:
#   bash seren-prepare-node.sh [SERVICE FLAGS] [OPTIONS]
#
# Service flags:
#   -l, --llama       Install llama.cpp inference server
#   -k, --kokoro      Install Kokoro-FastAPI TTS
#   -c, --comfyui     Install ComfyUI image generation
#   -d, --chromadb    Install ChromaDB vector store
#       --coral       Install Coral M.2 TPU support (off by default; needs hardware)
#       --all         Install llama + kokoro + comfyui + chromadb (NOT coral)
#
# Options:
#   -u, --user USER       Target user (default: invoking user)
#   -H, --hostname NAME   Hostname (default: auto-derived from services)
#       --build           Build artifacts from source instead of downloading prebuilts
#       --tag TAG         Pin to specific release tag (e.g. 2026.04.29-xavier)
#   -h, --help            Show this help
#
# Examples:
#   # Xavier 32GB primary node — llama + kokoro + chroma
#   bash seren-prepare-node.sh -l -k -d
#
#   # Xavier 16GB specialist — comfy only
#   bash seren-prepare-node.sh -c
#
#   # Nano edge — everything plus Coral TPU
#   bash seren-prepare-node.sh --all --coral
#
#   # Pin to a specific release
#   bash seren-prepare-node.sh -l -k -d --tag 2026.04.29-xavier
# ══════════════════════════════════════════════════════════════

set -e

# Resolve script's own location so platform modules can be sourced regardless
# of where the user invokes from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared helpers (provides log/warn/fail/info/run_phase/run_service/etc)
#
# lib/ since the move into SerenStarwright. Kept tolerant of the old
# alongside-me location too, because a node somewhere is running a copy from
# before the reorg and "FATAL: common.sh not found" is a rotten thing to hand
# someone whose only crime is not having pulled.
COMMON_SH=""
for cand in "$SCRIPT_DIR/lib/common.sh" "$SCRIPT_DIR/common.sh"; do
    [ -f "$cand" ] && { COMMON_SH="$cand"; break; }
done
if [ -z "$COMMON_SH" ]; then
    echo "FATAL: common.sh not found."
    echo "Looked in: $SCRIPT_DIR/lib/common.sh"
    echo "           $SCRIPT_DIR/common.sh"
    exit 1
fi
# shellcheck disable=SC1091
source "$COMMON_SH"

# Tee'd output: detail to log file, summary to console (FD 3)
exec 3>&1 4>&2

# ─────────────────────────────────────────────────────────────
# Flag defaults & parsing
# ─────────────────────────────────────────────────────────────
TARGET_USER="${SUDO_USER:-${USER:-$(id -un)}}"
TARGET_HOSTNAME=""
USE_BUILD_FLAG=false
USER_PREBUILT_TAG=""
SKIP_MAX_POWER=false

INSTALL_LLAMA=false
INSTALL_KOKORO=false
INSTALL_COMFYUI=false
INSTALL_CHROMADB=false
INSTALL_CORAL=false

usage() {
    cat <<EOF
Usage: $0 [SERVICE FLAGS] [OPTIONS]

Service flags (combine freely):
  -l, --llama       Install llama.cpp inference server
  -k, --kokoro      Install Kokoro-FastAPI TTS
  -c, --comfyui     Install ComfyUI image generation
  -d, --chromadb    Install ChromaDB vector store
      --coral       Install Coral M.2 TPU support
      --all         Install llama + kokoro + comfyui + chromadb (NOT coral)

Options:
  -u, --user USER       Target user (default: invoking user)
  -H, --hostname NAME   Hostname (default: auto-derived from services)
      --build           Build artifacts from source (slow; default is download)
      --tag TAG         Pin to specific release tag
      --no-max-power    Skip MAXN power mode + jetson_clocks (default: ON).
                        Jetson platforms only — a node without nvpmodel skips
                        this phase anyway. Use on passively-cooled or
                        battery-powered Jetsons.
  -h, --help            Show this help

Examples:
  Primary node:        $0 -l -k -d
  Specialist node:     $0 -c
  Edge node + TPU:     $0 --all --coral
  Pinned release:      $0 -l -k -d --tag 2026.04.29-xavier
  Fanless / battery:   $0 -l -k --no-max-power
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -l|--llama)    INSTALL_LLAMA=true; shift ;;
        -k|--kokoro)   INSTALL_KOKORO=true; shift ;;
        -c|--comfyui)  INSTALL_COMFYUI=true; shift ;;
        -d|--chromadb) INSTALL_CHROMADB=true; shift ;;
        --coral)       INSTALL_CORAL=true; shift ;;
        --all)         INSTALL_LLAMA=true; INSTALL_KOKORO=true
                       INSTALL_COMFYUI=true; INSTALL_CHROMADB=true; shift ;;
        -u|--user)     TARGET_USER="$2"; shift 2 ;;
        -H|--hostname) TARGET_HOSTNAME="$2"; shift 2 ;;
        --build)       USE_BUILD_FLAG=true; shift ;;
        --tag)         USER_PREBUILT_TAG="$2"; shift 2 ;;
        # Overrides detection entirely. Needed for the DGX Spark, whose
        # auto-detection is written from spec rather than from a tested
        # machine - and useful on anything new enough to fool the heuristics.
        --platform)    export SEREN_PLATFORM="$2"; shift 2 ;;
        --no-max-power) SKIP_MAX_POWER=true; shift ;;
        # Starwright contracts. --events points at a JSON Lines file the caller
        # tails; --describe reports this node's shape and exits without doing
        # anything. See seren_event in lib/common.sh for why events go to a
        # file here rather than to stdout like the service installers.
        --events)      export SEREN_EVENTS_FILE="$2"; shift 2 ;;
        --describe)    DO_DESCRIBE=true; shift ;;
        -h|--help)     usage; exit 0 ;;
        *)             echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
done

# --describe: answer and exit, ZERO side effects. Must come before the
# "at least one service" check below - describing a node is not installing on
# it, and requiring -l just to ask what's available would be absurd.
if ${DO_DESCRIBE:-false}; then
    seren_describe_node
    exit 0
fi

# At least one service must be requested
if ! $INSTALL_LLAMA && ! $INSTALL_KOKORO && ! $INSTALL_COMFYUI \
   && ! $INSTALL_CHROMADB && ! $INSTALL_CORAL; then
    echo "ERROR: No service flag given. Pick at least one of -l/-k/-c/-d/--coral or --all." >&2
    usage
    exit 1
fi

# Validate user
if ! id "$TARGET_USER" &>/dev/null; then
    echo "ERROR: User '$TARGET_USER' does not exist" >&2
    exit 1
fi

# ─────────────────────────────────────────────────────────────
# Preflight: platform detection + structural checks
# ─────────────────────────────────────────────────────────────
detect_platform || exit 1

# Verify the platform module tree exists
PLATFORM_DIR="$SCRIPT_DIR/$PLATFORM"
if [ ! -d "$PLATFORM_DIR" ]; then
    fail "Platform directory missing: $PLATFORM_DIR"
    fail "Did you extract the full node-prep tree (nodes/ with its platform dirs)?"
    exit 1
fi

if [ ! -f "$PLATFORM_DIR/foundation.sh" ]; then
    fail "Foundation module missing: $PLATFORM_DIR/foundation.sh"
    exit 1
fi

# Auto-derive hostname if not provided
if [ -z "$TARGET_HOSTNAME" ]; then
    parts=()
    $INSTALL_LLAMA    && parts+=("llama")
    $INSTALL_KOKORO   && parts+=("kokoro")
    $INSTALL_COMFYUI  && parts+=("comfy")
    $INSTALL_CHROMADB && parts+=("chroma")
    $INSTALL_CORAL    && parts+=("coral")
    TARGET_HOSTNAME="${PLATFORM}-$(IFS=-; echo "${parts[*]}")"
fi

# Set up logging
LOG_FILE="$SCRIPT_DIR/seren-setup.log"
STATE_FILE="$SCRIPT_DIR/.seren-setup.state.json"
export LOG_FILE STATE_FILE SKIP_MAX_POWER

# Banner before redirecting stdout
echo ""
echo -e "${GREEN}══════════════════════════════════════════${NC}"
echo -e "${GREEN}  Seren Setup — ${PLATFORM} (${JP_FAMILY})${NC}"
echo -e "${GREEN}══════════════════════════════════════════${NC}"
echo ""
echo -e "${GREEN}[SEREN]${NC} Detailed output → $LOG_FILE"
echo -e "${GREEN}[SEREN]${NC} Phase state    → $STATE_FILE"
echo ""

: > "$LOG_FILE"
exec >> "$LOG_FILE" 2>&1

log "Platform:        $PLATFORM ($JP_FAMILY, kernel $KERNEL_VER)"
log "Target user:     $TARGET_USER"
log "Target hostname: $TARGET_HOSTNAME"
log "Build mode:      $($USE_BUILD_FLAG && echo 'BUILD FROM SOURCE' || echo 'prebuilt download')"
log "Max power:       $($SKIP_MAX_POWER && echo 'SKIPPED (--no-max-power)' || echo 'ON (MAXN + jetson_clocks)')"
log "Services:        llama=$INSTALL_LLAMA kokoro=$INSTALL_KOKORO comfy=$INSTALL_COMFYUI chroma=$INSTALL_CHROMADB coral=$INSTALL_CORAL"

# Initialize state file
ensure_jq
[ -f "$STATE_FILE" ] || echo '{}' > "$STATE_FILE"

# ─────────────────────────────────────────────────────────────
# Bad-combo warnings (warn, don't block)
# ─────────────────────────────────────────────────────────────
if [ "$PLATFORM" = "nano" ] && $INSTALL_COMFYUI; then
    warn "ComfyUI on Orin Nano (8GB unified) is very memory-tight."
    warn "Recommended: run ComfyUI on a Xavier 16GB specialist node instead."
    warn "Continuing anyway — your call."
fi

if [ "$PLATFORM" = "xavier" ] && $INSTALL_CORAL; then
    info "Coral on Xavier is supported but uncommon — most Coral builds run on Orin Nano."
    info "Make sure your kernel matches the prebuilt module manifest."
fi

# ─────────────────────────────────────────────────────────────
# Base box setup — sudoers + hostname (always run)
# ─────────────────────────────────────────────────────────────
# These run BEFORE the platform module so the foundation phases have a
# consistent environment to build on.

phase_sudoers() {
    sudo tee /etc/sudoers.d/seren > /dev/null << SUDOERS
# Seren stack — passwordless sudo for inference operations
# Generated by seren-prepare-node.sh for user: $TARGET_USER
# Validate: sudo visudo -cf /etc/sudoers.d/seren

# Memory reclaim
$TARGET_USER ALL=(root) NOPASSWD: /usr/bin/tee /proc/sys/vm/drop_caches
$TARGET_USER ALL=(root) NOPASSWD: /usr/bin/tee /proc/sys/vm/compact_memory

# Systemd service control
$TARGET_USER ALL=(root) NOPASSWD: /bin/systemctl daemon-reload
$TARGET_USER ALL=(root) NOPASSWD: /bin/systemctl enable *
$TARGET_USER ALL=(root) NOPASSWD: /bin/systemctl disable *
$TARGET_USER ALL=(root) NOPASSWD: /bin/systemctl start *
$TARGET_USER ALL=(root) NOPASSWD: /bin/systemctl stop *
$TARGET_USER ALL=(root) NOPASSWD: /bin/systemctl restart *
$TARGET_USER ALL=(root) NOPASSWD: /bin/systemctl status *

# Service file deployment
$TARGET_USER ALL=(root) NOPASSWD: /bin/mv /tmp/*.service /etc/systemd/system/*
$TARGET_USER ALL=(root) NOPASSWD: /bin/chmod 644 /etc/systemd/system/*.service

# Reboot + hostname
$TARGET_USER ALL=(root) NOPASSWD: /sbin/reboot *
$TARGET_USER ALL=(root) NOPASSWD: /bin/hostnamectl set-hostname *

# Swap
$TARGET_USER ALL=(root) NOPASSWD: /sbin/swapoff *
$TARGET_USER ALL=(root) NOPASSWD: /sbin/swapon *

# Power mode + clock locking (Jetson)
$TARGET_USER ALL=(root) NOPASSWD: /usr/sbin/nvpmodel *
$TARGET_USER ALL=(root) NOPASSWD: /usr/bin/jetson_clocks *
$TARGET_USER ALL=(root) NOPASSWD: /usr/bin/jetson_clocks
SUDOERS
    sudo chmod 440 /etc/sudoers.d/seren
    if sudo visudo -cf /etc/sudoers.d/seren; then
        log "Sudoers validated"
    else
        fail "Sudoers INVALID — file rejected by visudo"
        return 1
    fi
}
run_phase "00_sudoers" "Base — Sudoers" phase_sudoers

phase_hostname() {
    if [ "$(hostname)" != "$TARGET_HOSTNAME" ]; then
        sudo hostnamectl set-hostname "$TARGET_HOSTNAME"
        log "Hostname set to $TARGET_HOSTNAME"
    else
        log "Hostname already $TARGET_HOSTNAME"
    fi
}
run_phase "00_hostname" "Base — Hostname" phase_hostname

# ─────────────────────────────────────────────────────────────
# Source platform module (defines run_foundation, etc.)
# ─────────────────────────────────────────────────────────────
log "Sourcing platform module: $PLATFORM_DIR/foundation.sh"
# shellcheck disable=SC1091
source "$PLATFORM_DIR/foundation.sh"

# ─────────────────────────────────────────────────────────────
# Foundation prebuilts — downloaded BEFORE foundation runs
# ─────────────────────────────────────────────────────────────
# On Xavier these are python3.10 + sqlite3.45 tarballs that skip ~40 min of
# source builds. Best-effort: if not in the release, foundation falls back.
# On Nano this is a no-op (Python 3.10 is native, SQLite is recent enough).
if ! $USE_BUILD_FLAG; then
    if [ -f "$PLATFORM_DIR/prebuilts.sh" ]; then
        # shellcheck disable=SC1091
        source "$PLATFORM_DIR/prebuilts.sh"
        if declare -F run_prebuilts_download_foundation >/dev/null; then
            run_prebuilts_download_foundation
        fi
    fi
fi

# ─────────────────────────────────────────────────────────────
# Foundation phases
# ─────────────────────────────────────────────────────────────
run_foundation

# ─────────────────────────────────────────────────────────────
# Service prebuilts — staged AFTER foundation, BEFORE services
# ─────────────────────────────────────────────────────────────
# Only needed if at least one service requires staged artifacts.
NEEDS_PREBUILTS=false
$INSTALL_LLAMA   && NEEDS_PREBUILTS=true
$INSTALL_COMFYUI && NEEDS_PREBUILTS=true
$INSTALL_CORAL   && NEEDS_PREBUILTS=true

if $NEEDS_PREBUILTS; then
    # NOT every platform ships every module. Xavier and Nano have the full set
    # (build.sh, prebuilts.sh, coral.sh); the Spark deliberately has neither a
    # build path nor prebuilts, because JetPack 7 ships what those exist to
    # provide. Before these guards, `--llama` on a Spark fell through to an
    # undefined run_prebuilts_download and died on "command not found" under
    # set -e - a bash error, on brand new hardware, before installing anything.
    if $USE_BUILD_FLAG; then
        if [ ! -f "$PLATFORM_DIR/build.sh" ]; then
            fail "Platform '$PLATFORM' has no source-build path (no $PLATFORM_DIR/build.sh)."
            fail "Drop the build flag - this platform installs from packages instead."
            exit 1
        fi
        # shellcheck disable=SC1091
        source "$PLATFORM_DIR/build.sh"
        run_build_path
    else
        # prebuilts.sh already sourced above for foundation
        if declare -F run_prebuilts_download_services >/dev/null; then
            run_prebuilts_download_services
        elif declare -F run_prebuilts_download >/dev/null; then
            run_prebuilts_download   # platforms without the split functions
        else
            # No prebuilts machinery at all. On the Spark that's correct, not
            # broken: JetPack 7 ships CUDA/Python/SQLite new enough that there
            # is nothing to stage. Say so and carry on to the services.
            info "No prebuilt staging for '$PLATFORM' - services install directly."
        fi
    fi
else
    info "Skipping service prebuilts (no service needs staged artifacts)"
fi

# ─────────────────────────────────────────────────────────────
# Service installation — each service is its own sourceable module
# ─────────────────────────────────────────────────────────────
# Service phases ALWAYS run when explicitly flagged (no phase tracking).
# Each service file defines an install_<service> function.

if $INSTALL_LLAMA; then
    # shellcheck disable=SC1091
    source "$PLATFORM_DIR/llama.sh"
    run_service "Service — llama.cpp" install_llama
fi

if $INSTALL_KOKORO; then
    # shellcheck disable=SC1091
    source "$PLATFORM_DIR/kokoro.sh"
    run_service "Service — Kokoro-FastAPI" install_kokoro
fi

if $INSTALL_COMFYUI; then
    # shellcheck disable=SC1091
    source "$PLATFORM_DIR/comfy.sh"
    run_service "Service — ComfyUI" install_comfy
fi

if $INSTALL_CHROMADB; then
    # shellcheck disable=SC1091
    source "$PLATFORM_DIR/chroma.sh"
    run_service "Service — ChromaDB" install_chroma
fi

if $INSTALL_CORAL; then
    # shellcheck disable=SC1091
    source "$PLATFORM_DIR/coral.sh"
    run_service "Service — Coral TPU" install_coral
fi

# ─────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────
echo "" >&3
echo -e "${GREEN}══════════════════════════════════════════${NC}" >&3
echo -e "${GREEN}  Seren Setup Complete${NC}" >&3
echo -e "${GREEN}══════════════════════════════════════════${NC}" >&3
echo "" >&3
{
    echo "  Platform:    $PLATFORM ($JP_FAMILY)"
    echo "  Hostname:    $(hostname)"
    echo "  User:        $TARGET_USER"
    echo "  Kernel:      $KERNEL_VER"
    echo ""
    echo "  Installed services:"
    $INSTALL_LLAMA    && echo "    ✓ llama.cpp"
    $INSTALL_KOKORO   && echo "    ✓ Kokoro-FastAPI"
    $INSTALL_COMFYUI  && echo "    ✓ ComfyUI"
    $INSTALL_CHROMADB && echo "    ✓ ChromaDB"
    $INSTALL_CORAL    && echo "    ✓ Coral TPU (REBOOT REQUIRED for kernel cmdline)"
    echo ""
    echo "  Next: sudo reboot, then start your services."
} >&3
echo "" >&3
echo -e "${GREEN}══════════════════════════════════════════${NC}" >&3
echo "" >&3
