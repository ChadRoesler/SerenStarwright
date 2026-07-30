#!/bin/bash
# ══════════════════════════════════════════════════════════════
# common.sh — Shared helpers for seren-setup.sh
#
# Sourced by seren-setup.sh and platform modules.
# Provides:
#   - Logging (log/warn/fail/info)
#   - Phase tracking (jq-backed, resumable)
#   - Platform detection (jp5/Xavier vs jp6/Orin Nano)
#   - GitHub release tag resolution
#   - PyTorch version pinning per platform
#
# Do not run directly.
# ══════════════════════════════════════════════════════════════

# Guard against double-sourcing
[ "${SEREN_COMMON_LOADED:-0}" = "1" ] && return 0
SEREN_COMMON_LOADED=1

# ─────────────────────────────────────────────────────────────
# Colors + logging
# ─────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# These print to FD 3 if open (so they show on console even when stdout is
# redirected to a log file), and also to stdout (so they end up in the log).
log()  { echo -e "${GREEN}[SEREN]${NC} $1" >&3 2>/dev/null || true; echo -e "${GREEN}[SEREN]${NC} $1"; seren_event ok    msg "$1"; }
warn() { echo -e "${YELLOW}[SEREN]${NC} $1" >&3 2>/dev/null || true; echo -e "${YELLOW}[SEREN]${NC} $1"; seren_event warn  msg "$1"; }
fail() { echo -e "${RED}[SEREN]${NC} $1" >&3 2>/dev/null || true; echo -e "${RED}[SEREN]${NC} $1"; seren_event error msg "$1"; }
info() { echo -e "${BLUE}[SEREN]${NC} $1" >&3 2>/dev/null || true; echo -e "${BLUE}[SEREN]${NC} $1"; seren_event info  msg "$1"; }

# ─────────────────────────────────────────────────────────────
# Structured events — the Starwright contract, node-prep flavour
# ─────────────────────────────────────────────────────────────
#
# WHY A FILE AND NOT A STREAM, unlike the service installers:
#
# The service side puts JSON on stdout and human text on stderr. That is not
# available here, because seren-prepare-node.sh does
#
#     exec 3>&1 4>&2            # stash the real console
#     exec >> "$LOG_FILE" 2>&1  # stdout AND stderr now go to the log file
#
# Both standard streams are already spoken for by the tee'd logging, and fd 3
# is how human progress gets back to the caller. There is no free stream to
# put events on without unpicking the logging that the whole of node prep is
# built around — and prep shells out to apt-get, cmake, nvpmodel and pip,
# none of which are famous for stream hygiene.
#
# So: an explicit file. --events PATH (or $SEREN_EVENTS_FILE). Starwright tails
# it while the run proceeds. Immune to any redirection, works when a phase
# scribbles on every stream it can find, and costs nothing when unset.
#
# Same JSON Lines shape as the service side, so one consumer reads both.

seren_json_escape_str() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\r'/}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\t'/\\t}"
    # strip ANSI colour - these messages are built with colour codes inline and
    # a raw escape byte in a JSON string is both ugly and technically invalid
    printf '%s' "$s" | sed -E 's/\x1b\[[0-9;]*m//g'
}

# seren_node_flags_from_self — read the DISPATCHER's own accepted flags.
#
# $0 inside a sourced library is still the parent script, so this greps
# seren-prepare-node.sh's own case branches. Mirrors seren_flags_from_self on
# the service side, and for the same reason: a hand-maintained flag list is a
# second source of truth, and a UI that assumes what the dispatcher accepts is
# one commit away from offering an option that doesn't exist (or hiding one
# that does).
#
# Degrades to empty if $0 isn't readable - "flags":[] is an honest answer.
seren_node_flags_from_self() {
    [ -r "${0:-}" ] || return 0
    grep -oE '^[[:space:]]+-{1,2}[a-zA-Z][a-zA-Z|-]*\)' "$0" 2>/dev/null \
        | tr -d ' )' \
        | tr '|' '\n' \
        | sed 's/^-*//' \
        | grep -vE '^.$' \
        | sort -u \
        | tr '\n' ' '
}

seren_describe_node() {
    local script_dir="${1:-$SCRIPT_DIR}"
    local detected="null" fam="null" arch="null"
    # 3>/dev/null matters as much as the other two: log/info/warn/fail write to
    # fd 3 (the saved console) as well as stdout, so redirecting only stdout and
    # stderr still let detection chatter onto the caller's pipe and corrupt the
    # JSON. --describe must emit exactly one line and nothing else.
    if detect_platform >/dev/null 2>&1 3>/dev/null; then
        detected="\"$PLATFORM\""; fam="\"$JP_FAMILY\""; arch="\"$CUDA_ARCH\""
    fi

    # name:display:description  — coral last, it's the hardware-gated one
    local specs=(
        "llama:llama.cpp:Inference server"
        "kokoro:Kokoro:Text to speech"
        "comfyui:ComfyUI:Image generation"
        "chromadb:ChromaDB:Vector store"
        "coral:Coral TPU:M.2 Edge TPU support"
    )
    # module filename differs from the flag name for these two
    local comps="" first=1
    for spec in "${specs[@]}"; do
        local n="${spec%%:*}" rest="${spec#*:}"
        local disp="${rest%%:*}" desc="${rest#*:}"
        local modfile="$n"
        [ "$n" = "comfyui" ]  && modfile="comfy"
        [ "$n" = "chromadb" ] && modfile="chroma"
        local avail=false
        [ "$detected" != "null" ] && \
            [ -f "$script_dir/$PLATFORM/$modfile.sh" ] && avail=true
        [ $first -eq 0 ] && comps="$comps,"
        first=0
        comps="$comps{\"name\":\"$n\",\"display\":\"$(seren_json_escape_str "$disp")\""
        comps="$comps,\"description\":\"$(seren_json_escape_str "$desc")\""
        comps="$comps,\"available\":$avail"
        comps="$comps,\"hardware_gated\":$([ "$n" = coral ] && echo true || echo false)"
        # foundation phases are state-tracked and skip; component phases never do
        comps="$comps,\"always_reinstalls\":true}"
    done

    printf '{"schema_version":1,"kind":"node"'
    printf ',"platform":%s,"jp_family":%s,"cuda_arch":%s' "$detected" "$fam" "$arch"
    printf ',"hostname":"%s"' "$(seren_json_escape_str "$(hostname 2>/dev/null || echo '')")"
    printf ',"components":[%s]' "$comps"
    printf ',"modes":["prebuilts","build"]'
    printf ',"platforms":["xavier","nano","spark"]'
    # Derived, never declared - see seren_node_flags_from_self.
    local flags_json="" f
    for f in $(seren_node_flags_from_self); do
        flags_json="${flags_json:+$flags_json,}\"$(seren_json_escape_str "$f")\""
    done
    printf ',"flags":[%s]' "$flags_json"
    printf '}\n'
}

# seren_event <event> [key value]...
seren_event() {
    [ -n "${SEREN_EVENTS_FILE:-}" ] || return 0
    local ev="$1"; shift
    local out="{\"event\":\"$(seren_json_escape_str "$ev")\""
    while [ $# -gt 1 ]; do
        local k="$1" v="$2"; shift 2
        case "$v" in
            ''|*[!0-9-]*) out="$out,\"$(seren_json_escape_str "$k")\":\"$(seren_json_escape_str "$v")\"" ;;
            *)            out="$out,\"$(seren_json_escape_str "$k")\":$v" ;;
        esac
    done
    printf '%s}\n' "$out" >> "$SEREN_EVENTS_FILE" 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────
# Platform detection
# ─────────────────────────────────────────────────────────────
# Sets these globals (read by everyone downstream):
#   PLATFORM        — "xavier" or "nano" (which platform module to source)
#   JP_FAMILY       — "jp5" or "jp6"
#   PLATFORM_TAG    — "xavier" or "orin" (artifact filename suffix from build-prebuilts)
#   RELEASE_SUFFIX  — "xavier" or "nano"  (release tag suffix on GitHub)
#   CUDA_ARCH       — "72" (Xavier/Volta) or "87" (Orin/Ampere)
#   TORCH_ARCH_LIST — "7.2" or "8.7"
#   PYTORCH_VERSION — "2.1.0" or "2.3.1"
#   TORCHVISION_VERSION — "0.16.0" or "0.18.1"
#   KERNEL_VER      — `uname -r`
# ─────────────────────────────────────────────────────────────
# detect_platform — figure out which node we're on.
#
# $SEREN_PLATFORM (or --platform) OVERRIDES EVERYTHING. That escape hatch is
# not a nicety: the Spark heuristics below are written from its spec, not from
# a machine I could test on, and an installer that cannot be told what it is
# running on is a bad time on hardware new enough to fool detection.
#
# Jetsons announce themselves in /etc/nv_tegra_release (R35 = Xavier/jp5,
# R36 = Orin Nano/jp6). The DGX Spark does NOT have that file at all — see
# spark/foundation.sh — so it needs an entirely separate path, which is why
# spark/ sat unreachable: detect_platform had no case for it and every run
# died in the *) branch before dispatch.
# ─────────────────────────────────────────────────────────────
detect_platform() {
    local jp_release=""
    if [ -f /etc/nv_tegra_release ]; then
        jp_release=$(head -1 /etc/nv_tegra_release | grep -oP 'R\d+' | head -1)
    fi

    # -- explicit override, checked first and trusted completely -------------
    if [ -n "${SEREN_PLATFORM:-}" ]; then
        case "$SEREN_PLATFORM" in
            xavier|nano|spark)
                info "Platform forced to '$SEREN_PLATFORM' (override)"
                _set_platform_vars "$SEREN_PLATFORM" && return 0
                ;;
            *)
                fail "Unknown --platform '$SEREN_PLATFORM' (expected: xavier, nano, spark)"
                return 1
                ;;
        esac
    fi

    # -- not a Tegra board? it may be a Spark -------------------------------
    if [ -z "$jp_release" ] && _looks_like_spark; then
        info "Detected DGX Spark (no /etc/nv_tegra_release, GB10-class GPU)"
        _set_platform_vars spark && return 0
    fi

    case "$jp_release" in
        R35) _set_platform_vars xavier ;;
        R36) _set_platform_vars nano   ;;
        *)
            fail "Could not detect a supported platform."
            fail "  /etc/nv_tegra_release: ${jp_release:-absent}"
            fail "  Expected R35 (Xavier/jp5), R36 (Orin Nano/jp6), or a DGX Spark."
            fail "  Force it with:  --platform xavier|nano|spark"
            return 1
            ;;
    esac
    return 0
}

# _looks_like_spark — best-effort DGX Spark detection.
#
# UNVERIFIED: written from the Spark's spec and spark/foundation.sh, not from a
# machine anyone has run this on. Any single signal here could be wrong on real
# hardware, which is exactly why --platform spark exists and is checked first.
# If this function guesses wrong in either direction, the override is the fix
# and this function is the bug — please report what your Spark actually says.
#
# Signals, any one of which is enough:
#   - device-tree model names the board (Grace/ARM variants)
#   - nvidia-smi reports a GB10 / Blackwell GPU
#   - DMI product name mentions Spark or DGX
_looks_like_spark() {
    local model=""
    if [ -r /proc/device-tree/model ]; then
        model="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || true)"
    fi
    case "$model" in
        *[Ss]park*|*GB10*) return 0 ;;
    esac

    if command -v nvidia-smi >/dev/null 2>&1; then
        local gpu
        gpu="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || true)"
        case "$gpu" in
            *GB10*|*Blackwell*) return 0 ;;
        esac
    fi

    local dmi=/sys/devices/virtual/dmi/id/product_name
    if [ -r "$dmi" ]; then
        case "$(cat "$dmi" 2>/dev/null || true)" in
            *[Ss]park*|*DGX*) return 0 ;;
        esac
    fi

    return 1
}

# _set_platform_vars — single place where per-platform constants live, so the
# override path and the auto-detect path can't drift apart.
_set_platform_vars() {
    case "$1" in
        xavier)
            PLATFORM="xavier";  JP_FAMILY="jp5";  PLATFORM_TAG="xavier"
            RELEASE_SUFFIX="xavier"
            CUDA_ARCH="72";     TORCH_ARCH_LIST="7.2"
            PYTORCH_VERSION="2.1.0";  TORCHVISION_VERSION="0.16.0"
            ;;
        nano)
            PLATFORM="nano";    JP_FAMILY="jp6";  PLATFORM_TAG="orin"
            RELEASE_SUFFIX="nano"
            CUDA_ARCH="87";     TORCH_ARCH_LIST="8.7"
            PYTORCH_VERSION="2.3.1";  TORCHVISION_VERSION="0.18.1"
            ;;
        spark)
            # TENTATIVE, and flagged as such in spark/foundation.sh too:
            # Blackwell GB10 compute capability is believed to be 12.0 (arch
            # 120). The spark/ modules don't currently read these, so a wrong
            # value here is cosmetic until something does - but fix it rather
            # than trust it. Torch versions deliberately left empty: JetPack 7's
            # shipping versions aren't known to me, and an invented pin is worse
            # than an obviously absent one.
            PLATFORM="spark";   JP_FAMILY="jp7";  PLATFORM_TAG="spark"
            RELEASE_SUFFIX="spark"
            CUDA_ARCH="120";    TORCH_ARCH_LIST="12.0"
            PYTORCH_VERSION="";       TORCHVISION_VERSION=""
            ;;
        *)
            fail "_set_platform_vars: unknown platform '$1'"
            return 1
            ;;
    esac
    KERNEL_VER=$(uname -r)
    return 0
}

# ─────────────────────────────────────────────────────────────
# Phase tracking
# ─────────────────────────────────────────────────────────────
# State file is per-script-run, set by seren-setup.sh as $STATE_FILE.
# Service phases (llama/kokoro/etc) are NOT tracked — they always re-run
# when explicitly flagged. Only foundation phases use phase_*.
ensure_jq() {
    if ! command -v jq &>/dev/null; then
        sudo apt-get install -y jq >/dev/null 2>&1 || {
            sudo apt-get update >/dev/null 2>&1
            sudo apt-get install -y jq
        }
    fi
}

phase_done() { jq -r ".\"$1\" // false" "$STATE_FILE"; }
phase_mark() {
    local key="$1"
    local tmp; tmp="$(mktemp)"
    jq ".\"$key\" = true" "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}
phase_skip_if_done() {
    if [ "$(phase_done "$1")" = "true" ]; then
        info "Phase '$1' already complete — skipping (delete $STATE_FILE to redo)"
        return 0
    fi
    return 1
}

# Foundation phase wrapper — respects state tracking
run_phase() {
    local key="$1"; shift
    local label="$1"; shift
    if phase_skip_if_done "$key"; then
        seren_event phase_skip key "$key" label "$label"
        return 0
    fi
    seren_event phase_start key "$key" label "$label" tracked true
    log "▶ $label"
    "$@"
    phase_mark "$key"
    log "✓ $label"
    seren_event phase_done key "$key" label "$label"
}

# Service phase wrapper — ALWAYS runs, never tracked
# Used for llama/kokoro/comfy/chroma/coral installs because user explicitly
# asked for them — re-installing is "make sure it's there" not "skip work".
run_service() {
    local label="$1"; shift
    # tracked=false is the honest bit a UI needs: unlike foundation phases,
    # these ALWAYS re-run. A checkbox reading "[x] llama" must not imply
    # "ensure it's there" when it means "reinstall, possibly a long build".
    seren_event phase_start label "$label" tracked false
    log "▶ $label (always reinstalls)"
    "$@"
    log "✓ $label"
    seren_event phase_done label "$label"
}

# ─────────────────────────────────────────────────────────────
# Max power mode (shared by Xavier and Nano)
# ─────────────────────────────────────────────────────────────
# Sets nvpmodel mode 0 (MAXN) and locks all clocks via jetson_clocks.
# Default: ON. Skipped if SKIP_MAX_POWER=true (set by --no-max-power flag).
# Drops a systemd oneshot to re-apply at every boot, since both settings
# revert on reboot.
#
# WARNING for callers: MAXN draws full TDP. Orin Nano Super at MAXN draws
# ~25W and WILL thermal throttle without active cooling. Xavier AGX at
# MAXN draws ~30W and needs the heatsink fan (which the dev kit ships with).
phase_max_power() {
    if [ "${SKIP_MAX_POWER:-false}" = "true" ]; then
        info "Max power mode skipped (--no-max-power)"
        return 0
    fi

    if ! command -v nvpmodel &>/dev/null; then
        warn "nvpmodel not found — not a Jetson? Skipping max power phase."
        return 0
    fi

    log "Setting nvpmodel mode 0 (MAXN)..."
    sudo nvpmodel -m 0 || warn "nvpmodel -m 0 failed — continuing anyway"

    if command -v jetson_clocks &>/dev/null; then
        log "Locking clocks via jetson_clocks..."
        sudo jetson_clocks || warn "jetson_clocks failed — continuing anyway"
    else
        warn "jetson_clocks not found — clocks will scale dynamically"
    fi

    # Best-effort fan check — warn if MAXN on a Jetson with no detectable fan
    local fan_rpm=""
    if [ -r /sys/devices/pwm-fan/target_pwm ]; then
        fan_rpm=$(cat /sys/devices/pwm-fan/target_pwm 2>/dev/null || echo "")
    elif [ -r /sys/class/hwmon/hwmon0/fan1_input ]; then
        fan_rpm=$(cat /sys/class/hwmon/hwmon0/fan1_input 2>/dev/null || echo "")
    fi
    if [ -z "$fan_rpm" ] || [ "$fan_rpm" = "0" ]; then
        warn "No active fan detected — MAXN power may cause thermal throttling."
        warn "If perf seems bad after this completes, check temps: cat /sys/class/thermal/thermal_zone*/temp"
    fi

    # Persist across reboots via systemd oneshot
    log "Installing seren-max-power.service for boot persistence..."
    sudo tee /etc/systemd/system/seren-max-power.service > /dev/null << 'EOF'
[Unit]
Description=Seren — Set Jetson to max power mode at boot
After=multi-user.target
DefaultDependencies=no

[Service]
Type=oneshot
ExecStart=/usr/sbin/nvpmodel -m 0
ExecStartPost=/usr/bin/jetson_clocks
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    sudo chmod 644 /etc/systemd/system/seren-max-power.service
    sudo systemctl daemon-reload
    sudo systemctl enable seren-max-power.service
    log "seren-max-power.service installed and enabled for boot"
}

# ─────────────────────────────────────────────────────────────
# GitHub release tag resolution
# ─────────────────────────────────────────────────────────────
PREBUILT_REPO="https://github.com/ChadRoesler/Nvidia_Jetson_Prebuilt"
PREBUILT_API="https://api.github.com/repos/ChadRoesler/Nvidia_Jetson_Prebuilt/releases"

# Caller sets:
#   USER_PREBUILT_TAG — empty for auto-resolve, or pinned tag like "2026.04.29-xavier"
# Sets:
#   PREBUILT_TAG — resolved tag
#   PREBUILT_BASE — full URL prefix for asset downloads
resolve_release_tag() {
    if [ -n "${PREBUILT_TAG:-}" ] && [ -n "${PREBUILT_BASE:-}" ]; then
        return 0   # already resolved this run
    fi

    if [ -n "${USER_PREBUILT_TAG:-}" ]; then
        PREBUILT_TAG="$USER_PREBUILT_TAG"
        PREBUILT_BASE="${PREBUILT_REPO}/releases/download/${PREBUILT_TAG}"
        log "Using user-pinned release tag: $PREBUILT_TAG"
        return 0
    fi

    log "Resolving newest *-${RELEASE_SUFFIX} release from GitHub API..."
    ensure_jq
    command -v curl &>/dev/null || sudo apt-get install -y curl >/dev/null 2>&1

    local response
    response=$(curl -fsSL "$PREBUILT_API" 2>/dev/null) || \
        fail "Could not reach GitHub API at $PREBUILT_API. Pass --tag TAG to skip API lookup."

    PREBUILT_TAG=$(echo "$response" | jq -r --arg suffix "-${RELEASE_SUFFIX}" \
        '[.[] | select(.tag_name | endswith($suffix))] | .[0].tag_name // empty')

    if [ -z "$PREBUILT_TAG" ]; then
        fail "No release found matching *-${RELEASE_SUFFIX}. Check the repo or pin --tag TAG."
        return 1
    fi

    PREBUILT_BASE="${PREBUILT_REPO}/releases/download/${PREBUILT_TAG}"
    log "Resolved: $PREBUILT_TAG"
    return 0
}

# ─────────────────────────────────────────────────────────────
# Sourcing helper for service modules
# ─────────────────────────────────────────────────────────────
# Each service module defines an install_<service> function. The dispatcher
# sources the module and calls that function. This avoids 12 service scripts
# each duplicating "source common, parse args, etc."
source_service() {
    local platform="$1"
    local service="$2"
    local script_dir="$3"
    local svc_path="${script_dir}/${platform}/${service}.sh"
    if [ ! -f "$svc_path" ]; then
        fail "Service module not found: $svc_path"
        return 1
    fi
    # shellcheck disable=SC1090
    source "$svc_path"
}

# ─────────────────────────────────────────────────────────────
# Venv helpers — one venv per Python service
# ─────────────────────────────────────────────────────────────
# Convention: real venv lives at /mnt/nvme/seren-venvs/{service}/ when NVMe
# is available, else at /home/$TARGET_USER/seren-venvs/{service}/. Either way,
# /home/$TARGET_USER/seren-venvs/{service} exists (as a symlink to NVMe or
# as the real dir) so users have one consistent path to invoke.
#
# Service scripts use these helpers instead of pip-installing into ~/.local:
#
#   ensure_venv kokoro
#   venv_pip kokoro install fastapi uvicorn ...
#   venv_python kokoro -c "import kokoro"
#
# Start scripts later invoke ~/seren-venvs/{service}/bin/python directly.

# Resolve the canonical venv root (NVMe-backed if available, home otherwise)
_seren_venv_root() {
    if [ -d /mnt/nvme ]; then
        echo "/mnt/nvme/seren-venvs"
    else
        echo "/home/$TARGET_USER/seren-venvs"
    fi
}

# Path to a specific service's venv (always under home for invocation)
_seren_venv_path() {
    echo "/home/$TARGET_USER/seren-venvs/$1"
}

# Create the venv for a given service if it doesn't exist.
# Idempotent: re-running just verifies the venv is valid.
#
# Subtlety: `python3.10 -m venv` refuses to write to a symlink target. So
# we create the venv at $real_venv (the actual NVMe-backed path), then
# symlink the home path to it. Users invoke ~/seren-venvs/{svc}/bin/python
# and the symlink resolves transparently.
ensure_venv() {
    local service="$1"
    local venv_root; venv_root="$(_seren_venv_root)"
    local home_venvs="/home/$TARGET_USER/seren-venvs"
    local venv_path="$home_venvs/$service"
    local real_venv="$venv_root/$service"

    sudo -u "$TARGET_USER" mkdir -p "$venv_root" "$home_venvs"

    # If venv_path exists as a real dir (not a symlink) AND we want to back
    # it with NVMe, migrate it.
    if [ "$venv_root" != "$home_venvs" ] \
       && [ -d "$venv_path" ] && [ ! -L "$venv_path" ] \
       && [ ! -d "$real_venv" ]; then
        log "Migrating $venv_path → $real_venv"
        sudo -u "$TARGET_USER" mv "$venv_path" "$real_venv"
    fi

    # Create venv at the real path (where python -m venv can actually write)
    if [ ! -x "$real_venv/bin/python" ] && [ ! -x "$venv_path/bin/python" ]; then
        # Pick the python interpreter. Default python3.10 (Jetson convention),
        # override via PYTHON_BIN env var (NUC + future cross-platform installs).
        local python_bin="${PYTHON_BIN:-python3.10}"
        if ! command -v "$python_bin" &>/dev/null; then
            fail "ensure_venv: $python_bin not found on PATH (set PYTHON_BIN to override)"
            return 1
        fi
        log "Creating venv at $real_venv (using $python_bin)"
        # Make sure parent exists but the venv path itself does NOT
        sudo -u "$TARGET_USER" mkdir -p "$(dirname "$real_venv")"
        sudo -u "$TARGET_USER" rm -rf "$real_venv"   # in case of partial junk
        sudo -u "$TARGET_USER" "$python_bin" -m venv "$real_venv"
        sudo -u "$TARGET_USER" "$real_venv/bin/python" -m pip install --upgrade pip wheel setuptools
    else
        log "Venv exists: $real_venv"
    fi

    # Set up the home symlink if the venv lives elsewhere
    if [ "$venv_root" != "$home_venvs" ]; then
        if [ ! -e "$venv_path" ]; then
            sudo -u "$TARGET_USER" ln -s "$real_venv" "$venv_path"
        elif [ -L "$venv_path" ]; then
            local current_target; current_target=$(readlink "$venv_path")
            if [ "$current_target" != "$real_venv" ]; then
                warn "Symlink $venv_path points to $current_target, expected $real_venv — leaving alone"
            fi
        fi
    fi
}

# Run pip in a service's venv. Forwards all args after the service name.
venv_pip() {
    local service="$1"; shift
    local venv_path; venv_path="$(_seren_venv_path "$service")"
    sudo -u "$TARGET_USER" "$venv_path/bin/python" -m pip "$@"
}

# Run python in a service's venv. Forwards all args after the service name.
venv_python() {
    local service="$1"; shift
    local venv_path; venv_path="$(_seren_venv_path "$service")"
    sudo -u "$TARGET_USER" "$venv_path/bin/python" "$@"
}

# ═════════════════════════════════════════════════════════════
# Manifest writers — ~/.seren/{node,services/<name>}.json
# ═════════════════════════════════════════════════════════════
#
# Each service install calls write_service_manifest at the end. The node
# manifest is written once during foundation Phase 1.
#
# Manifests are the agent's source of truth for "what's installed on this
# box" — replacing fragile directory probing. Each manifest has:
#   - Well-known fields (port, endpoint, paths, lifecycle scripts)
#   - serviceSpecific{} sub-object for service-tunable settings + advanced
#     user customization. The agent ignores serviceSpecific contents; tools
#     that know about a specific service can use them.
#
# Schema version starts at 1. When fields change, bump the version and add
# migration logic in the agent's loader. NEVER silently change field
# meanings within a schema version.
#
# Usage:
#   write_service_manifest "whisper" \
#       implementation=faster-whisper \
#       port=8081 \
#       endpoint=/v1/audio/transcriptions \
#       start_script="$USER_HOME/start_whisper.sh" \
#       stop_script="$USER_HOME/stop_whisper.sh" \
#       pid_path="$USER_HOME/seren-logs/whisper.pid" \
#       log_path="$USER_HOME/seren-logs/whisper.log" \
#       venv_path="$USER_HOME/seren-venvs/whisper" \
#       --service-specific model="$WHISPER_MODEL" \
#       --service-specific device=cuda \
#       --service-specific compute_type=int8_float16

# Internal: JSON-escape a value. Handles backslashes, quotes, newlines.
# Doesn't try to handle arbitrary unicode — that'd need a proper JSON
# encoder. For our use (paths, identifiers, version strings) this is fine.
_seren_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"      # backslashes first
    s="${s//\"/\\\"}"      # quotes
    s="${s//$'\n'/\\n}"    # newlines
    s="${s//$'\r'/\\r}"    # carriage returns
    s="${s//$'\t'/\\t}"    # tabs
    printf '%s' "$s"
}

_seren_manifest_dir() {
    if [ -z "${USER_HOME:-}" ]; then
        echo "ERROR: USER_HOME is empty — manifest helpers can't proceed." >&2
        echo "       This is usually a bug in seren-setup.sh's init order." >&2
        return 1
    fi
    if [ -z "${TARGET_USER:-}" ]; then
        echo "ERROR: TARGET_USER is empty — manifest helpers can't proceed." >&2
        return 1
    fi
    local d="$USER_HOME/.seren"
    sudo -u "$TARGET_USER" mkdir -p "$d/services"
    echo "$d"
}

# Atomic JSON write: writes to a tempfile, then mv. Prevents partial reads.
_seren_atomic_write() {
    local target="$1"; shift
    local content="$1"
    local tmp; tmp=$(sudo -u "$TARGET_USER" mktemp "${target}.XXXXXX")
    echo "$content" | sudo -u "$TARGET_USER" tee "$tmp" > /dev/null
    sudo -u "$TARGET_USER" mv "$tmp" "$target"
}

write_service_manifest() {
    local service="$1"; shift
    local manifest_dir; manifest_dir=$(_seren_manifest_dir)
    local target="$manifest_dir/services/${service}.json"

    # Parse k=v args. Recognize --service-specific to switch into the
    # serviceSpecific sub-object. Top-level fields come first, then
    # --service-specific marker, then nested fields.
    local -a top_keys=()
    local -a top_vals=()
    local -a spec_keys=()
    local -a spec_vals=()
    local in_specific=false

    while [ $# -gt 0 ]; do
        if [ "$1" = "--service-specific" ]; then
            in_specific=true
            shift
            continue
        fi
        local kv="$1"; shift
        local k="${kv%%=*}"
        local v="${kv#*=}"
        if $in_specific; then
            spec_keys+=("$k")
            spec_vals+=("$v")
        else
            top_keys+=("$k")
            top_vals+=("$v")
        fi
    done

    # Build JSON manually. Keeps us off jq for write (jq is fine for read,
    # but writing structured JSON via jq from bash is nontrivial). The
    # escape function handles the common cases.
    local now; now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local json='{'
    json+="\"service\":\"$(_seren_json_escape "$service")\","

    local i
    for i in "${!top_keys[@]}"; do
        local k="${top_keys[$i]}"
        local v="${top_vals[$i]}"
        # Numeric values (port, schema_version, etc.) get unquoted output.
        # Crude detection: if it's all digits, treat as number.
        if [[ "$v" =~ ^[0-9]+$ ]]; then
            json+="\"$(_seren_json_escape "$k")\":${v},"
        else
            json+="\"$(_seren_json_escape "$k")\":\"$(_seren_json_escape "$v")\","
        fi
    done

    json+="\"installed_at\":\"${now}\","
    json+='"schema_version":1,'

    # serviceSpecific sub-object — always present, even if empty
    json+='"serviceSpecific":{'
    local first=true
    for i in "${!spec_keys[@]}"; do
        local k="${spec_keys[$i]}"
        local v="${spec_vals[$i]}"
        $first || json+=','
        first=false
        if [[ "$v" =~ ^[0-9]+$ ]]; then
            json+="\"$(_seren_json_escape "$k")\":${v}"
        else
            json+="\"$(_seren_json_escape "$k")\":\"$(_seren_json_escape "$v")\""
        fi
    done
    json+='}}'

    # Pretty-print via jq if available — easier for humans to read/edit
    if command -v jq &>/dev/null; then
        local pretty; pretty=$(echo "$json" | jq . 2>/dev/null)
        if [ -n "$pretty" ]; then
            json="$pretty"
        fi
    fi

    _seren_atomic_write "$target" "$json"
    log "Manifest written: ~/.seren/services/${service}.json"
}

# Node-level manifest. Called by foundation Phase 1 after hostname + ip
# settle. Uses host introspection to fill in fields rather than caller args.
write_node_manifest() {
    local manifest_dir; manifest_dir=$(_seren_manifest_dir)
    local target="$manifest_dir/node.json"

    local hostname; hostname=$(hostname)
    # All non-loopback IPv4 addresses, comma-separated for the JSON array
    local ips; ips=$(ip -4 -o addr show 2>/dev/null \
        | awk '{print $4}' \
        | cut -d'/' -f1 \
        | grep -v '^127\.' \
        | head -5)

    local platform="${1:-unknown}"     # caller passes "xavier" or "nano"
    local jetpack="${2:-unknown}"      # "R35" or "R36"
    local cuda_arch="${3:-unknown}"    # "72" or "87"
    local cuda_version="${4:-unknown}"

    local total_kb; total_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
    local mem_gb=$(( total_kb / 1024 / 1024 ))
    local cores; cores=$(nproc 2>/dev/null || echo 0)
    local now; now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Build the IP array
    local ip_array='['
    local first=true
    while IFS= read -r ip; do
        [ -z "$ip" ] && continue
        $first || ip_array+=','
        first=false
        ip_array+="\"$(_seren_json_escape "$ip")\""
    done <<< "$ips"
    ip_array+=']'

    local json='{'
    json+="\"hostname\":\"$(_seren_json_escape "$hostname")\","
    json+="\"ip_addresses\":${ip_array},"
    json+="\"platform\":\"$(_seren_json_escape "$platform")\","
    json+="\"jetpack_release\":\"$(_seren_json_escape "$jetpack")\","
    json+="\"cuda_arch\":\"$(_seren_json_escape "$cuda_arch")\","
    json+="\"cuda_version\":\"$(_seren_json_escape "$cuda_version")\","
    json+="\"unified_memory_gb\":${mem_gb},"
    json+="\"cpu_cores\":${cores},"
    json+="\"installed_at\":\"${now}\","
    json+='"schema_version":1,'
    json+='"nodeSpecific":{}}'

    if command -v jq &>/dev/null; then
        local pretty; pretty=$(echo "$json" | jq . 2>/dev/null)
        if [ -n "$pretty" ]; then
            json="$pretty"
        fi
    fi

    _seren_atomic_write "$target" "$json"
    log "Manifest written: ~/.seren/node.json"
}

# ═════════════════════════════════════════════════════════════
# Agent install — shared between Xavier and Nano
# ═════════════════════════════════════════════════════════════
#
# The Seren agent is the per-Jetson management plane. It's a tiny FastAPI
# app exposing /api/v1/{system,service/*}/* endpoints, manifest-driven,
# bearer-token authed.
#
# Why shared install logic: the agent doesn't touch CUDA or platform-
# specific kernels. Same Python deps, same systemd unit, same lifecycle
# on both Xavier and Nano. Platform agent.sh files just wrap this.
#
# Inputs (passed explicitly to keep this self-contained):
#   $1 — TARGET_USER (e.g. the login you run Seren as)
#   $2 — SCRIPT_DIR (location of seren-agent.tar.gz to extract from)
#
# Side effects:
#   - Extracts seren-agent.tar.gz → $USER_HOME/seren-agent/agent/...
#   - Creates ~/seren-venvs/agent venv with fastapi, httpx, uvicorn
#   - Installs /etc/systemd/system/seren-agent.service (Type=simple,
#     Restart=on-failure, After=network-online.target)
#   - Installs ~/start_agent.sh and ~/stop_agent.sh wrappers around
#     systemctl (so the manifest's lifecycle scripts work uniformly)
#   - Writes ~/.seren/services/agent.json manifest
#   - Enables (but does NOT start) the service — caller can start later
#     via systemctl or via the agent's own /api/v1/service/agent/start
#     endpoint after a reboot
install_agent_common() {
    local target_user="$1"
    local script_dir="$2"
    local user_home="/home/$target_user"

    log "▶ Service — Seren Agent (FastAPI management plane)"

    # ── Verify tarball exists before doing anything else ──
    local tarball="$script_dir/seren-agent.tar.gz"
    if [ ! -f "$tarball" ]; then
        fail "seren-agent.tar.gz not found at $tarball"
        fail "Build it from the agent/ source tree:"
        fail "  cd $script_dir && tar czf seren-agent.tar.gz agent/"
        return 1
    fi
    # Sanity-check the tarball isn't corrupted
    if ! tar tzf "$tarball" > /dev/null 2>&1; then
        fail "seren-agent.tar.gz is corrupted or not a valid gzip tarball"
        return 1
    fi
    # Sanity-check it contains agent/__init__.py (the package entry)
    if ! tar tzf "$tarball" | grep -q '^agent/__init__.py$'; then
        fail "seren-agent.tar.gz is missing agent/__init__.py — wrong layout?"
        fail "Expected entries like: agent/__init__.py, agent/app.py, ..."
        return 1
    fi

    # ── Extract agent code ──
    # Land at $user_home/seren-agent/agent/ (note the nested 'agent/' is the
    # Python package; the outer 'seren-agent/' is just the install dir).
    local install_dir="$user_home/seren-agent"
    log "Extracting agent code to $install_dir..."
    sudo -u "$target_user" mkdir -p "$install_dir"
    # Wipe any previous agent/ inside the install dir so old files don't
    # linger if the package layout changed across versions. We do NOT wipe
    # the install_dir itself — anything outside agent/ stays put.
    sudo -u "$target_user" rm -rf "$install_dir/agent"
    sudo -u "$target_user" tar xzf "$tarball" -C "$install_dir"
    if [ ! -f "$install_dir/agent/__init__.py" ]; then
        fail "Extraction succeeded but $install_dir/agent/__init__.py is missing"
        return 1
    fi

    # ── Venv + deps ──
    ensure_venv agent
    log "Installing agent Python deps into venv (fastapi, httpx, uvicorn)..."
    venv_pip agent install \
        fastapi \
        "httpx>=0.27" \
        "uvicorn[standard]" \
        || { fail "agent dep install failed"; return 1; }

    # ── Verify agent module imports cleanly in the venv ──
    # If this fails, the deploy is broken — better to know now than at
    # systemd start time when it's noisier to diagnose.
    log "Verifying agent imports..."
    if ! sudo -u "$target_user" \
        env PYTHONPATH="$install_dir" \
        "$user_home/seren-venvs/agent/bin/python" \
        -c "from agent import __version__; print(f'agent version {__version__} imports OK')"
    then
        fail "agent module fails to import — deploy is broken"
        return 1
    fi

    # ── Make sure secrets exist (defensive) ──
    # foundation Phase 1 normally generates the token, but if someone runs
    # the agent install standalone we want to make sure auth is configured.
    # Agent will run without auth if no token, but with a loud warning header.
    if [ ! -f "$user_home/.seren/secrets.json" ]; then
        if [ -f "$script_dir/seren-secrets.sh" ]; then
            log "No agent token found — generating one..."
            bash "$script_dir/seren-secrets.sh" -u "$target_user"
        else
            warn "No agent token AND seren-secrets.sh missing. Agent will run"
            warn "with auth DISABLED (responses will include X-Seren-Auth: disabled)."
            warn "Manually generate: bash $script_dir/seren-secrets.sh -u $target_user"
        fi
    fi

    # ── Logs dir (for systemd journald spillover and manual inspection) ──
    sudo -u "$target_user" mkdir -p "$user_home/seren-logs"

    # ── start_agent.sh / stop_agent.sh wrappers ──
    # The agent is the one service we run via systemd (rather than the
    # start_<service>.sh + PID file convention) because it's infrastructure
    # — auto-restart on crash and auto-start at boot matter here. But we
    # still ship wrapper scripts so the agent's manifest can declare
    # start_script/stop_script paths uniformly (the agent's own
    # /api/v1/service/agent/start endpoint subprocesses them through
    # the lifecycle module).
    sudo -u "$target_user" tee "$user_home/start_agent.sh" > /dev/null << 'STARTEOF'
#!/bin/bash
# start_agent.sh — bring up the Seren agent via systemd.
# Agent's manifest declares this as its start_script for self-management.
sudo systemctl start seren-agent.service
echo "seren-agent: $(systemctl is-active seren-agent.service)"
STARTEOF
    sudo -u "$target_user" chmod +x "$user_home/start_agent.sh"

    sudo -u "$target_user" tee "$user_home/stop_agent.sh" > /dev/null << 'STOPEOF'
#!/bin/bash
# stop_agent.sh — stop the Seren agent via systemd.
sudo systemctl stop seren-agent.service
echo "seren-agent: $(systemctl is-active seren-agent.service)"
STOPEOF
    sudo -u "$target_user" chmod +x "$user_home/stop_agent.sh"

    # ── systemd unit ──
    log "Installing seren-agent.service..."
    sudo tee /etc/systemd/system/seren-agent.service > /dev/null << EOF
[Unit]
Description=Seren — per-Jetson management plane (FastAPI agent)
Documentation=https://github.com/ChadRoesler (seren-v5/agent)
After=network-online.target
Wants=network-online.target
# Don't pile up restart attempts on a permanently-broken install:
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
User=$target_user
WorkingDirectory=$install_dir
Environment="PYTHONPATH=$install_dir"
Environment="AGENT_PORT=7777"
Environment="AGENT_HOST=0.0.0.0"
ExecStart=$user_home/seren-venvs/agent/bin/python -m agent.app
Restart=on-failure
RestartSec=5
# Forward stdout/stderr to journald (queryable via journalctl -u seren-agent)
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    sudo chmod 644 /etc/systemd/system/seren-agent.service
    sudo systemctl daemon-reload
    sudo systemctl enable seren-agent.service
    log "seren-agent.service installed + enabled for boot"

    # ── Sudoers entry — let the target user start/stop the agent without password ──
    # The wrapper scripts above use `sudo systemctl ...` and would otherwise
    # prompt for a password every time. Limit the sudoers grant to the exact
    # commands we need.
    sudo tee /etc/sudoers.d/seren-agent > /dev/null << EOF
# Generated by install_agent_common() — allow $target_user to manage seren-agent.service
$target_user ALL=(root) NOPASSWD: /bin/systemctl start seren-agent.service
$target_user ALL=(root) NOPASSWD: /bin/systemctl stop seren-agent.service
$target_user ALL=(root) NOPASSWD: /bin/systemctl restart seren-agent.service
$target_user ALL=(root) NOPASSWD: /bin/systemctl status seren-agent.service
$target_user ALL=(root) NOPASSWD: /usr/bin/systemctl start seren-agent.service
$target_user ALL=(root) NOPASSWD: /usr/bin/systemctl stop seren-agent.service
$target_user ALL=(root) NOPASSWD: /usr/bin/systemctl restart seren-agent.service
$target_user ALL=(root) NOPASSWD: /usr/bin/systemctl status seren-agent.service
# Reboot — for the agent's POST /api/v1/system/reboot and /reboot/cancel endpoints.
# /sbin/shutdown -r +N    schedules a reboot N minutes out (dashboard fires +1)
# /sbin/shutdown -c       cancels a scheduled reboot
# Wildcards on the time argument are intentional — restricts to -r and -c
# specifically (not -h halt, not -P poweroff). The N minutes is bounded
# by the agent's input clamp (0..60) so wildcard doesn't widen the blast.
$target_user ALL=(root) NOPASSWD: /sbin/shutdown -r *
$target_user ALL=(root) NOPASSWD: /sbin/shutdown -c
EOF
    sudo chmod 440 /etc/sudoers.d/seren-agent
    sudo visudo -cf /etc/sudoers.d/seren-agent > /dev/null || {
        fail "Sudoers entry failed validation — aborting"
        sudo rm -f /etc/sudoers.d/seren-agent
        return 1
    }

    # ── Write manifest ──
    # Note: no pid_path declared. Agent is systemd-managed; lifecycle helpers
    # detect missing pid_path and fall back to systemctl is-active. (See
    # lifecycle.py — to be enhanced in a follow-up if needed; for now status
    # checks return 'pid: None' for the agent which is fine.)
    write_service_manifest "agent" \
        implementation=seren-agent \
        port=7777 \
        endpoint=/api/v1/system/ping \
        start_script="$user_home/start_agent.sh" \
        stop_script="$user_home/stop_agent.sh" \
        log_path="$user_home/seren-logs/agent.log" \
        venv_path="$user_home/seren-venvs/agent" \
        repo_path="$install_dir" \
        --service-specific systemd_unit=seren-agent.service \
        --service-specific managed_by=systemd

    # ── Print next steps ──
    log "Seren Agent installed."
    log "  Code:    $install_dir/agent/"
    log "  Venv:    ~/seren-venvs/agent"
    log "  Service: seren-agent.service (enabled at boot, NOT yet started)"
    log ""
    log "Start the agent now with:"
    log "  sudo systemctl start seren-agent"
    log "Then verify:"
    log "  curl http://localhost:7777/api/v1/system/ping"
    log "  curl http://localhost:7777/  # info page"
    log "  sudo journalctl -u seren-agent -f"
    log ""
    log "Auth token (give this to the C# RuntimeHost / chat app):"
    if [ -f "$user_home/.seren/secrets.json" ]; then
        log "  $(jq -r .agent_token "$user_home/.seren/secrets.json" 2>/dev/null || echo '(jq unavailable; cat ~/.seren/secrets.json)')"
    else
        warn "  No token file at ~/.seren/secrets.json — auth is DISABLED"
    fi
    log "✓ Service — Seren Agent"
}
