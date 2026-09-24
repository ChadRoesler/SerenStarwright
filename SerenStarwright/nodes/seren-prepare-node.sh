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
#       --tag TAG         Pin to a prebuilt release tag (e.g. 20260916_xavier-jp5)
#       --trim-os         CONSENT: remove the desktop, docker and snap (headless node)
#       --wipe-nvme       CONSENT: wipe and format the NVMe if it is not already ext4
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
#   bash seren-prepare-node.sh -l -k -d --tag 20260916_xavier-jp5
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
# EMPTY MEANS LEAVE THE HOSTNAME ALONE, and nothing fills it in for you any
# more. It used to be derived from this invocation's service flags - `-m` on a
# box called xavier-llama-kokoro-chroma computed "xavier-msmoe" and renamed it -
# so adding one component was structurally a rename request. Only --rename sets
# this now.
TARGET_HOSTNAME=""
# Opt-in base + foundation prep. Tri-state on purpose:
#   true   - --prep given, run it
#   false  - --no-prep given, never run it
#   ""     - decide from machine state: run it iff this node was never prepared
FORCE_PREP=""
USE_BUILD_FLAG=false
USER_PREBUILT_TAG=""
SKIP_MAX_POWER=false
# THE TWO THINGS PREP DOES THAT CANNOT BE UNDONE, each behind its own flag.
# They used to run whenever prep ran: a fresh box got its desktop, docker and
# snap purged and its NVMe reformatted with no question asked, reachable from
# the TUI's Install button with nothing typed. Both are still the right thing
# for a dedicated node - so they are one flag away, not gone - but a flag is
# a sentence somebody wrote, and "it just did that" is not.
TRIM_OS=false
WIPE_NVME=false

INSTALL_LLAMA=false
INSTALL_KOKORO=false
INSTALL_COMFYUI=false
INSTALL_CHROMADB=false
INSTALL_CORAL=false
# Ms.MoE Maker: the MoE build pipeline. Its own component because the thing it
# needs is a CUDA torch staged per platform, which is what this side of
# Starwright already does - see <platform>/msmoe.sh for why it is not a service.
INSTALL_MSMOE=false

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

Base prep (OS trim, CUDA, NVMe, sudoers - the slow, machine-wide part):
      --prep            Run base + foundation prep even if already done
      --no-prep         Never run it, even on a node never prepped before
                        With neither flag: prep runs ONLY if this node has no
                        record of ever having been prepared. Once it has, a
                        component install goes straight to the component.

Options:
  -u, --user USER       Target user (default: invoking user)
      --rename NAME     Set the hostname to NAME. Nothing else renames the box;
                        omit this and the hostname is never touched.
      --build           Build artifacts from source (slow; default is download)
      --tag TAG         Pin to a prebuilt release tag (YYYYMMDD_<platform>)
      --trim-os         Remove the desktop, docker and snap: this becomes a
                        headless node. Prep SKIPS the OS trim without it.
      --wipe-nvme       If nvme0n1p1 is missing or not ext4, wipe the disk and
                        make a fresh ext4. Without it, a non-ext4 NVMe STOPS
                        the run and says so. An ext4 NVMe is mounted either way.
      --no-max-power    Skip MAXN power mode + jetson_clocks (default: ON).
                        Jetson platforms only — a node without nvpmodel skips
                        this phase anyway. Use on passively-cooled or
                        battery-powered Jetsons.
  -h, --help            Show this help

Examples:
  First build of a box: $0 -l -k -d --rename xavier-brain
  Add a component:      $0 -m         (no prep, no rename, no surprises)
  Re-run prep only:     $0 --prep
  Specialist node:      $0 -c
  Edge node + TPU:      $0 --all --coral
  Pinned release:       $0 -l -k -d --tag 20260916_xavier-jp5
  Fanless / battery:    $0 -l -k --no-max-power
  Dedicated node:       $0 --prep --trim-os --wipe-nvme --rename nano-edge
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -l|--llama)    INSTALL_LLAMA=true; shift ;;
        -k|--kokoro)   INSTALL_KOKORO=true; shift ;;
        -c|--comfyui)  INSTALL_COMFYUI=true; shift ;;
        -d|--chromadb) INSTALL_CHROMADB=true; shift ;;
        --coral)       INSTALL_CORAL=true; shift ;;
        -m|--msmoe)    INSTALL_MSMOE=true; shift ;;
        # --all is the INFERENCE set. msmoe is left out on purpose, the same
        # way coral is - though for a different reason: coral is gated on
        # hardware, this is gated on weight. [train] pulls a multi-gigabyte
        # stack for a job most nodes never do, and --all on an 8GB Nano
        # should not quietly become that. Ask for it by name.
        --all)         INSTALL_LLAMA=true; INSTALL_KOKORO=true
                       INSTALL_COMFYUI=true; INSTALL_CHROMADB=true; shift ;;
        -u|--user)     TARGET_USER="$2"; shift 2 ;;
        # RENAME, not "hostname". The verb is the point: this is the only flag
        # that changes the identity of the machine, and the old spelling read
        # like a setting you were declaring rather than an act. See
        # TARGET_HOSTNAME above for what it replaced.
        --rename)      TARGET_HOSTNAME="$2"; shift 2 ;;
        --prep)        FORCE_PREP=true; shift ;;
        --no-prep)     FORCE_PREP=false; shift ;;
        --build)       USE_BUILD_FLAG=true; shift ;;
        --tag)         USER_PREBUILT_TAG="$2"; shift 2 ;;
        # Overrides detection entirely. Needed for the DGX Spark, whose
        # auto-detection is written from spec rather than from a tested
        # machine - and useful on anything new enough to fool the heuristics.
        --platform)    export SEREN_PLATFORM="$2"; shift 2 ;;
        --no-max-power) SKIP_MAX_POWER=true; shift ;;
        --trim-os)     TRIM_OS=true; shift ;;
        --wipe-nvme)   WIPE_NVME=true; shift ;;
        # Starwright contracts. --events points at a JSON Lines file the caller
        # tails; --describe reports this node's shape and exits without doing
        # anything. See seren_event in lib/common.sh for why events go to a
        # file here rather than to stdout like the service installers.
        --events)      export SEREN_EVENTS_FILE="$2"; shift 2 ;;
        --describe)    DO_DESCRIBE=true; shift ;;
        -h|--help)     usage; exit 0 ;;
        *)
            # The retired spelling is matched INSIDE the catch-all, not given a
            # case branch of its own. --describe derives its flag list by
            # grepping the case branches in this file
            # (seren_node_flags_from_self), so `-H|--hostname)` would advertise
            # "hostname" straight back into the TUI - which then renders the
            # very input this change exists to remove.
            if [ "$1" = "--hostname" ] || [ "$1" = "-H" ]; then
                echo "ERROR: -H/--hostname was removed. It derived a name from your" >&2
                echo "       service flags and renamed the box as a side effect of" >&2
                echo "       installing a component." >&2
                echo "       To rename deliberately:  --rename ${2:-NAME}" >&2
                exit 1
            fi
            echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
done

# --describe: answer and exit, ZERO side effects. Must come before the
# "at least one service" check below - describing a node is not installing on
# it, and requiring -l just to ask what's available would be absurd.
if ${DO_DESCRIBE:-false}; then
    seren_describe_node
    exit 0
fi

# Something must be asked for - but a component is no longer the only thing you
# can ask for. `--prep` on its own (prepare the box, install nothing) and
# `--rename` on its own are both legitimate now that prep is a separate act.
ANY_COMPONENT=false
$INSTALL_LLAMA    && ANY_COMPONENT=true
$INSTALL_KOKORO   && ANY_COMPONENT=true
$INSTALL_COMFYUI  && ANY_COMPONENT=true
$INSTALL_CHROMADB && ANY_COMPONENT=true
$INSTALL_CORAL    && ANY_COMPONENT=true
$INSTALL_MSMOE    && ANY_COMPONENT=true

if ! $ANY_COMPONENT && [ "$FORCE_PREP" != "true" ] && [ -z "$TARGET_HOSTNAME" ]; then
    echo "ERROR: Nothing to do. Give a component (-l/-k/-c/-d/-m/--coral or --all)," >&2
    echo "       or --prep to prepare the box, or --rename NAME." >&2
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

# NO HOSTNAME DERIVATION. There used to be a block here that built a name out
# of this invocation's service flags ("${PLATFORM}-llama-kokoro-chroma") and left
# it in TARGET_HOSTNAME, which phase_hostname then applied. Two things were wrong
# with it and the second is the one that bit:
#
#   1. It made the hostname a function of the SERVICE SET, so changing what a
#      node runs meant changing what the node is called. `-m` on an existing
#      brain node computed "xavier-msmoe".
#   2. The only thing standing between that and a real rename was phase state
#      keyed "00_hostname" - kept in a gitignored file inside the checkout. On
#      any fresh clone, or after any .pyz rebuild, that file is absent, the
#      phase looks undone, and the box gets renamed by a command whose stated
#      job was installing a component.
#
# So the name is now only ever what somebody typed after --rename.

# Set up logging
LOG_FILE="$SCRIPT_DIR/seren-setup.log"

# Phase state lives on the MACHINE, not in this checkout - see seren_state_path
# in lib/common.sh for the full why. Short version: the old
# $SCRIPT_DIR/.seren-setup.state.json is gitignored, so it was absent from every
# fresh clone and every .pyz rebuild, which made "already prepared" unknowable
# and every foundation phase re-run by default.
STATE_FILE="$(seren_state_path)"
LEGACY_STATE_FILE="$SCRIPT_DIR/.seren-setup.state.json"
export LOG_FILE STATE_FILE SKIP_MAX_POWER TRIM_OS WIPE_NVME

# Decided BEFORE the state file is created, because creating it is what makes a
# node look prepared. Read it now, act on it later.
NODE_WAS_PROVISIONED=false
node_provisioned && NODE_WAS_PROVISIONED=true

# Neither --prep nor --no-prep: prep iff this machine has never been prepared.
# That is the whole point of the change - a first run on bare hardware still
# just works, and every run after it leaves the box's foundation alone.
if [ -n "$FORCE_PREP" ]; then
    RUN_PREP="$FORCE_PREP"
elif $NODE_WAS_PROVISIONED; then
    RUN_PREP=false
else
    RUN_PREP=true
fi

# Banner before redirecting stdout
echo ""
echo -e "${GREEN}══════════════════════════════════════════${NC}"
echo -e "${GREEN}  Seren Setup — ${PLATFORM} (${JP_FAMILY})${NC}"
echo -e "${GREEN}══════════════════════════════════════════${NC}"
echo ""
echo -e "${GREEN}[SEREN]${NC} Detailed output → $LOG_FILE"
echo -e "${GREEN}[SEREN]${NC} Phase state    → $STATE_FILE"
# The two facts most worth knowing BEFORE anything touches the box, printed to
# the console rather than buried in the log: is the foundation about to be
# rebuilt, and is this machine about to change its name.
if $RUN_PREP; then
    if $NODE_WAS_PROVISIONED; then
        echo -e "${GREEN}[SEREN]${NC} Base prep      → RE-RUNNING (--prep)"
    else
        echo -e "${GREEN}[SEREN]${NC} Base prep      → running (this node has no prep record)"
    fi
elif $NODE_WAS_PROVISIONED; then
    echo -e "${GREEN}[SEREN]${NC} Base prep      → skipped (already prepared; --prep forces)"
else
    # --no-prep on a box with no prep record. Honest about it AND loud about it:
    # the components below expect a foundation that may not be there, and
    # "skipped (already prepared)" would have been a flat untruth here.
    echo -e "${YELLOW}[SEREN]${NC} Base prep      → SKIPPED by --no-prep, and this node has NO prep record"
    echo -e "${YELLOW}[SEREN]${NC}                  components may fail on missing CUDA/Python/NVMe"
fi
if [ -n "$TARGET_HOSTNAME" ]; then
    echo -e "${GREEN}[SEREN]${NC} Hostname       → RENAMING to $TARGET_HOSTNAME"
else
    echo -e "${GREEN}[SEREN]${NC} Hostname       → $(hostname) (unchanged)"
fi
# The two irreversible things, said on the console where the prompt would
# have been. Only relevant when prep runs; a component install touches neither.
if $RUN_PREP; then
    if $TRIM_OS; then
        echo -e "${YELLOW}[SEREN]${NC} OS trim        → YES (--trim-os): desktop, docker and snap will be removed"
    else
        echo -e "${GREEN}[SEREN]${NC} OS trim        → skipped (pass --trim-os to make this a headless node)"
    fi
    if $WIPE_NVME; then
        echo -e "${YELLOW}[SEREN]${NC} NVMe           → WILL WIPE nvme0n1 if it is not already ext4 (--wipe-nvme)"
    else
        echo -e "${GREEN}[SEREN]${NC} NVMe           → mount if ext4; a non-ext4 disk stops the run (--wipe-nvme to format)"
    fi
fi
echo ""

: > "$LOG_FILE"
exec >> "$LOG_FILE" 2>&1

log "Platform:        $PLATFORM ($JP_FAMILY, kernel $KERNEL_VER)"
log "Target user:     $TARGET_USER"
log "Hostname:        $(hostname)$([ -n "$TARGET_HOSTNAME" ] && echo " -> RENAMING to $TARGET_HOSTNAME" || echo " (unchanged)")"
if $RUN_PREP; then
    log "Base prep:       RUNNING"
elif $NODE_WAS_PROVISIONED; then
    log "Base prep:       skipped (prepared $(seren_state_get _provisioned_at))"
else
    warn "Base prep:       SKIPPED by --no-prep on a node with no prep record"
fi
log "Build mode:      $($USE_BUILD_FLAG && echo 'BUILD FROM SOURCE' || echo 'prebuilt download')"
log "OS trim:         $($TRIM_OS && echo 'YES (--trim-os)' || echo 'no')"
log "NVMe wipe:       $($WIPE_NVME && echo 'ALLOWED (--wipe-nvme)' || echo 'not allowed')"
log "Max power:       $($SKIP_MAX_POWER && echo 'SKIPPED (--no-max-power)' || echo 'ON (MAXN + jetson_clocks)')"
log "Services:        llama=$INSTALL_LLAMA kokoro=$INSTALL_KOKORO comfy=$INSTALL_COMFYUI chroma=$INSTALL_CHROMADB coral=$INSTALL_CORAL msmoe=$INSTALL_MSMOE"

# Initialize state file. jq first: phase_mark and the provisioned stamp need it,
# and the READ side (node_provisioned, above) deliberately does not - it has
# already run by this point, before anything could be installed.
ensure_jq
seren_state_migrate "$STATE_FILE" "$LEGACY_STATE_FILE"
if ! seren_state_init "$STATE_FILE"; then
    fail "Cannot create phase state at $STATE_FILE"
    fail "Prep would re-run every phase on every invocation without it."
    exit 1
fi

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
# Base box setup — sudoers (prep only) + rename (only when asked)
# ─────────────────────────────────────────────────────────────
# These run BEFORE the platform module so the foundation phases have a
# consistent environment to build on.
#
# NEITHER IS UNCONDITIONAL ANY MORE, and they became conditional for different
# reasons:
#
#   sudoers  - it is a privilege grant written for $TARGET_USER, and re-running
#              it silently re-points /etc/sudoers.d/seren at whoever happened to
#              invoke this time. That belongs to preparing a box, not to adding
#              a component to one. It runs under $RUN_PREP.
#
#   hostname - see the note where the derivation used to live. It now runs if
#              and only if --rename gave us a name.

phase_sudoers() {
    # ── the helper first, because the grant names it ──
    # /usr/local/sbin/seren-systemctl is the ONLY systemctl this user may run
    # as root without a password, and it accepts exactly one verb and one
    # seren-* unit. See the header of lib/seren-systemctl for why a sudoers
    # glob cannot do that job. Root-owned and not writable by the user, or the
    # grant would be worth nothing.
    local helper_src="$SCRIPT_DIR/lib/seren-systemctl"
    [ -f "$helper_src" ] || { fail "lib/seren-systemctl is missing beside this script"; return 1; }
    sudo install -o root -g root -m 0755 "$helper_src" /usr/local/sbin/seren-systemctl
    log "installed /usr/local/sbin/seren-systemctl"

    # WHAT THIS GRANTS, AND WHAT IT NO LONGER DOES.
    #
    # The previous file was root-equivalent in two lines:
    #     /bin/mv /tmp/*.service /etc/systemd/system/*
    #     /bin/systemctl start *
    # Write any unit into /tmp, move it into place, start it. Neither line had
    # a consumer: installers run as a person who already has sudo, and the
    # Observatory - the one thing that runs unattended as this user - only ever
    # needs to start, stop and restart the family's own units, drop caches,
    # and schedule a reboot. So the grant is now exactly that list:
    #
    #   drop_caches / compact_memory    memory reclaim (exact arguments)
    #   seren-systemctl                 one verb, one seren-* unit, no path
    #   shutdown -r <when> / -c         the Observatory's reboot + cancel
    #
    # hostnamectl, swapon/swapoff, nvpmodel and jetson_clocks are gone from it:
    # prep runs them itself under the invoking sudo, and the max-power unit
    # runs as root through systemd. Nothing unattended needed them.
    sudo tee /etc/sudoers.d/seren > /dev/null << SUDOERS
# Seren stack - passwordless sudo for the Observatory's unattended work.
# Generated by seren-prepare-node.sh for user: $TARGET_USER
# Validate: sudo visudo -cf /etc/sudoers.d/seren
#
# Deliberately narrow. Every line here names exact arguments or a helper
# that validates its own. If something you are adding needs a wildcard,
# add a verb to /usr/local/sbin/seren-systemctl instead.

# Memory reclaim
$TARGET_USER ALL=(root) NOPASSWD: /usr/bin/tee /proc/sys/vm/drop_caches
$TARGET_USER ALL=(root) NOPASSWD: /usr/bin/tee /proc/sys/vm/compact_memory

# Service control - only through the helper, only seren-* units
$TARGET_USER ALL=(root) NOPASSWD: /usr/local/sbin/seren-systemctl

# Reboot (Observatory POST /system/reboot and /reboot/cancel).
# The time argument is bounded by the Observatory's own clamp; -c cancels.
$TARGET_USER ALL=(root) NOPASSWD: /sbin/shutdown -r *
$TARGET_USER ALL=(root) NOPASSWD: /sbin/shutdown -c
SUDOERS
    sudo chmod 440 /etc/sudoers.d/seren
    if sudo visudo -cf /etc/sudoers.d/seren; then
        log "Sudoers validated"
    else
        fail "Sudoers INVALID — file rejected by visudo"
        return 1
    fi
    # The legacy per-agent file, if a box still carries one, is the wide grant
    # under another name. Say so rather than silently leave it.
    if [ -f /etc/sudoers.d/seren-agent ]; then
        warn "/etc/sudoers.d/seren-agent is still present (the retired agent's grant)."
        warn "  It is broader than the new file. Remove it once the Observatory is on this node:"
        warn "    sudo rm /etc/sudoers.d/seren-agent"
    fi
}
if $RUN_PREP; then
    run_phase "00_sudoers" "Base — Sudoers" phase_sudoers
elif $NODE_WAS_PROVISIONED; then
    info "Skipping sudoers (node already prepared; --prep re-runs it)"
else
    warn "Skipping sudoers (--no-prep) - /etc/sudoers.d/seren may not exist yet"
fi

# NOT a tracked phase, and that is the correction rather than an oversight.
# `run_phase "00_hostname"` recorded "the hostname phase has run" - not WHICH
# name it set - so the second, deliberate `--rename something-else` was skipped
# as already done. A rename is an act, not a milestone: when asked for, it
# happens; when not asked for, there is nothing here to skip.
if [ -n "$TARGET_HOSTNAME" ]; then
    if [ "$(hostname)" = "$TARGET_HOSTNAME" ]; then
        log "Hostname already $TARGET_HOSTNAME - nothing to do"
    else
        seren_event phase_start label "Base — Rename" tracked false
        log "▶ Base — Rename: $(hostname) -> $TARGET_HOSTNAME"
        sudo hostnamectl set-hostname "$TARGET_HOSTNAME"
        mark_hostname_set "$TARGET_HOSTNAME"
        log "✓ Hostname set to $TARGET_HOSTNAME"
        seren_event phase_done label "Base — Rename"
    fi
else
    prior_name="$(seren_state_get _hostname_set_to)"
    if [ -n "$prior_name" ]; then
        info "Hostname left as $(hostname) (seren set it to $prior_name; --rename changes it)"
    else
        info "Hostname left as $(hostname) (--rename NAME to change it)"
    fi
fi

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
#
# SOURCING IS UNCONDITIONAL; ONLY THE DOWNLOAD IS GATED. Getting that split
# wrong reintroduces a bug this file already carries a comment about: the
# service-prebuilts block further down notes "prebuilts.sh already sourced above
# for foundation" and calls run_prebuilts_download_services. Put the `source`
# behind $RUN_PREP and on a prepared box that function is undefined, so the
# staging step falls through to its "no prebuilts machinery" branch, msmoe finds
# STAGED_TORCH_WHL unset, and the staged Jetson torch wheel is silently replaced
# by a redist download. A silent downgrade, on exactly the path that motivated
# splitting prep out in the first place.
if ! $USE_BUILD_FLAG; then
    if [ -f "$PLATFORM_DIR/prebuilts.sh" ]; then
        # shellcheck disable=SC1091
        source "$PLATFORM_DIR/prebuilts.sh"
        if $RUN_PREP && declare -F run_prebuilts_download_foundation >/dev/null; then
            run_prebuilts_download_foundation
        fi
    fi
fi

# ─────────────────────────────────────────────────────────────
# Foundation phases
# ─────────────────────────────────────────────────────────────
# The slow, machine-wide part: OS trim, CUDA, NVMe, swap, power profile. Three
# to seven phases of apt-get depending on platform, each individually tracked.
#
# Running this before every component install is what made "add Ms.MoE to a
# working node" a twenty-minute wait with a rename at the end of it.
if $RUN_PREP; then
    run_foundation
    # Stamped only after foundation returns. A half-finished prep leaves the
    # machine unprovisioned on purpose: the next run picks it up and the
    # individual phase keys make it resume rather than start over.
    mark_provisioned "$PLATFORM"
elif $NODE_WAS_PROVISIONED; then
    info "Skipping foundation phases - prepared $(seren_state_get _provisioned_at)"
    info "Re-run them with --prep if the box itself needs work."
else
    warn "Skipping foundation phases (--no-prep) on a node with no prep record."
    warn "If a component fails on CUDA, Python or NVMe, this is why."
fi

# ─────────────────────────────────────────────────────────────
# Service prebuilts — staged AFTER foundation, BEFORE services
# ─────────────────────────────────────────────────────────────
# Only needed if at least one service requires staged artifacts.
NEEDS_PREBUILTS=false
$INSTALL_LLAMA   && NEEDS_PREBUILTS=true
$INSTALL_COMFYUI && NEEDS_PREBUILTS=true
$INSTALL_CORAL   && NEEDS_PREBUILTS=true
# msmoe needs the staged torch wheel, so it needs the prebuilts phase. Without
# this line msmoe.sh finds STAGED_TORCH_WHL unset, falls through to the redist
# branch, and the carefully built Jetson wheel is simply never used - a silent
# downgrade rather than an error.
$INSTALL_MSMOE   && NEEDS_PREBUILTS=true

if $NEEDS_PREBUILTS; then
    # NOT every platform ships every module. Xavier and Nano have a build path;
    # the Spark does not (its archive is built on the Spark itself). Prebuilt
    # STAGING is shared by all three now - lib/common.sh, driven by the
    # release's SHA256SUMS - so the Spark's llama-server, torch and coral
    # modules stage like everyone else's. It used to have no prebuilts.sh at
    # all, so `--llama` on a Spark passed this block with a cheerful "services
    # install directly" and then died in spark/llama.sh on "staged binary
    # missing".
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

if $INSTALL_MSMOE; then
    # shellcheck disable=SC1091
    source "$PLATFORM_DIR/msmoe.sh"
    run_service "Service — Ms.MoE Maker" install_msmoe
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
    echo "  Hostname:    $(hostname)$([ -n "$TARGET_HOSTNAME" ] && echo "  (renamed this run)" || echo "  (unchanged)")"
    echo "  User:        $TARGET_USER"
    echo "  Kernel:      $KERNEL_VER"
    echo "  Base prep:   $($RUN_PREP && echo 'ran this run' || echo 'skipped - already prepared')"
    echo ""
    echo "  Installed components:"
    # msmoe was missing from this list while being installable, so a run that
    # did nothing else reported an empty "Installed components" and looked like
    # a no-op.
    $INSTALL_LLAMA    && echo "    ✓ llama.cpp"
    $INSTALL_KOKORO   && echo "    ✓ Kokoro-FastAPI"
    $INSTALL_COMFYUI  && echo "    ✓ ComfyUI"
    $INSTALL_CHROMADB && echo "    ✓ ChromaDB"
    $INSTALL_MSMOE    && echo "    ✓ Ms.MoE Maker"
    $INSTALL_CORAL    && echo "    ✓ Coral TPU (REBOOT REQUIRED for kernel cmdline)"
    $ANY_COMPONENT    || echo "    (none - prep only)"
    echo ""
    if $RUN_PREP; then
        echo "  Next: sudo reboot, then start your services."
    else
        echo "  Next: start your services. Nothing here changed the box itself."
    fi
} >&3
echo "" >&3
echo -e "${GREEN}══════════════════════════════════════════${NC}" >&3
echo "" >&3
