#!/bin/bash
# ══════════════════════════════════════════════════════════════
# common.sh - Shared helpers for seren-prepare-node.sh
#
# Sourced by seren-prepare-node.sh and platform modules.
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
#
# `2>/dev/null >&3`, IN THAT ORDER, and the order is the whole point. Bash
# applies redirections left to right, so `>&3 2>/dev/null` fails on fd 3 and
# reports "Bad file descriptor" to a stderr that 2>/dev/null has not claimed
# yet - printing the exact noise it was written to suppress, on every single
# log line, any time fd 3 is not set up. Claim stderr first, then try fd 3.
log()  { echo -e "${GREEN}[SEREN]${NC} $1" 2>/dev/null >&3 || true; echo -e "${GREEN}[SEREN]${NC} $1"; seren_event ok    msg "$1"; }
warn() { echo -e "${YELLOW}[SEREN]${NC} $1" 2>/dev/null >&3 || true; echo -e "${YELLOW}[SEREN]${NC} $1"; seren_event warn  msg "$1"; }
fail() { echo -e "${RED}[SEREN]${NC} $1" 2>/dev/null >&3 || true; echo -e "${RED}[SEREN]${NC} $1"; seren_event error msg "$1"; }
info() { echo -e "${BLUE}[SEREN]${NC} $1" 2>/dev/null >&3 || true; echo -e "${BLUE}[SEREN]${NC} $1"; seren_event info  msg "$1"; }

# ─────────────────────────────────────────────────────────────
# Structured events - the Starwright contract, node-prep flavour
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
# built around - and prep shells out to apt-get, cmake, nvpmodel and pip,
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

# seren_node_flags_from_self - read the DISPATCHER's own accepted flags.
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

    # name:display:description  - coral last, it's the hardware-gated one
    local specs=(
        "llama:llama.cpp:Inference server"
        "kokoro:Kokoro:Text to speech"
        "whisper:Whisper:Speech to text"
        "comfyui:ComfyUI:Image generation"
        "chromadb:ChromaDB:Vector store"
        "msmoe:Ms.MoE Maker:MoE build pipeline"
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
        # Component phases never track state - asking for one means "make sure
        # it's there", which is a reinstall. Foundation is a different animal
        # and no longer runs implicitly at all; see --prep.
        comps="$comps,\"always_reinstalls\":true}"
    done

    printf '{"schema_version":1,"kind":"node"'
    printf ',"platform":%s,"jp_family":%s,"cuda_arch":%s' "$detected" "$fam" "$arch"
    printf ',"hostname":"%s"' "$(seren_json_escape_str "$(hostname 2>/dev/null || echo '')")"
    # Has this MACHINE been prepared before? A front-end needs this to decide
    # whether to OFFER prep or merely allow it - and, more importantly, to stop
    # implying that foundation "runs first and skips when done", which is what
    # the TUI used to say back when the state file lived in the checkout and was
    # therefore missing on every fresh clone.
    #
    # A pure READ. No mkdir, no jq, no sudo: --describe creates nothing, and CI
    # asserts exactly that by running it against a throwaway HOME.
    local prov=false prov_at=null managed=null
    if node_provisioned; then
        prov=true
        local _at; _at="$(seren_state_get _provisioned_at)"
        [ -n "$_at" ] && prov_at="\"$(seren_json_escape_str "$_at")\""
    fi
    # The name seren itself set, if it ever did. Lets a UI say "seren named this
    # box X" instead of guessing whether the current hostname was deliberate.
    local _hn; _hn="$(seren_state_get _hostname_set_to)"
    [ -n "$_hn" ] && managed="\"$(seren_json_escape_str "$_hn")\""
    printf ',"provisioned":%s' "$prov"
    printf ',"provisioned_at":%s' "$prov_at"
    printf ',"hostname_managed":%s' "$managed"
    printf ',"components":[%s]' "$comps"
    # DERIVED, not hardcoded. This used to claim ["prebuilts","build"] for every
    # platform, which was a lie about the Spark - it has no build.sh - so a UI
    # reading this offered "build from source" for a path that does not exist.
    # Same rule as flags and components: report what is actually on disk.
    local modes='"prebuilts"'
    if [ "$detected" != "null" ] && [ -f "$script_dir/$PLATFORM/build.sh" ]; then
        modes="$modes,\"build\""
    fi
    printf ',"modes":[%s]' "$modes"
    printf ',"platforms":["xavier","nano","spark","host"]'
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
#   PLATFORM        - "xavier", "nano" or "spark" (which platform module to source)
#   JP_FAMILY       - "jp5", "jp6" or "jp7"
#   PLATFORM_TAG    - "xavier", "orin" or "spark" (the artifact/folder tag the
#                     build script uses; note nano -> orin)
#   RELEASE_SUFFIX  - "<platform_tag>-<jp>": the platform folder name, which is
#                     what a release tag ends in (20260916_orin-jp6)
#   CUDA_ARCH       - "72" (Xavier/Volta), "87" (Orin/Ampere), "121" (GB10)
#   TORCH_ARCH_LIST - "7.2", "8.7", "12.1"
#   PYTORCH_VERSION / TORCHVISION_VERSION - the held baseline the release was
#                     built at (mirrors SerenSystemPrebuilts lib/platform.sh)
#   KERNEL_VER      - `uname -r`
# ─────────────────────────────────────────────────────────────
# detect_platform - figure out which node we're on.
#
# $SEREN_PLATFORM (or --platform) OVERRIDES EVERYTHING. That escape hatch is
# not a nicety: the Spark heuristics below are written from its spec, not from
# a machine I could test on, and an installer that cannot be told what it is
# running on is a bad time on hardware new enough to fool detection.
#
# Jetsons announce themselves in /etc/nv_tegra_release (R35 = Xavier/jp5,
# R36 = Orin Nano/jp6). The DGX Spark does NOT have that file at all - see
# spark/foundation.sh - so it needs an entirely separate path, which is why
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
            xavier|nano|spark|host)
                info "Platform forced to '$SEREN_PLATFORM' (override)"
                _set_platform_vars "$SEREN_PLATFORM" && return 0
                ;;
            *)
                fail "Unknown --platform '$SEREN_PLATFORM' (expected: xavier, nano, spark, host)"
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
        "")
            # No Tegra release and not a Spark. An x86_64 Linux box is a plain
            # HOST - a NUC, a tower, a VM - which runs the Seren services and
            # none of the GPU components. Only x86_64 is assumed: an aarch64
            # board that did not announce itself is more likely a Jetson whose
            # release file went missing than a server, and guessing "host"
            # there would skip its CUDA setup without a word.
            if [ "$(uname -s 2>/dev/null)" = "Linux" ] && [ "$(uname -m 2>/dev/null)" = "x86_64" ]; then
                info "Detected a generic x86_64 Linux host (no Tegra release, not a Spark)"
                _set_platform_vars host && return 0
            fi
            fail "Could not detect a supported platform."
            fail "  /etc/nv_tegra_release: absent, and this is not an x86_64 Linux host."
            fail "  Force it with:  --platform xavier|nano|spark|host"
            return 1
            ;;
        *)
            fail "Could not detect a supported platform."
            fail "  /etc/nv_tegra_release: $jp_release"
            fail "  Expected R35 (Xavier/jp5), R36 (Orin Nano/jp6), a DGX Spark, or a generic host."
            fail "  Force it with:  --platform xavier|nano|spark|host"
            return 1
            ;;
    esac
    return 0
}

# seren_host_python_ok [--say|--which] - does this box already have a Python
# the Seren services can run on: 3.10 or newer, built against SQLite 3.35 or
# newer (ChromaDB's floor)? /usr/local first, so a Python node prep installed
# is found before the distro's. --say prints "python3.10 3.10.14, sqlite
# 3.45.1"; --which prints its path. Exit status is the answer either way.
seren_host_python_ok() {
    local mode="${1:-}" cand py out
    for cand in /usr/local/bin/python3.13 /usr/local/bin/python3.12 /usr/local/bin/python3.11 \
                /usr/local/bin/python3.10 python3.13 python3.12 python3.11 python3.10 python3; do
        py="$(command -v "$cand" 2>/dev/null)" || continue
        [ -n "$py" ] || continue
        out="$("$py" -c 'import sys, sqlite3
v = sys.version_info
s = tuple(int(x) for x in sqlite3.sqlite_version.split(".")[:2])
ok = (v.major, v.minor) >= (3, 10) and s >= (3, 35)
print("%s %d.%d.%d, sqlite %s" % (sys.argv[1], v.major, v.minor, v.micro, sqlite3.sqlite_version))
sys.exit(0 if ok else 1)' "$(basename "$py")" 2>/dev/null)" || continue
        case "$mode" in
            --say)   echo "$out" ;;
            --which) echo "$py" ;;
        esac
        return 0
    done
    return 1
}

# _looks_like_spark - best-effort DGX Spark detection.
#
# UNVERIFIED: written from the Spark's spec and spark/foundation.sh, not from a
# machine anyone has run this on. Any single signal here could be wrong on real
# hardware, which is exactly why --platform spark exists and is checked first.
# If this function guesses wrong in either direction, the override is the fix
# and this function is the bug - please report what your Spark actually says.
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

# _set_platform_vars - single place where per-platform constants live, so the
# override path and the auto-detect path can't drift apart.
_set_platform_vars() {
    case "$1" in
        # THE PINS MIRROR SerenSystemPrebuilts lib/platform.sh - the versions
        # the release folders were actually built at. They had drifted: this
        # said torch 2.3.1 / torchvision 0.18.1 for the Nano while the archive
        # holds 2.11.0 / 0.26.0, and left the Spark blank with "CC 120,
        # tentative" while the Spark archive was selftested at sm_121.
        xavier)
            PLATFORM="xavier";  JP_FAMILY="jp5";  PLATFORM_TAG="xavier"
            RELEASE_SUFFIX="xavier-jp5"
            CUDA_ARCH="72";     TORCH_ARCH_LIST="7.2"
            PYTORCH_VERSION="2.1.0";  TORCHVISION_VERSION="0.16.0"
            ;;
        nano)
            PLATFORM="nano";    JP_FAMILY="jp6";  PLATFORM_TAG="orin"
            RELEASE_SUFFIX="orin-jp6"
            CUDA_ARCH="87";     TORCH_ARCH_LIST="8.7"
            PYTORCH_VERSION="2.11.0"; TORCHVISION_VERSION="0.26.0"
            ;;
        spark)
            # GB10 is sm_121 - not the 120 this used to guess. The Spark
            # archive's selftest launches kernels on the real device and asserts
            # the arch list, so this is measured, not read off a spec sheet.
            PLATFORM="spark";   JP_FAMILY="jp7";  PLATFORM_TAG="spark"
            RELEASE_SUFFIX="spark-jp7"
            CUDA_ARCH="121";    TORCH_ARCH_LIST="12.1"
            PYTORCH_VERSION="2.11.0"; TORCHVISION_VERSION="0.26.0"
            ;;
        host)
            # A generic Linux box. JP_FAMILY carries the distro codename (it
            # is what the Jetsons' "jp5" is to them: which base this is), and
            # the release suffix matches SerenSystemPrebuilts' host folders:
            # 20260520_host-focal-x86_64. No CUDA arch and no torch baseline -
            # a host runs the services, not the GPU components.
            local codename=""
            codename="$( . /etc/os-release 2>/dev/null; echo "${VERSION_CODENAME:-${ID:-linux}}" )"
            PLATFORM="host";    JP_FAMILY="${codename:-linux}";  PLATFORM_TAG="host"
            RELEASE_SUFFIX="host-${JP_FAMILY}-$(uname -m 2>/dev/null || echo unknown)"
            CUDA_ARCH="";       TORCH_ARCH_LIST=""
            PYTORCH_VERSION=""; TORCHVISION_VERSION=""
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
# State file is per-script-run, set by seren-prepare-node.sh as $STATE_FILE.
# Service phases (llama/kokoro/etc) are NOT tracked - they always re-run
# when explicitly flagged. Only foundation phases use phase_*.
ensure_jq() {
    if ! command -v jq &>/dev/null; then
        sudo apt-get install -y jq >/dev/null 2>&1 || {
            sudo apt-get update >/dev/null 2>&1
            sudo apt-get install -y jq
        }
    fi
}

# ────────────────────────────────────────────────────────────
# Phase state - WHERE IT LIVES, AND WHY IT MOVED
# ────────────────────────────────────────────────────────────
#
# It used to be $SCRIPT_DIR/.seren-setup.state.json - next to the script, and
# in .gitignore. So "this node is already prepared" was a property of the
# DIRECTORY YOU RAN FROM, not of the machine, and it was missing by default on:
#
#   - a fresh clone (the file is gitignored, so it is never in one)
#   - a second checkout, or the same checkout moved
#   - EVERY .pyz rebuild - the bundle extracts to a path keyed on the
#     archive's mtime+size, so a new build gets a virgin state file
#
# An empty state file means every foundation phase re-runs, and it used to mean
# the hostname phase re-ran too, against a name derived from that invocation's
# service flags. Adding one component to an already-built box therefore renamed
# it. The rename is gone (see --rename in seren-prepare-node.sh), but the
# underlying wrongness was the state location, so that is fixed here: the state
# of a machine belongs ON the machine.
#
# ~/.seren is already the family convention - write_node_manifest puts node.json
# there - so this is the same directory, not a new one to learn.
#
# $SEREN_STATE_FILE overrides, which is what makes this testable: CI asserts
# --describe creates nothing, and a test run must not scribble in a real home.
seren_state_path() {
    if [ -n "${SEREN_STATE_FILE:-}" ]; then
        echo "$SEREN_STATE_FILE"
        return 0
    fi
    local u="${TARGET_USER:-$(id -un 2>/dev/null || echo root)}"
    local home="/home/$u"
    [ "$u" = "root" ] && home="/root"
    echo "$home/.seren/node-state.json"
}

# One-time carry-over from the old per-checkout location, so somebody upgrading
# does not get a re-run of every foundation phase as their reward for pulling.
# Best-effort by design: a failure here costs time, never correctness.
seren_state_migrate() {
    local new="$1" legacy="$2"
    [ -f "$new" ] && return 0
    [ -f "$legacy" ] || return 0
    # An empty-object state file carries no information; copying it would just
    # create the new file and hide a real legacy one nobody has found yet.
    local body; body="$(tr -d '[:space:]' < "$legacy" 2>/dev/null || echo '')"
    [ "$body" = "{}" ] && return 0
    [ -z "$body" ] && return 0
    if cp "$legacy" "$new" 2>/dev/null; then
        info "Migrated phase state: $legacy -> $new"
    fi
    return 0
}

# Create the state file's directory and the file itself. Separate from the read
# helpers on purpose: --describe READS state and must create nothing, so no
# read path is allowed to mkdir.
seren_state_init() {
    local sf="$1"
    local dir; dir="$(dirname "$sf")"
    mkdir -p "$dir" 2>/dev/null || sudo mkdir -p "$dir" 2>/dev/null || true
    if [ ! -w "$dir" ] && [ -n "${TARGET_USER:-}" ]; then
        sudo chown "$TARGET_USER" "$dir" 2>/dev/null || true
    fi
    [ -f "$sf" ] || echo '{}' > "$sf" 2>/dev/null || true
    [ -f "$sf" ] || return 1
    return 0
}

# Has this MACHINE ever completed a full prep run?
#
# Deliberately grep and not jq: this is read to DECIDE whether to prep, which
# happens before ensure_jq has run, and it is read again by --describe, which
# promises to need nothing at all. A dependency here would defeat both.
node_provisioned() {
    local sf; sf="$(seren_state_path)"
    [ -r "$sf" ] || return 1
    grep -q '"_provisioned_at"' "$sf" 2>/dev/null
}

# Read one metadata key out of the state file without jq. Empty if absent.
seren_state_get() {
    local key="$1" sf pair
    sf="$(seren_state_path)"
    [ -r "$sf" ] || return 0
    # grep + parameter expansion rather than a sed capture group: this file is
    # read by --describe, which must work on a box with nothing installed, and
    # the nested quoting a backreference needs here is exactly how this helper
    # first shipped emitting a literal 0x01 byte instead of the value.
    pair="$(grep -o "\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$sf" 2>/dev/null | head -1)"
    [ -n "$pair" ] || return 0
    pair="${pair#*:}"       # drop the key and the colon
    pair="${pair#*\"}"      # drop the opening quote of the value
    echo "${pair%\"*}"      # drop the closing quote
}

# Stamp the machine as prepared. Called once, after foundation completes.
mark_provisioned() {
    local platform="${1:-unknown}"
    local now; now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local tmp; tmp="$(mktemp)"
    local prog='._provisioned_at = $at | ._provisioned_platform = $plat'
    if jq --arg at "$now" --arg plat "$platform" "$prog" "$STATE_FILE" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$STATE_FILE"
        log "Node marked provisioned ($platform) at $now"
    else
        rm -f "$tmp"
        warn "Could not stamp provisioned state in $STATE_FILE"
    fi
}

# Record that WE set the hostname, and to what. Provenance, not just a flag:
# it lets a later run say "seren named this box X" instead of guessing.
mark_hostname_set() {
    local name="$1"
    local now; now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local tmp; tmp="$(mktemp)"
    local prog='._hostname_set_to = $n | ._hostname_set_at = $at'
    if jq --arg n "$name" --arg at "$now" "$prog" "$STATE_FILE" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$STATE_FILE"
    else
        rm -f "$tmp"
    fi
}

# Remember where --install-root pointed, so adding a component later lands
# beside the ones already there without the flag being typed again.
mark_install_root() {
    local root="$1"
    local tmp; tmp="$(mktemp)"
    if jq --arg r "$root" '._install_root = $r' "$STATE_FILE" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$STATE_FILE"
    else
        rm -f "$tmp"
    fi
}

# seren_apps_root - the directory node components are installed under:
# llama.cpp, whisper.cpp, Kokoro-FastAPI and ComfyUI each get a folder in it.
#
#   --install-root DIR         what somebody asked for (SEREN_INSTALL_ROOT)
#   the root a past run named  remembered in the node state
#   /mnt/nvme                  when the NVMe is there - where models and venvs
#                              already go, and for the same reason
#   the user's home            a node with no NVMe
#
# These were hardwired to the home directory, so on a Xavier the binaries and
# repos went onto the 32GB eMMC the NVMe phase exists to keep clear, with
# nowhere to say otherwise. Start/stop scripts, the env file and the manifests
# stay in the home: they are small, and they are how everything else finds a
# component wherever it was put.
seren_apps_root() {
    if [ -n "${SEREN_INSTALL_ROOT:-}" ]; then
        echo "${SEREN_INSTALL_ROOT%/}"
        return 0
    fi
    if [ -n "${SEREN_TEST_HOME:-}" ]; then
        echo "$SEREN_TEST_HOME"
        return 0
    fi
    local saved; saved="$(seren_state_get _install_root)"
    if [ -n "$saved" ]; then
        echo "$saved"
    elif [ -d /mnt/nvme ]; then
        echo "/mnt/nvme"
    else
        echo "/home/$TARGET_USER"
    fi
}

# A node installed before the install root existed has its copy in the home.
# Installing again puts a new one under the root and repoints the start script;
# say that the old one is now dead weight rather than leave it to be found.
seren_note_home_copy() {
    local name="$1" root; root="$(seren_apps_root)"
    local home="/home/$TARGET_USER"
    [ -n "${SEREN_TEST_HOME:-}" ] && home="$SEREN_TEST_HOME"
    if [ "$root" != "$home" ] && [ -e "$home/$name" ]; then
        warn "$home/$name is an older copy and is no longer used - $name now lives in $root."
        warn "  Remove it when you are happy:  rm -rf $home/$name"
    fi
    return 0
}

phase_done() { jq -r ".\"$1\" // false" "$STATE_FILE"; }
phase_mark() {
    local key="$1"
    local tmp; tmp="$(mktemp)"
    jq ".\"$key\" = true" "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}
phase_skip_if_done() {
    if [ "$(phase_done "$1")" = "true" ]; then
        info "Phase '$1' already complete - skipping (delete $STATE_FILE to redo)"
        return 0
    fi
    return 1
}
# Forget a phase so the next run_phase runs it again. Absent key is a no-op.
phase_unmark() {
    local key="$1"
    local tmp; tmp="$(mktemp)"
    jq "del(.\"$key\")" "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

# seren_nvme_prepare DEV PART - get /dev/PART mounted at /mnt/nvme as ext4.
#
# PREPARE OR RE-PREPARE, and --wipe-nvme is what picks:
#
#   without it   prepare. An ext4 disk is mounted with everything on it kept;
#                a disk that is not ext4 (or not partitioned) STOPS the run.
#   with it      re-prepare. The disk is wiped, repartitioned and formatted
#                whatever is on it - ext4, mounted, in use as swap - and then
#                mounted empty.
#
# The flag used to mean only "you may format it if it is not ext4", so a disk
# carrying a previous install's ext4 came through --wipe-nvme with every old
# model and package still on it, and there was no way to ask for a clean one.
#
# One copy for every platform. There were three, and the Spark's had drifted:
# it formatted a non-ext4 disk without asking for the flag at all.
seren_nvme_prepare() {
    local dev="$1" part="$2"
    local wipe="${WIPE_NVME:-false}" need_format=false

    if [ "$wipe" = "true" ]; then
        # NEVER the disk the OS is running from. An Orin Nano booted from NVMe
        # has its root on nvme0n1, and the flag must not be able to reach it.
        local root_src root_disk
        root_src=$(findmnt -n -o SOURCE / 2>/dev/null || echo "")
        root_disk=$(lsblk -no PKNAME "$root_src" 2>/dev/null || echo "")
        if [ "$dev" = "$root_disk" ] || lsblk -nro MOUNTPOINT "/dev/$dev" 2>/dev/null | grep -qx '/'; then
            fail "--wipe-nvme refused: /dev/$dev holds the root filesystem ($root_src)."
            fail "Run without --wipe-nvme to leave it as it is."
            return 1
        fi
        warn "--wipe-nvme: re-preparing /dev/$dev - everything on it is erased"
        need_format=true
    elif mount | grep -q "/mnt/nvme"; then
        return 0
    elif ! lsblk | grep -q "$part"; then
        log "No $part partition - it needs creating"
        need_format=true
    elif ! sudo blkid "/dev/$part" | grep -q 'TYPE="ext4"'; then
        local current_fs
        current_fs=$(sudo blkid "/dev/$part" -o value -s TYPE 2>/dev/null || echo "unknown")
        warn "$part has filesystem '$current_fs' (expected ext4)"
        need_format=true
    fi

    if $need_format && [ "$wipe" != "true" ]; then
        # STOP, do not format. The disk is not ext4 (or not partitioned),
        # and nobody said it could be wiped. Say exactly what would happen
        # and how to allow it, on the console as well as in the log.
        local dev_state
        dev_state="$(lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT "/dev/$dev" 2>/dev/null | sed 's/^/      /')"
        echo -e "${RED}[SEREN]${NC} NVMe /dev/$dev is not an ext4 data disk and --wipe-nvme was not given." >&3 2>/dev/null || true
        echo -e "${RED}[SEREN]${NC} Prep will NOT format it. Current state:" >&3 2>/dev/null || true
        echo "$dev_state" >&3 2>/dev/null || true
        echo -e "${RED}[SEREN]${NC} If this disk is yours to erase, re-run with --wipe-nvme (everything on it is lost)." >&3 2>/dev/null || true
        fail "NVMe needs formatting and --wipe-nvme was not given. Refusing to wipe /dev/$dev."
        return 1
    fi

    if $need_format; then
        # Let go of it first: a re-prepare usually finds the disk mounted and
        # carrying the swapfile. A busy mount stops the run rather than being
        # forced - something is still using the disk and should be stopped.
        local sw mp
        for sw in $(swapon --show=NAME --noheadings 2>/dev/null | grep '^/mnt/nvme' || true); do
            sudo swapoff "$sw"
        done
        for mp in $(lsblk -nro MOUNTPOINT "/dev/$dev" 2>/dev/null | grep '^/' || true); do
            if ! sudo umount "$mp"; then
                fail "Cannot unmount $mp - something is still using the NVMe."
                fail "Stop the seren services on this node, then run again."
                return 1
            fi
        done
        # Wipe ALL signatures from disk + partition before recreating, otherwise
        # leftover NTFS/MBR fragments confuse blkid + the kernel.
        sudo wipefs -a "/dev/$dev" 2>/dev/null || true
        sudo wipefs -a "/dev/$part" 2>/dev/null || true
        sudo parted "/dev/$dev" --script mklabel gpt
        sudo parted "/dev/$dev" --script mkpart primary ext4 0% 100%
        sleep 2
        sudo partprobe "/dev/$dev" 2>/dev/null || true
        sudo mkfs.ext4 -F "/dev/$part"
    fi

    sudo mkdir -p /mnt/nvme
    sudo mount "/dev/$part" /mnt/nvme
    sudo chown "$TARGET_USER":"$TARGET_USER" /mnt/nvme

    # Update fstab - replace any existing nvme line (might be wrong fstype)
    if grep -q "/dev/$part" /etc/fstab; then
        sudo sed -i "\|/dev/$part|d" /etc/fstab
    fi
    echo "/dev/$part /mnt/nvme ext4 defaults 0 2" | sudo tee -a /etc/fstab >/dev/null

    # After a re-prepare ~/.local/{lib,bin} are symlinks from the last prep,
    # pointing into a disk that is now empty. Give them their targets back, or
    # the relocation that follows reads a dangling link as "nothing here" and
    # nests a second link inside the directory it then creates.
    if [ "$wipe" = "true" ]; then
        local sub
        for sub in lib bin; do
            if [ -L "/home/$TARGET_USER/.local/$sub" ]; then
                sudo -u "$TARGET_USER" mkdir -p "/mnt/nvme/pip-packages/$sub"
            fi
        done
    fi
    return 0
}

# Foundation phase wrapper - respects state tracking
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

# Service phase wrapper - ALWAYS runs, never tracked
# Used for llama/kokoro/comfy/chroma/coral installs because user explicitly
# asked for them - re-installing is "make sure it's there" not "skip work".
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

    # NOT a warning, and not phrased as a question. nvpmodel is a Jetson tool;
    # on a Spark or any non-Tegra node its absence is the expected state, and
    # "not a Jetson?" reads like something went wrong on exactly the platform
    # where nothing did.
    if ! command -v nvpmodel &>/dev/null; then
        info "No nvpmodel on this platform - power profile is managed by the OS. Skipping."
        return 0
    fi

    log "Setting nvpmodel mode 0 (MAXN)..."
    sudo nvpmodel -m 0 || warn "nvpmodel -m 0 failed - continuing anyway"

    if command -v jetson_clocks &>/dev/null; then
        log "Locking clocks via jetson_clocks..."
        sudo jetson_clocks || warn "jetson_clocks failed - continuing anyway"
    else
        warn "jetson_clocks not found - clocks will scale dynamically"
    fi

    # Best-effort fan check - warn if MAXN on a Jetson with no detectable fan
    local fan_rpm=""
    if [ -r /sys/devices/pwm-fan/target_pwm ]; then
        fan_rpm=$(cat /sys/devices/pwm-fan/target_pwm 2>/dev/null || echo "")
    elif [ -r /sys/class/hwmon/hwmon0/fan1_input ]; then
        fan_rpm=$(cat /sys/class/hwmon/hwmon0/fan1_input 2>/dev/null || echo "")
    fi
    if [ -z "$fan_rpm" ] || [ "$fan_rpm" = "0" ]; then
        warn "No active fan detected - MAXN power may cause thermal throttling."
        warn "If perf seems bad after this completes, check temps: cat /sys/class/thermal/thermal_zone*/temp"
    fi

    # Persist across reboots via systemd oneshot
    log "Installing seren-max-power.service for boot persistence..."
    sudo tee /etc/systemd/system/seren-max-power.service > /dev/null << 'EOF'
[Unit]
Description=Seren - Set Jetson to max power mode at boot
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
# SerenSystemPrebuilts - NOT Nvidia_Jetson_Prebuilt. The old name was the
# repo before the reorg; the URL kept working only because GitHub redirects
# renamed repositories, and the tags it resolved carried torch pins this tree
# had already moved past.
PREBUILT_REPO="https://github.com/ChadRoesler/SerenSystemPrebuilts"
PREBUILT_API="https://api.github.com/repos/ChadRoesler/SerenSystemPrebuilts/releases?per_page=100"

# Caller sets:
#   USER_PREBUILT_TAG - empty for auto-resolve, or a pinned tag like
#                       "20260916_xavier-jp5" (YYYYMMDD_<platform>-<jp>)
# Sets:
#   PREBUILT_TAG - resolved tag
#   PREBUILT_BASE - full URL prefix for asset downloads
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

    log "Resolving newest *_${RELEASE_SUFFIX} release from GitHub API..."
    ensure_jq
    command -v curl &>/dev/null || sudo apt-get install -y curl >/dev/null 2>&1

    local response
    response=$(curl -fsSL "$PREBUILT_API" 2>/dev/null) || \
        fail "Could not reach GitHub API at $PREBUILT_API. Pass --tag TAG to skip API lookup."

    # Tags are YYYYMMDD_<platform>-<jp>, so the newest BUILD sorts last by
    # name - sorted here rather than trusting the API's order, which is by
    # creation time and a re-upload would reorder.
    PREBUILT_TAG=$(echo "$response" | jq -r --arg suffix "_${RELEASE_SUFFIX}" \
        '[.[] | select(.draft | not) | select(.tag_name | endswith($suffix)) | .tag_name] | sort | last // empty')

    if [ -z "$PREBUILT_TAG" ]; then
        fail "No release found matching *_${RELEASE_SUFFIX}. Check the repo or pin --tag TAG."
        return 1
    fi

    PREBUILT_BASE="${PREBUILT_REPO}/releases/download/${PREBUILT_TAG}"
    log "Resolved: $PREBUILT_TAG"
    return 0
}

# ─────────────────────────────────────────────────────────────
# Prebuilt staging - driven by the release's own SHA256SUMS
# ─────────────────────────────────────────────────────────────
#
# WHAT THIS REPLACED. Three near-identical <platform>/prebuilts.sh files, each
# hardcoding the asset names it expected: `llama-server-orin-aarch64` (the
# archive writes llama-server-jp6-orin-aarch64), a torchvision wheel tagged
# `+fbb4cc5` on every platform (that is the XAVIER build's commit; the Nano's
# is +336d36e), and torch versions that had drifted from what was built. Each
# ran bare wget, chmod +x'd the result before anything checked it, and the
# Spark had no file at all - so `--llama` on a Spark died on "staged binary
# missing" after the driver had cheerfully said "services install directly".
#
# The release ships a SHA256SUMS listing every file it holds. So: fetch that
# first, SELECT what this run needs from it by pattern, download each asset
# and verify it against the listed hash before it is used. Names come from the
# archive, never from here. A byte that does not match is deleted and the run
# stops; nothing is made executable until it has been checked.
#
# Releases are flat: one asset per file, subdirectories flattened. The two
# apt folders are never uploaded (their debs are the box's own backup, not
# something that can be hosted), and the wheelhouse is not needed for an
# online node install, so selection is restricted to top-level entries.
#
# Legacy tags (2026.05.24-nano) have no SHA256SUMS. They are not resolved
# automatically any more - the tag scheme is YYYYMMDD_<platform>-<jp> - and
# pinning one with --tag gets a clear refusal rather than an unverified fetch.

# Where staged artifacts live for the service modules to consume.
export PREBUILT_DIR="${PREBUILT_DIR:-/home/${TARGET_USER:-$(id -un)}/seren-prebuilts}"

# Run a command as the target user - directly when that is already us, so
# this works on a box (or a test) with no sudo.
_as_target() {
    if [ "${TARGET_USER:-$(id -un)}" = "$(id -un)" ]; then "$@"; else sudo -u "$TARGET_USER" "$@"; fi
}

# The asset name as it appears in the URL: '+' -> %2B, '%' -> %25, ' ' -> %20.
# Pure bash on purpose - no python3 dependency in the one place a node fetches
# its binaries from, and byte-wise so a non-ASCII name still round-trips.
seren_urlencode() {
    local s="$1" out="" i c
    local LC_ALL=C
    for (( i = 0; i < ${#s}; i++ )); do
        c="${s:i:1}"
        case "$c" in
            [A-Za-z0-9._~-]) out+="$c" ;;
            *) printf -v c '%%%02X' "'$c"; out+="$c" ;;
        esac
    done
    printf '%s
' "$out"
}

# seren_prebuilts_index - fetch the release's SHA256SUMS once per run.
# Sets PREBUILT_INDEX (a local path). Refuses a release that has none.
seren_prebuilts_index() {
    if [ -n "${PREBUILT_INDEX:-}" ] && [ -s "$PREBUILT_INDEX" ]; then return 0; fi
    resolve_release_tag || return 1
    _as_target mkdir -p "$PREBUILT_DIR/.release"
    PREBUILT_INDEX="$PREBUILT_DIR/.release/SHA256SUMS-${PREBUILT_TAG}"
    # Always fetched, never cached across runs: it is a few KB, and a stale
    # copy is exactly how a re-issued asset would slip past verification.
    rm -f "$PREBUILT_INDEX"
    log "Fetching the release index (SHA256SUMS) for $PREBUILT_TAG..."
    if ! _as_target curl -fsSL --retry 3 -o "$PREBUILT_INDEX" "${PREBUILT_BASE}/SHA256SUMS"; then
        rm -f "$PREBUILT_INDEX"
        fail "Release $PREBUILT_TAG has no SHA256SUMS, so nothing in it can be verified."
        fail "  Releases from 2026-09-23 on carry one; tags before that (2026.05.24-nano)"
        fail "  do not. Pin a newer tag with --tag, or download by hand and stage into"
        fail "  $PREBUILT_DIR."
        return 1
    fi
    export PREBUILT_INDEX
    log "Release index: $(grep -c . "$PREBUILT_INDEX") file(s) listed in $PREBUILT_TAG"
}

# seren_prebuilts_pick GLOB - the top-level entries of the index whose name
# matches GLOB, one per line. Subdirectory entries (apt/, apt-toolchain/,
# wheelhouse/, vendor/, vllm/, sources/) are never picked here: none of them
# are release assets a node install needs, and two of them are never uploaded.
seren_prebuilts_pick() {
    local glob="$1" sum rel
    [ -s "${PREBUILT_INDEX:-}" ] || return 0
    while read -r sum rel; do
        [ -n "$rel" ] || continue
        # sha256sum prints "*name" for a file hashed in binary mode (always,
        # on Windows). `sha256sum -c` accepts both; so does this.
        rel="${rel#\*}"
        case "$rel" in */*) continue ;; esac
        # shellcheck disable=SC2254
        case "$rel" in $glob) echo "$rel" ;; esac
    done < "$PREBUILT_INDEX"
}

# seren_prebuilts_get NAME - download the asset NAME into PREBUILT_DIR and
# verify it against the index. Prints the local path. A file already present
# and matching is not fetched again; one present and NOT matching is refetched
# once, and refused if it still does not match.
seren_prebuilts_get() {
    local name="$1" want got dest url attempt
    # EVERYTHING SAID HERE GOES TO STDERR. The one stdout line is the staged
    # path, captured by the caller with $(...); the driver's log() prints to
    # stdout, so an unredirected caption would land inside STAGED_LLAMA_BIN.
    _pb_log()  { log  "$@" >&2; }
    _pb_warn() { warn "$@" >&2; }
    _pb_fail() { fail "$@" >&2; }
    want="$(awk -v n="$name" '{ r = $2; sub(/^\*/, "", r); if (r == n) { print $1; exit } }' "$PREBUILT_INDEX")"
    [ -n "$want" ] || { _pb_fail "$name is not in the release index"; return 1; }
    dest="$PREBUILT_DIR/$name"
    url="${PREBUILT_BASE}/$(seren_urlencode "$name")"
    for attempt in 1 2; do
        if [ ! -f "$dest" ]; then
            _pb_log "Downloading $name..."
            _as_target curl -fSL --retry 3 --progress-bar -o "$dest" "$url" || {
                rm -f "$dest"; fail "could not download $url"; return 1; }
        fi
        got="$(sha256sum "$dest" | awk '{print $1}')"
        if [ "$got" = "$want" ]; then
            _pb_log "  verified $name ✓"
            echo "$dest"
            return 0
        fi
        _pb_warn "  $name does not match the release's SHA256SUMS (got ${got:0:12}, want ${want:0:12})"
        rm -f "$dest"
        [ "$attempt" = 1 ] && warn "  refetching once"
    done
    _pb_fail "$name failed verification twice - refusing to stage it. The release or the"
    _pb_fail "  download path is not serving the bytes the archive recorded."
    return 1
}

# seren_prebuilts_stage GLOB VARNAME [required] - pick one matching asset,
# fetch and verify it, export VARNAME as its local path. With `required`, a
# release that has no such asset fails the run; otherwise it is noted.
seren_prebuilts_stage() {
    local glob="$1" var="$2" required="${3:-}" name path count
    name="$(seren_prebuilts_pick "$glob" | head -1)"
    count="$(seren_prebuilts_pick "$glob" | grep -c . || true)"
    if [ -z "$name" ]; then
        if [ "$required" = "required" ]; then
            fail "release $PREBUILT_TAG has no asset matching '$glob' - a $PLATFORM node needs it"
            return 1
        fi
        info "release $PREBUILT_TAG has no '$glob' - skipping (optional)"
        return 0
    fi
    [ "$count" -gt 1 ] && warn "$count assets match '$glob' in $PREBUILT_TAG; using $name"
    path="$(seren_prebuilts_get "$name")" || return 1
    export "$var=$path"
}

# ── the two entry points the dispatcher calls (same names as before) ──

run_prebuilts_download_foundation() {
    # Python and SQLite tarballs, staged BEFORE foundation so the Xavier can
    # skip forty minutes of source builds. The Nano and the Spark ship a new
    # enough Python and SQLite natively and their foundation phases do not
    # read these, so there is nothing to stage there - said, not assumed.
    if [ "$PLATFORM" = "host" ]; then
        # A host stages Python and SQLite only when its own are too old (an
        # Ubuntu 20.04 NUC). The asset names are the host builder's
        # (python-3.10.14-focal-x86_64.tar.gz, libsqlite3-3.45.1-focal-...),
        # not the Jetson builder's. No release for this box is not fatal: the
        # foundation phases build from source and say how long that takes.
        if seren_host_python_ok; then
            info "Foundation prebuilts: nothing to stage on this host ($(seren_host_python_ok --say))"
            return 0
        fi
        _as_target mkdir -p "$PREBUILT_DIR"
        if ! seren_prebuilts_index; then
            warn "No verified *_${RELEASE_SUFFIX} release to take Python and SQLite from -"
            warn "  the foundation will build them from source (~40 min)."
            return 0
        fi
        seren_prebuilts_stage 'libsqlite3-*.tar.gz'  STAGED_SQLITE_TARBALL || true
        seren_prebuilts_stage 'python-3.*-*.tar.gz'  STAGED_PYTHON_TARBALL || true
        [ -n "${STAGED_PYTHON_TARBALL:-}" ] || warn "no Python tarball in the release - foundation will source-build (~30 min)"
        [ -n "${STAGED_SQLITE_TARBALL:-}" ] || warn "no SQLite tarball in the release - foundation will source-build (~10 min)"
        return 0
    fi
    if [ "$PLATFORM" != "xavier" ]; then
        info "Foundation prebuilts: nothing to stage on $PLATFORM (Python/SQLite are native)"
        return 0
    fi
    _as_target mkdir -p "$PREBUILT_DIR"
    seren_prebuilts_index || return 1
    seren_prebuilts_stage 'python3.*-*.tar.gz' STAGED_PYTHON_TARBALL || return 1
    seren_prebuilts_stage 'sqlite3.*-*.tar.gz' STAGED_SQLITE_TARBALL || return 1
    [ -n "${STAGED_PYTHON_TARBALL:-}" ] || warn "no Python tarball in the release - foundation will source-build (~30 min)"
    [ -n "${STAGED_SQLITE_TARBALL:-}" ] || warn "no SQLite tarball in the release - foundation will source-build (~10 min)"
}

run_prebuilts_download_services() {
    _as_target mkdir -p "$PREBUILT_DIR"
    seren_prebuilts_index || return 1

    if $INSTALL_LLAMA; then
        seren_prebuilts_stage 'llama-server-*' STAGED_LLAMA_BIN required || return 1
        chmod +x "$STAGED_LLAMA_BIN"      # AFTER verification, never before
    fi
    if ${INSTALL_WHISPER:-false}; then
        seren_prebuilts_stage 'whisper-server-*' STAGED_WHISPER_BIN required || return 1
        chmod +x "$STAGED_WHISPER_BIN"
    fi

    # torch + torchvision for whichever component needs them. The names come
    # from the index, so the torchvision local-version tag is whatever THIS
    # platform's build produced - not a hardcoded commit from another box's.
    if $INSTALL_COMFYUI || ${INSTALL_MSMOE:-false}; then
        seren_prebuilts_stage 'torch-*.whl'        STAGED_TORCH_WHL   required || return 1
        seren_prebuilts_stage 'torchvision-*.whl'  STAGED_TVISION_WHL required || return 1
        # Required on the Xavier (nothing on PyPI covers sm_72), a spare elsewhere.
        seren_prebuilts_stage 'bitsandbytes-*.whl' STAGED_BNB_WHL \
            "$([ "$PLATFORM" = xavier ] && echo required)" || return 1
    fi

    if ${INSTALL_CORAL:-false}; then
        seren_prebuilts_stage 'gasket-*.ko'      STAGED_GASKET_KO       required || return 1
        seren_prebuilts_stage 'apex-*.ko'        STAGED_APEX_KO         required || return 1
        seren_prebuilts_stage 'coral-*.manifest' STAGED_CORAL_MANIFEST  || return 1
        [ -n "${STAGED_CORAL_MANIFEST:-}" ] || warn "No Coral manifest in the release - skipping the kernel-version check"
    fi

    log "Staged from $PREBUILT_TAG into $PREBUILT_DIR"
}

run_prebuilts_download() {
    run_prebuilts_download_foundation && run_prebuilts_download_services
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
# apt helpers - ask the release what it HAS, do not declare it
# ─────────────────────────────────────────────────────────────
#
# WHY THIS EXISTS, from a real failure on the Spark:
#
#   E: Unable to locate package libopenblas-base
#   E: Unable to locate package python3.11
#   E: Package 'netcat' has no installation candidate
#
# One `apt install -y` carried about twenty-five names. Three of them no longer
# resolve on that release, and apt's answer to three bad names in a list of
# twenty-five is to install NONE of them and exit 100. So build-essential, git,
# jq and everything else the node actually needs were never installed - and the
# phase died with a number, because the call was unguarded.
#
# The names were not even wrong when they were written. `libopenblas-base` was
# real on 20.04 and is gone now; `netcat` is a VIRTUAL package (it is
# netcat-openbsd or netcat-traditional, and `which netcat` still answers, which
# is why this looks insane from the shell); `python3.11` depends on which repo
# components a given image enables. A hardcoded package list is a claim about
# somebody else's distro that goes stale without anybody touching this file.
#
# So: ask. apt already knows which names resolve on THIS box, and a candidate of
# "(none)" is how it says "virtual" while an empty candidate is how it says
# "never heard of it". Both mean unusable, both are worth reporting by name, and
# neither is worth killing a node prep over.

# seren_apt_has - is this package installable on THIS release?
# Not "does the binary exist": `which netcat` answers on a box where
# `apt install netcat` cannot work. The candidate version is the real question.
seren_apt_has() {
    local cand
    cand="$(apt-cache policy "$1" 2>/dev/null | awk -F': ' '/Candidate:/{print $2; exit}')"
    [ -n "$cand" ] && [ "$cand" != "(none)" ]
}

# seren_apt_first - the first name in a list that this release can install.
# For packages that got renamed across releases: netcat-openbsd on one, the
# traditional one elsewhere. Prints nothing and returns 1 if none resolve.
seren_apt_first() {
    local p
    for p in "$@"; do
        if seren_apt_has "$p"; then echo "$p"; return 0; fi
    done
    return 1
}

# seren_apt_install - install what resolves, name what does not.
#
# REQUIRED vs OPTIONAL is the caller's call, made by which function they use.
# This one is the optional flavour: a name that has aged out warns and the rest
# still land, because losing jq should not cost you build-essential.
seren_apt_install() {
    local present=() missing=() p
    for p in "$@"; do
        if seren_apt_has "$p"; then present+=("$p"); else missing+=("$p"); fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        warn "not available on this release, skipping: ${missing[*]}"
        warn "  (a virtual or renamed package - the list in this platform's"
        warn "   foundation.sh has aged out, which is worth a look, but it is"
        warn "   not a reason to abandon the install)"
    fi
    [ ${#present[@]} -eq 0 ] && { warn "nothing left to install"; return 0; }
    if ! sudo apt install -y "${present[@]}"; then
        fail "apt install failed for: ${present[*]}"
        return 1
    fi
    return 0
}

# seren_apt_install_required - the same, except a missing name is fatal AND SAID.
# Used for the handful without which the node is not prepared at all.
seren_apt_install_required() {
    local missing=() p
    for p in "$@"; do
        seren_apt_has "$p" || missing+=("$p")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        fail "required packages are not installable on this release: ${missing[*]}"
        fail "  This node cannot be prepared until that is resolved - check that"
        fail "  the universe component is enabled, or that the name has not been"
        fail "  renamed in this Ubuntu release."
        return 1
    fi
    if ! sudo apt install -y "$@"; then
        fail "apt install failed for the required set: $*"
        return 1
    fi
    return 0
}

# ─────────────────────────────────────────────────────────────
# Venv helpers - one venv per Python service
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
        # PICK THE INTERPRETER BY LOOKING, not by hardcoding a minor version.
        #
        # This was `${PYTHON_BIN:-python3.10}` and nothing on the Spark path ever
        # set PYTHON_BIN - so every venv on a JP7 box would have failed with
        # "python3.10 not found", on a machine carrying a perfectly good 3.12.
        # The Jetson convention was true for JetPack 6 and became a false claim
        # about every other platform the moment one was added.
        #
        # Explicit still wins: PYTHON_BIN set by a platform module or by hand is
        # used as given and is not second-guessed. Otherwise probe, newest-first,
        # over the range the rest of Seren supports - the same 3.10-3.12 window
        # the service installers' find_python accepts, so a box that can run a
        # service can also build a node venv. Plain python3 is the last resort
        # and is accepted only if it lands inside that window; a distro that has
        # moved to 3.13 should say so here rather than fail later inside pip.
        local python_bin="${PYTHON_BIN:-}"
        if [ -z "$python_bin" ]; then
            local cand ver
            for cand in python3.12 python3.11 python3.10 python3; do
                command -v "$cand" &>/dev/null || continue
                ver="$("$cand" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || echo "")"
                case "$ver" in 3.10|3.11|3.12) python_bin="$cand"; break ;; esac
            done
        fi
        if [ -z "$python_bin" ] || ! command -v "$python_bin" &>/dev/null; then
            # SAY WHAT IS ACTUALLY THERE. "python3.10 not found" on a box
            # carrying 3.12 reads as a broken machine; the list makes it read
            # as the version mismatch it is.
            local seen="" c v
            for c in python3.13 python3.12 python3.11 python3.10 python3; do
                command -v "$c" &>/dev/null || continue
                v="$("$c" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || echo "?")"
                seen="${seen:+$seen, }$c ($v)"
            done
            fail "ensure_venv: no Python 3.10-3.12 on PATH (set PYTHON_BIN to override)."
            fail "  On PATH: ${seen:-nothing called python3 at all}"
            fail "  Run this node's foundation phase first - it installs one."
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
                warn "Symlink $venv_path points to $current_target, expected $real_venv - leaving alone"
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
# pid_file plumbing shared by whisper, llama and Kokoro
# ═════════════════════════════════════════════════════════════
#
# The Observatory runs a start script as `bash start_<name>.sh` - no login
# shell, so the LD_LIBRARY_PATH foundation puts in ~/.bashrc is not there. Each
# start script sets its own, and it has to be the same path foundation wrote
# for this platform: the Xavier's CUDA 12.2 only works through the compat shim
# (R35 ships an older driver), which plain /usr/local/cuda/lib64 does not
# include. Mirrors the .bashrc lines in <platform>/foundation.sh.
seren_cuda_ld_path() {
    case "${PLATFORM:-}" in
        xavier) echo "/usr/local/cuda-12.2/compat:/usr/local/cuda-12.2/lib64" ;;
        nano)   echo "/usr/local/cuda-12.6/lib64" ;;
        *)      echo "/usr/local/cuda/lib64" ;;
    esac
}

# _seren_write_stop_script NAME USER_HOME LOGS - ~/stop_<name>.sh. The same for
# every pid_file service: TERM, ten seconds' grace, KILL, clear the pid. A
# missing pid file is "not running", which is success.
_seren_write_stop_script() {
    local name="$1" home="$2" logs="$3"
    _as_target tee "$home/stop_${name}.sh" > /dev/null <<STOPEOF
#!/bin/bash
# stop_${name}.sh - written by seren-prepare-node (${name}).
PID="$logs/${name}.pid"
[ -f "\$PID" ] || exit 0
kill "\$(cat "\$PID")" 2>/dev/null
for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "\$(cat "\$PID")" 2>/dev/null || break; sleep 1; done
kill -9 "\$(cat "\$PID")" 2>/dev/null
rm -f "\$PID"
STOPEOF
    chmod +x "$home/stop_${name}.sh"
}

# ═════════════════════════════════════════════════════════════
# Whisper - speech to text (whisper.cpp's whisper-server)
# ═════════════════════════════════════════════════════════════
#
# The same shape as llama.cpp: SystemPrebuilts builds one static binary per
# platform (phases/whisper.sh), this copies it into place. What llama.sh does
# NOT do, and this does: a start and a stop script, a pid and a log where the
# Observatory looks for them, and a service manifest - so Lodestar can start,
# stop and watch it like any other node service (26 Sept 2026; until then no
# node installer wrote a manifest at all, so a node looked empty to its
# Observatory however much it ran).
#
# The server answers multipart POSTs at /v1/audio/transcriptions (an OpenAI-
# style path via --inference-path) with the model loaded once. No bearer: like
# llama-server and Kokoro on the node, it is a LAN service behind Lodestar.
#
#   seren_install_whisper DEFAULT_MODEL
#     WHISPER_MODEL        overrides the model (--whisper-model): a ggml name
#                          from huggingface.co/ggerganov/whisper.cpp, e.g.
#                          base.en, small.en, large-v3-turbo
#     WHISPER_PORT         default 8081
#     WHISPER_MODEL_BASE   where models are fetched from (a test points this
#                          at a folder)
seren_install_whisper() {
    local default_model="$1"
    local USER_HOME="/home/$TARGET_USER"
    [ -n "${SEREN_TEST_HOME:-}" ] && USER_HOME="$SEREN_TEST_HOME"
    local BIN_DIR; BIN_DIR="$(seren_apps_root)/whisper.cpp/build/bin"
    seren_note_home_copy whisper.cpp
    local MODEL="${WHISPER_MODEL:-$default_model}"
    local PORT="${WHISPER_PORT:-8081}"
    local BASE="${WHISPER_MODEL_BASE:-https://huggingface.co/ggerganov/whisper.cpp/resolve/main}"
    local MODELS="$USER_HOME/models/whisper"
    [ -d /mnt/nvme ] && [ -z "${SEREN_TEST_HOME:-}" ] && MODELS="/mnt/nvme/models/whisper"
    local MODEL_PATH="$MODELS/ggml-${MODEL}.bin"
    local LOGS="$USER_HOME/seren-logs"

    if [ -z "${STAGED_WHISPER_BIN:-}" ] || [ ! -f "$STAGED_WHISPER_BIN" ]; then
        fail "Staged whisper-server binary missing. Prebuilts didn't run, or the release has no whisper-server for this platform."
        fail "Expected at: ${STAGED_WHISPER_BIN:-<unset>}  (SystemPrebuilts: build-jetson-prebuilts.sh --whisper)"
        return 1
    fi
    _as_target mkdir -p "$BIN_DIR" "$MODELS" "$LOGS"
    _as_target cp -f "$STAGED_WHISPER_BIN" "$BIN_DIR/whisper-server"
    chmod +x "$BIN_DIR/whisper-server"
    log "whisper-server installed at $BIN_DIR/whisper-server"

    # The model: fetched once, kept. A partial download lands under a temp
    # name and is only moved into place whole.
    if [ -s "$MODEL_PATH" ]; then
        log "Whisper model already here: $MODEL_PATH"
    else
        log "Downloading whisper model ggml-${MODEL}.bin..."
        _as_target curl -fL --retry 3 -o "$MODEL_PATH.part" "$BASE/ggml-${MODEL}.bin" \
            || { rm -f "$MODEL_PATH.part"; fail "Could not download ggml-${MODEL}.bin from $BASE"; return 1; }
        _as_target mv "$MODEL_PATH.part" "$MODEL_PATH"
    fi
    local SUM; SUM="$(sha256sum "$MODEL_PATH" | awk '{print $1}')"

    # Start / stop: the pid_file lifecycle the Observatory drives. CUDA's
    # runtime libraries are found through LD_LIBRARY_PATH, as for llama-server
    # (seren_cuda_ld_path - this said /usr/local/cuda/lib64 on every platform,
    # which on a Xavier leaves out the compat shim its CUDA 12.2 needs).
    local LDP; LDP="$(seren_cuda_ld_path)"
    _as_target tee "$USER_HOME/start_whisper.sh" > /dev/null <<STARTEOF
#!/bin/bash
# start_whisper.sh - written by seren-prepare-node (whisper). Started and
# stopped by the Observatory through its manifest (~/.seren/services/whisper.json).
export LD_LIBRARY_PATH=$LDP:\${LD_LIBRARY_PATH:-}
PID="$LOGS/whisper.pid"
if [ -f "\$PID" ] && kill -0 "\$(cat "\$PID")" 2>/dev/null; then echo "whisper already running"; exit 0; fi
nohup "$BIN_DIR/whisper-server" \\
  -m "$MODEL_PATH" \\
  --host 0.0.0.0 --port $PORT \\
  --inference-path /v1/audio/transcriptions \\
  -t "\$(nproc)" >> "$LOGS/whisper.log" 2>&1 &
echo \$! > "\$PID"
STARTEOF
    chmod +x "$USER_HOME/start_whisper.sh"
    _seren_write_stop_script whisper "$USER_HOME" "$LOGS"

    write_service_manifest "whisper" \
        service_type=pid_file \
        implementation=whisper.cpp \
        port="$PORT" \
        endpoint=/v1/audio/transcriptions \
        health_path=/ \
        start_script="$USER_HOME/start_whisper.sh" \
        stop_script="$USER_HOME/stop_whisper.sh" \
        pid_path="$LOGS/whisper.pid" \
        log_path="$LOGS/whisper.log" \
        --service-specific model="$MODEL" \
        --service-specific model_path="$MODEL_PATH" \
        --service-specific model_sha256="$SUM" \
        --service-specific device=cuda

    if "$BIN_DIR/whisper-server" --help >/dev/null 2>&1; then
        log "whisper-server runs; start it with ~/start_whisper.sh (or from Lodestar)"
    else
        warn "whisper-server did not answer --help - check LD_LIBRARY_PATH ($LDP)"
    fi
}

# ═════════════════════════════════════════════════════════════
# llama.cpp - the inference server (llama-server)
# ═════════════════════════════════════════════════════════════
#
# Design note: llama and Kokoro were installed on every node and
# registered on none, so the Observatory listed nothing and Lodestar could not
# start or stop either. The punch-list row was "write_service_manifest exists,
# nobody calls it for llama or Kokoro". This is llama's half; Kokoro's follows.
#
# ONE manifest, and the model is a SETTING, not an identity. A node serves one
# model at a time and swapping it is the everyday act, so "llama" is the
# service and ~/seren-llama.env says what it serves. The alternative - a
# manifest per model - makes each swap an install, and leaves the Observatory
# listing three llamas on a box that can only run one.
#
# ~/seren-llama.env is written ONCE and is then the user's: a re-install (and
# every -l is one) keeps it, and --llama-model changes that one line and
# nothing else. Overwriting it would quietly undo the last model swap every
# time anyone added a component. The port is NOT in it: the manifest carries
# the port too, and one number in two files is two numbers.
#
# Nothing is downloaded. Models are big, many and a choice; the Observatory's
# /service/llama/models lists what is in models_dir, and a start with no model
# there fails saying which file it wanted and where to set it.
#
# This absorbed spark/llama.sh's ~/start-llama-spark.sh: its sizes (32k
# context, two slots, q8_0 KV cache) are now the Spark's defaults here.
#
#   seren_install_llama CTX PARALLEL [EXTRA_ARGS]    (per-platform defaults)
#     LLAMA_MODEL    --llama-model: a .gguf path, or a bare name inside the
#                    models dir. Unset keeps what the env file already says.
#     LLAMA_PORT     default 8090 (where the chat side has always found it)
seren_install_llama() {
    local def_ctx="$1" def_parallel="$2" def_extra="${3:-}"
    local USER_HOME="/home/$TARGET_USER"
    [ -n "${SEREN_TEST_HOME:-}" ] && USER_HOME="$SEREN_TEST_HOME"
    local BIN_DIR; BIN_DIR="$(seren_apps_root)/llama.cpp/build/bin"
    seren_note_home_copy llama.cpp
    local PORT="${LLAMA_PORT:-8090}"
    local MODELS="$USER_HOME/models"
    [ -d /mnt/nvme ] && [ -z "${SEREN_TEST_HOME:-}" ] && MODELS="/mnt/nvme/models"
    local LOGS="$USER_HOME/seren-logs"
    local ENVF="$USER_HOME/seren-llama.env"
    local LDP; LDP="$(seren_cuda_ld_path)"

    if [ -z "${STAGED_LLAMA_BIN:-}" ] || [ ! -f "$STAGED_LLAMA_BIN" ]; then
        fail "Staged llama-server binary missing. Prebuilts/build phase didn't run or failed."
        fail "Expected at: ${STAGED_LLAMA_BIN:-<unset>}"
        return 1
    fi
    _as_target mkdir -p "$BIN_DIR" "$MODELS" "$LOGS"
    _as_target cp -f "$STAGED_LLAMA_BIN" "$BIN_DIR/llama-server"
    chmod +x "$BIN_DIR/llama-server"
    log "llama-server installed at $BIN_DIR/llama-server"

    # A bare name means "the one in the models dir" - the same words the
    # Observatory's model list uses.
    local want="${LLAMA_MODEL:-}"
    [ -n "$want" ] && [[ "$want" != */* ]] && want="$MODELS/$want"

    if [ ! -f "$ENVF" ]; then
        # First install: the model asked for, else the only .gguf here, else a
        # placeholder the start script will refuse by name.
        if [ -z "$want" ]; then
            local found=("$MODELS"/*.gguf)
            if [ ${#found[@]} -eq 1 ] && [ -f "${found[0]}" ]; then want="${found[0]}"; fi
        fi
        [ -n "$want" ] || want="$MODELS/model.gguf"
        {
            echo "# ~/seren-llama.env - what ~/start_llama.sh serves. Written once by"
            echo "# seren-prepare-node (llama) and yours from then on: a re-install keeps it,"
            echo "# and --llama-model changes the LLAMA_MODEL line and nothing else."
            echo "# Edit, then restart llama from Lodestar (or ~/stop_llama.sh; ~/start_llama.sh)."
            echo "# The port lives in ~/.seren/services/llama.json, not here."
            printf 'LLAMA_MODEL=%q\n' "$want"
            printf 'LLAMA_CTX=%q\n' "$def_ctx"
            echo "LLAMA_NGL=999        # layers on the GPU; 999 = all of them"
            printf 'LLAMA_PARALLEL=%q\n' "$def_parallel"
            # Quoted by hand, not %q: these are our own flags, and a file meant
            # for editing should read '--cache-type-k q8_0', not '\ '-escaped.
            echo "LLAMA_EXTRA_ARGS=\"$def_extra\""
        } | _as_target tee "$ENVF" > /dev/null
        log "llama settings written: $ENVF"
    elif [ -n "$want" ]; then
        local tmp; tmp="$(_as_target mktemp "$ENVF.XXXXXX")"
        awk -v line="$(printf 'LLAMA_MODEL=%q' "$want")" \
            'BEGIN{d=0} /^LLAMA_MODEL=/{print line; d=1; next} {print} END{if(!d) print line}' \
            "$ENVF" | _as_target tee "$tmp" > /dev/null
        _as_target mv "$tmp" "$ENVF"
        log "llama model set in $ENVF: $want"
    else
        log "llama settings kept: $ENVF (--llama-model changes the model)"
    fi
    # shellcheck disable=SC1090
    local shown; shown="$( . "$ENVF" 2>/dev/null; echo "${LLAMA_MODEL:-}")"
    [ -f "$shown" ] || warn "No model at $shown yet - put a .gguf there, or set LLAMA_MODEL in $ENVF"

    _as_target tee "$USER_HOME/start_llama.sh" > /dev/null <<STARTEOF
#!/bin/bash
# start_llama.sh - written by seren-prepare-node (llama). Started and stopped by
# the Observatory through its manifest (~/.seren/services/llama.json). WHAT it
# serves is $ENVF - edit that, not this.
export LD_LIBRARY_PATH=$LDP:\${LD_LIBRARY_PATH:-}
PID="$LOGS/llama.pid"
if [ -f "\$PID" ] && kill -0 "\$(cat "\$PID")" 2>/dev/null; then echo "llama already running"; exit 0; fi
ENVF="$ENVF"
[ -f "\$ENVF" ] || { echo "no \$ENVF - re-run seren-prepare-node.sh -l" >&2; exit 1; }
. "\$ENVF"
[ -f "\${LLAMA_MODEL:-}" ] || { echo "no model at '\${LLAMA_MODEL:-}' - set LLAMA_MODEL in \$ENVF" >&2; exit 1; }
# LLAMA_EXTRA_ARGS is a list of flags, so it is split on purpose.
# shellcheck disable=SC2086
nohup "$BIN_DIR/llama-server" \\
  --model "\$LLAMA_MODEL" \\
  --host 0.0.0.0 --port $PORT \\
  --ctx-size "\${LLAMA_CTX:-8192}" \\
  --n-gpu-layers "\${LLAMA_NGL:-999}" \\
  --parallel "\${LLAMA_PARALLEL:-1}" \\
  --jinja \${LLAMA_EXTRA_ARGS:-} >> "$LOGS/llama.log" 2>&1 &
echo \$! > "\$PID"
STARTEOF
    chmod +x "$USER_HOME/start_llama.sh"
    _seren_write_stop_script llama "$USER_HOME" "$LOGS"

    # models_dir is what the Observatory's /service/llama/models lists. No
    # "model" key: the env file is the truth for that, and a copy here would be
    # wrong after the first swap.
    write_service_manifest "llama" \
        service_type=pid_file \
        implementation=llama.cpp \
        port="$PORT" \
        endpoint=/v1/chat/completions \
        health_path=/health \
        start_script="$USER_HOME/start_llama.sh" \
        stop_script="$USER_HOME/stop_llama.sh" \
        pid_path="$LOGS/llama.pid" \
        log_path="$LOGS/llama.log" \
        --service-specific models_dir="$MODELS" \
        --service-specific config_path="$ENVF" \
        --service-specific device=cuda

    if "$BIN_DIR/llama-server" --version 2>&1 | head -3; then
        log "llama-server runs; start it with ~/start_llama.sh (or from Lodestar)"
    else
        warn "llama-server did not answer --version - check LD_LIBRARY_PATH ($LDP)"
    fi
}

# ═════════════════════════════════════════════════════════════
# Kokoro - text to speech (Kokoro-FastAPI), registered for the Observatory
# ═════════════════════════════════════════════════════════════
#
# The install itself stays in <platform>/kokoro.sh - the dependency pins are
# genuinely per platform. What is shared is the part that was missing
# (27 Sept 2026, with llama above): start/stop scripts and a manifest.
#
# HOW Kokoro-FastAPI starts, from its own start-gpu.sh: uvicorn api.src.main:app
# from the repo root with the repo and api/ on PYTHONPATH. The installers used
# to log "uvicorn src.main:app", which is not a module in that repo.
#
# MODEL_DIR is absolute on purpose. Kokoro joins it onto api/, and an absolute
# path wins that join - so it points at where the installers actually put the
# weights (src/models/v1_0 at the repo root), not at api/src/models where
# upstream's own script downloads them and ours never did. The voices ship in
# the repo, at api/src/voices/v1_0; that is also what the Observatory's
# /service/kokoro/voices lists, through serviceSpecific.voices_path.
#
#   seren_register_kokoro DEVICE     cpu | cuda
#     cpu on the Jetsons: the venv's torch is PyPI's aarch64 CPU build, and
#     Kokoro on the CPU leaves the unified memory to llama-server (the reason
#     the old start_kokoro.sh hid the GPU). cuda on the Spark - USE_GPU on,
#     and Kokoro itself falls back to the CPU if torch cannot see CUDA.
#     KOKORO_PORT   default 8880
seren_register_kokoro() {
    local device="${1:-cpu}"
    local USER_HOME="/home/$TARGET_USER"
    [ -n "${SEREN_TEST_HOME:-}" ] && USER_HOME="$SEREN_TEST_HOME"
    local DIR; DIR="$(seren_apps_root)/Kokoro-FastAPI"
    local VENV="$USER_HOME/seren-venvs/kokoro"
    local PORT="${KOKORO_PORT:-8880}"
    local LOGS="$USER_HOME/seren-logs"
    local VOICES="$DIR/api/src/voices/v1_0"
    local use_gpu=false hide_gpu='export CUDA_VISIBLE_DEVICES=""'
    if [ "$device" = cuda ]; then use_gpu=true; hide_gpu="# (the GPU is visible - device cuda)"; fi

    if [ ! -d "$DIR" ] || [ ! -x "$VENV/bin/python" ]; then
        fail "Kokoro is not where its start script would look: $DIR, $VENV"
        return 1
    fi
    _as_target mkdir -p "$LOGS"

    _as_target tee "$USER_HOME/start_kokoro.sh" > /dev/null <<STARTEOF
#!/bin/bash
# start_kokoro.sh - written by seren-prepare-node (kokoro). Started and stopped
# by the Observatory through its manifest (~/.seren/services/kokoro.json).
PID="$LOGS/kokoro.pid"
if [ -f "\$PID" ] && kill -0 "\$(cat "\$PID")" 2>/dev/null; then echo "kokoro already running"; exit 0; fi
cd "$DIR" || exit 1
export PYTHONPATH="$DIR:$DIR/api"
export MODEL_DIR="$DIR/src/models"
export VOICES_DIR="$VOICES"
export WEB_PLAYER_PATH="$DIR/web"
export USE_GPU=$use_gpu
$hide_gpu
nohup "$VENV/bin/python" -m uvicorn api.src.main:app \\
  --host 0.0.0.0 --port $PORT >> "$LOGS/kokoro.log" 2>&1 &
echo \$! > "\$PID"
STARTEOF
    chmod +x "$USER_HOME/start_kokoro.sh"
    _seren_write_stop_script kokoro "$USER_HOME" "$LOGS"

    write_service_manifest "kokoro" \
        service_type=pid_file \
        implementation=kokoro-fastapi \
        port="$PORT" \
        endpoint=/v1/audio/speech \
        health_path=/health \
        start_script="$USER_HOME/start_kokoro.sh" \
        stop_script="$USER_HOME/stop_kokoro.sh" \
        pid_path="$LOGS/kokoro.pid" \
        log_path="$LOGS/kokoro.log" \
        venv_path="$VENV" \
        --service-specific voices_path="$VOICES" \
        --service-specific model_dir="$DIR/src/models" \
        --service-specific device="$device"
    log "Kokoro registered; start it with ~/start_kokoro.sh (or from Lodestar), port $PORT"
}

# ═════════════════════════════════════════════════════════════
# Manifest writers - ~/.seren/{node,services/<name>}.json
# ═════════════════════════════════════════════════════════════
#
# Each service install calls write_service_manifest at the end. The node
# manifest is written once during foundation Phase 1.
#
# Manifests are the agent's source of truth for "what's installed on this
# box" - replacing fragile directory probing. Each manifest has:
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
# Doesn't try to handle arbitrary unicode - that'd need a proper JSON
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
        echo "ERROR: USER_HOME is empty - manifest helpers can't proceed." >&2
        echo "       This is usually a bug in seren-prepare-node.sh's init order." >&2
        return 1
    fi
    if [ -z "${TARGET_USER:-}" ]; then
        echo "ERROR: TARGET_USER is empty - manifest helpers can't proceed." >&2
        return 1
    fi
    local d="$USER_HOME/.seren"
    _as_target mkdir -p "$d/services"
    echo "$d"
}

# Atomic JSON write: writes to a tempfile, then mv. Prevents partial reads.
_seren_atomic_write() {
    local target="$1"; shift
    local content="$1"
    # _as_target, not sudo -u: the same user needs no sudo (and a test, or a
    # box without it, has none).
    local tmp; tmp=$(_as_target mktemp "${target}.XXXXXX")
    echo "$content" | _as_target tee "$tmp" > /dev/null
    _as_target mv "$tmp" "$target"
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

    # serviceSpecific sub-object - always present, even if empty
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

    # Pretty-print via jq if available - easier for humans to read/edit
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
# (The per-node "seren-agent" installer that used to live here is gone.)
# ═════════════════════════════════════════════════════════════
#
# install_agent_common() was 240 lines that nothing called: it unpacked a
# seren-agent.tar.gz that no longer exists, ran a seren-secrets.sh that was
# never in this tree, installed a unit on port 7777 - the Observatory's port -
# and wrote a second, wider sudoers file. The Observatory replaced the agent
# and has its own installer under services/. Dead code that documents a
# system which is not there is worse than none, because it reads as true.
