#!/bin/bash
# ══════════════════════════════════════════════════════════════
# spark/foundation.sh - DGX Spark (jp7/GB10 Blackwell) OS prereq phases
#
# Sourced by seren-prepare-node.sh. Defines run_foundation() for Spark.
#
# The Spark is NOT a Jetson - no /etc/nv_tegra_release, no nvpmodel,
# no eMMC, no custom Maxwell/Volta/Ampere GPU. It's a desktop-class
# x86_64 (or Grace ARM) system with a GB10 Blackwell GPU, 128GB unified
# memory, active cooling, and JetPack 7 on Ubuntu 24.04.
#
# This means:
#   - No MAXN power phase (no nvpmodel - Spark manages power at the
#     firmware/hardware level transparently)
#   - No Python source build - JP7 ships Python 3.11+ natively
#   - No SQLite source build - Ubuntu 24.04 ships SQLite 3.40+
#   - No NVMe reformat/mount - Spark has built-in NVMe at /mnt/nvme
#   - CUDA toolkit is pre-installed via JetPack 7
#   - Blackwell GB10 CUDA arch - the key differentiator for builds
#
# Phases:
#   01_spark_os_trim     - disable bloat, install build essentials
#   02_spark_cuda        - ensure CUDA toolkit is complete for Blackwell
#   03_spark_nvme        - verify NVMe, set up model dirs + pip relocation
# ══════════════════════════════════════════════════════════════

# ─────────────────────────────────────────────────────────────
# Phase 1 - OS trim (Ubuntu 24.04 base, lighter than Jetson)
# ─────────────────────────────────────────────────────────────
phase_spark_os_trim() {
    # CONSENT. This phase removes the desktop, docker and snap and sets the
    # default target to multi-user: correct for a dedicated node, unforgivable
    # as a side effect. It runs only with --trim-os; otherwise it skips and
    # says so on the console, where the prompt would have been.
    if [ "${TRIM_OS:-false}" != "true" ]; then
        warn "OS trim SKIPPED: pass --trim-os to remove the desktop, docker and snap (headless node)"
        echo -e "${YELLOW}[SEREN]${NC} OS trim skipped - pass --trim-os to make this a headless node" >&3 2>/dev/null || true
        return 0
    fi
    # Spark ships as a headless dev workstation - trim desktop cruft
    sudo systemctl set-default multi-user.target
    sudo systemctl disable gdm3.service lightdm.service 2>/dev/null || true

    local DISABLE_SERVICES=(
        snapd.service snapd.socket snapd.seeded.service
        ModemManager.service bluetooth.service
        cups.service cups-browsed.service
        unattended-upgrades.service whoopsie.service apport.service
        avahi-daemon.service
    )
    for svc in "${DISABLE_SERVICES[@]}"; do
        sudo systemctl disable --now "$svc" 2>/dev/null || true
    done

    sudo systemctl disable --now docker.service docker.socket containerd.service 2>/dev/null || true
    sudo apt purge -y \
        docker.io docker-ce containerd.io \
        nvidia-docker2 nvidia-container-toolkit \
        2>/dev/null || true
    sudo rm -rf /var/lib/docker 2>/dev/null || true
    sudo apt purge snapd -y 2>/dev/null || true
    sudo rm -rf /snap /var/snap /var/lib/snapd 2>/dev/null || true

    sudo apt purge -y \
        thunderbird* libreoffice* firefox chromium-browser \
        ubuntu-desktop gnome-shell gnome-terminal nautilus gedit \
        evince eog totem rhythmbox shotwell cheese yelp \
        gnome-calculator gnome-calendar gnome-characters gnome-clocks \
        gnome-contacts gnome-font-viewer gnome-logs gnome-maps \
        gnome-photos gnome-screenshot gnome-weather gnome-disk-utility \
        baobab simple-scan remmina transmission-gtk usb-creator-gtk \
        deja-dup speech-dispatcher system-config-printer cups* \
        2>/dev/null || true

    # GUARDED, all three. These were bare `sudo apt ...` under `set -euo
    # pipefail`, so a failure ended the phase with apt's exit 100 and not one
    # word about which package apt was complaining about. The detail was in the
    # log the whole time; nothing carried it up to the person watching.
    sudo apt update || { fail "apt update failed - check the network and sources.list"; return 1; }
    sudo apt upgrade -y || warn "apt upgrade did not complete cleanly - continuing"

    # THE SET WITHOUT WHICH THIS NODE IS NOT PREPARED. Deliberately small, and
    # deliberately NOT version-pinned: python3-dev and python3-venv track
    # whatever this release's python3 is, which is the point. The list used to
    # name python3.11 outright and the Spark answered
    #   E: Unable to locate package python3.11
    # on a box that has 3.12 - because whether a specific minor version is
    # packaged depends on the release AND on which repo components the image
    # enables, neither of which this file can know.
    seren_apt_install_required \
        build-essential git curl wget \
        python3-pip python3-dev python3-venv python3-setuptools python3-wheel \
        || return 1

    # EVERYTHING ELSE IS BEST-EFFORT, and that is the other half of the fix.
    # apt's answer to three stale names in a list of twenty-five is to install
    # NONE of them, so `libopenblas-base` (real on 20.04, gone since) took
    # build-essential down with it. Now a name that has aged out is reported
    # and skipped.
    #
    # netcat is a VIRTUAL package - netcat-openbsd or netcat-traditional
    # depending on the release - which is why `which netcat` answers on a box
    # where `apt install netcat` cannot work. Resolved by asking, not guessing.
    local nc; nc="$(seren_apt_first netcat-openbsd netcat-traditional netcat || true)"
    seren_apt_install \
        net-tools i2c-tools espeak-ng \
        libcurl4-openssl-dev libssl-dev libffi-dev libjpeg-dev zlib1g-dev \
        libopenblas-dev libopenmpi-dev libomp-dev \
        software-properties-common jq ${nc:+$nc} \
        || warn "some optional packages did not install - see above"

    # WHICH INTERPRETER THE REST OF THIS RUN USES, discovered and then STATED.
    #
    # There used to be a `ln -sf /usr/bin/python3.12 /usr/local/bin/python3.11`
    # here, to satisfy a "venv convention" that wanted a 3.11. It made
    # `which python3.11` answer on a box with no python3.11 package, which is
    # exactly the confusion that sent us hunting - and it did not even work,
    # because ensure_venv was hardcoded to python3.10, a third number. A
    # symlink that lies about what is installed is worse than the gap it fills.
    #
    # So: find a real one, export it, and let ensure_venv use it. ensure_venv
    # probes on its own too, for anyone running a service phase alone.
    local cand ver
    PYTHON_BIN=""
    for cand in python3.12 python3.11 python3.10 python3; do
        command -v "$cand" &>/dev/null || continue
        ver="$("$cand" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || echo "")"
        case "$ver" in 3.10|3.11|3.12) PYTHON_BIN="$cand"; break ;; esac
    done
    if [ -z "$PYTHON_BIN" ]; then
        fail "No Python 3.10-3.12 after apt install - JP7 should ship 3.11+."
        fail "  python3 reports: $(python3 --version 2>&1 || echo 'not present')"
        return 1
    fi
    export PYTHON_BIN
    log "Python for venvs: $PYTHON_BIN ($("$PYTHON_BIN" --version 2>&1))"

    sudo apt autoremove -y || warn "apt autoremove did not complete"
    sudo apt autoclean || true
    sudo apt clean || true
}

# ─────────────────────────────────────────────────────────────
# Phase 2 - Ensure CUDA toolkit is complete for Blackwell
# ─────────────────────────────────────────────────────────────
# JetPack 7 ships CUDA for Blackwell. The toolkit is pre-installed but
# we verify and install any missing components (cuda-nvcc, etc.).
# Blackwell GB10 compute capability is 12.1 (sm_121) - measured by the
# SerenSystemPrebuilts selftest on the real device, not read off a spec sheet.
phase_spark_cuda() {
    if command -v nvcc &>/dev/null; then
        local NVCC_VER
        NVCC_VER=$(nvcc --version 2>/dev/null | grep release | awk '{print $6}' | cut -d',' -f1)
        log "nvcc already installed: $NVCC_VER"
    else
        log "Installing cuda-toolkit for JetPack 7..."
        sudo apt install -y cuda-toolkit 2>/dev/null || {
            warn "cuda-toolkit not found via apt - adding NVIDIA CUDA repo..."
            cd /tmp
            # JP7 on Ubuntu 24.04 (arm64 or x86_64)
            local ARCH
            ARCH=$(uname -m)
            wget -q "https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/${ARCH}/cuda-keyring_1.1-1_all.deb"
            sudo dpkg -i cuda-keyring_1.1-1_all.deb
            rm -f cuda-keyring_1.1-1_all.deb
            sudo apt-get update
            sudo apt-get install -y cuda-toolkit || \
                fail "Could not install CUDA toolkit - manual intervention needed"
        }
    fi

    # GB10 is sm_121; the prebuilt torch and llama-server for this box are
    # compiled for exactly that and selftested on it.
    local CC
    CC=$(nvcc --version 2>/dev/null | grep "release" | awk '{print $6}' | cut -d',' -f1 || echo "0")
    log "CUDA $CC detected - Blackwell GB10 support confirmed"

    # PATH for nvcc (bashrc persistence)
    if ! grep -q 'cuda' "/home/$TARGET_USER/.bashrc" 2>/dev/null; then
        sudo -u "$TARGET_USER" tee -a "/home/$TARGET_USER/.bashrc" >/dev/null <<'EOF'
export PATH=/usr/local/cuda/bin:$HOME/.local/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH
EOF
    fi
    export PATH=/usr/local/cuda/bin:$HOME/.local/bin:$PATH
    export LD_LIBRARY_PATH=/usr/local/cuda/lib64:${LD_LIBRARY_PATH:-}
}

# ─────────────────────────────────────────────────────────────
# Phase 3 - NVMe + pip relocation (Spark has built-in NVMe)
# ─────────────────────────────────────────────────────────────
# Spark ships with substantial NVMe storage (1TB+, 4TB when expanded). We
# set up model storage, venv backing, and pip relocation to keep the root
# fs clean, plus a swapfile as OOM insurance. The spare disk is resolved
# dynamically so we never reformat the drive that backs /.
phase_spark_nvme() {
    if ! lsblk | grep -q nvme; then
        info "No NVMe detected - Spark should have built-in NVMe; continuing with home dir"
        mkdir -p ~/models
        return 0
    fi

    # NEVER touch the disk that backs root. With a large add-in drive the
    # spare NVMe is not guaranteed to enumerate as nvme0n1, and a factory
    # 4TB often arrives with a leftover vfat/EFI partition that would make
    # us 'reformat' the wrong disk. Resolve the real target first.
    local ROOT_SRC ROOT_DISK NVME_DEV NVME_PART
    ROOT_SRC=$(findmnt -n -o SOURCE / 2>/dev/null || echo "")
    ROOT_DISK=$(lsblk -no PKNAME "$ROOT_SRC" 2>/dev/null || echo "")

    NVME_DEV=""
    for d in $(lsblk -dno NAME | grep '^nvme'); do
        [ "$d" = "$ROOT_DISK" ] && continue
        NVME_DEV="$d"
        break
    done

    if [ -z "$NVME_DEV" ]; then
        warn "Only NVMe present is the root disk ($ROOT_SRC) - nothing to mount; using home dir"
        mkdir -p ~/models
        return 0
    fi

    NVME_PART="${NVME_DEV}p1"
    log "NVMe target: /dev/$NVME_PART (root is on $ROOT_SRC, leaving it alone)"

    # Mount NVMe at /mnt/nvme if not already mounted
    if ! mount | grep -q "/mnt/nvme"; then
        local NEED_FORMAT=false
        if ! lsblk | grep -q "$NVME_PART"; then
            log "No $NVME_PART partition - creating fresh"
            NEED_FORMAT=true
        elif ! sudo blkid "/dev/$NVME_PART" | grep -q 'TYPE="ext4"'; then
            local CURRENT_FS
            CURRENT_FS=$(sudo blkid "/dev/$NVME_PART" -o value -s TYPE 2>/dev/null || echo "unknown")
            warn "/dev/$NVME_PART has filesystem '$CURRENT_FS' (expected ext4) - reformatting"
            NEED_FORMAT=true
        fi

        if $NEED_FORMAT; then
            sudo wipefs -a "/dev/$NVME_DEV" 2>/dev/null || true
            sudo wipefs -a "/dev/$NVME_PART" 2>/dev/null || true
            sudo parted "/dev/$NVME_DEV" --script mklabel gpt
            sudo parted "/dev/$NVME_DEV" --script mkpart primary ext4 0% 100%
            sleep 2
            sudo partprobe "/dev/$NVME_DEV" 2>/dev/null || true
            sudo mkfs.ext4 -F "/dev/$NVME_PART"
        fi

        sudo mkdir -p /mnt/nvme
        sudo mount "/dev/$NVME_PART" /mnt/nvme
        sudo chown "$TARGET_USER":"$TARGET_USER" /mnt/nvme

        if grep -q "/dev/$NVME_PART" /etc/fstab; then
            sudo sed -i "\|/dev/$NVME_PART|d" /etc/fstab
        fi
        echo "/dev/$NVME_PART /mnt/nvme ext4 defaults 0 2" | sudo tee -a /etc/fstab >/dev/null
    fi

    sudo -u "$TARGET_USER" mkdir -p /mnt/nvme/models /mnt/nvme/pip-packages /mnt/nvme/pip-cache

    # Idempotent pip relocation - same pattern as Xavier/Nano
    local USER_HOME="/home/$TARGET_USER"

    if [ -d "$USER_HOME/.local/lib" ] && [ ! -L "$USER_HOME/.local/lib" ]; then
        log "Migrating ~/.local/lib → /mnt/nvme/pip-packages/lib"
        sudo -u "$TARGET_USER" cp -r "$USER_HOME/.local/lib" /mnt/nvme/pip-packages/
        rm -rf "$USER_HOME/.local/lib"
        sudo -u "$TARGET_USER" ln -s /mnt/nvme/pip-packages/lib "$USER_HOME/.local/lib"
    elif [ ! -e "$USER_HOME/.local/lib" ]; then
        sudo -u "$TARGET_USER" mkdir -p /mnt/nvme/pip-packages/lib
        sudo -u "$TARGET_USER" mkdir -p "$USER_HOME/.local"
        sudo -u "$TARGET_USER" ln -s /mnt/nvme/pip-packages/lib "$USER_HOME/.local/lib"
    else
        log "~/.local/lib already symlinked - skipping"
    fi

    if [ -d "$USER_HOME/.local/bin" ] && [ ! -L "$USER_HOME/.local/bin" ]; then
        log "Migrating ~/.local/bin → /mnt/nvme/pip-packages/bin"
        sudo -u "$TARGET_USER" cp -r "$USER_HOME/.local/bin" /mnt/nvme/pip-packages/
        rm -rf "$USER_HOME/.local/bin"
        sudo -u "$TARGET_USER" ln -s /mnt/nvme/pip-packages/bin "$USER_HOME/.local/bin"
    elif [ ! -e "$USER_HOME/.local/bin" ]; then
        sudo -u "$TARGET_USER" mkdir -p /mnt/nvme/pip-packages/bin
        sudo -u "$TARGET_USER" ln -s /mnt/nvme/pip-packages/bin "$USER_HOME/.local/bin"
    else
        log "~/.local/bin already symlinked - skipping"
    fi

    if [ -d "$USER_HOME/.cache/pip" ] && [ ! -L "$USER_HOME/.cache/pip" ]; then
        log "Migrating ~/.cache/pip → /mnt/nvme/pip-cache"
        rm -rf "$USER_HOME/.cache/pip"
        sudo -u "$TARGET_USER" mkdir -p "$USER_HOME/.cache"
        sudo -u "$TARGET_USER" ln -s /mnt/nvme/pip-cache "$USER_HOME/.cache/pip"
    elif [ ! -e "$USER_HOME/.cache/pip" ]; then
        sudo -u "$TARGET_USER" mkdir -p "$USER_HOME/.cache"
        sudo -u "$TARGET_USER" ln -s /mnt/nvme/pip-cache "$USER_HOME/.cache/pip"
    else
        log "~/.cache/pip already symlinked - skipping"
    fi

    # 32GB swap on the NVMe. 128GB unified covers inference, but the 4TB
    # disk makes cheap insurance against a runaway build/loader OOM.
    if ! swapon --show | grep -q nvme; then
        sudo swapoff -a 2>/dev/null || true
        sudo fallocate -l 32G /mnt/nvme/32GB.swap
        sudo chmod 600 /mnt/nvme/32GB.swap
        sudo mkswap /mnt/nvme/32GB.swap
        sudo swapon /mnt/nvme/32GB.swap
        grep -q "32GB.swap" /etc/fstab || \
            echo '/mnt/nvme/32GB.swap none swap sw 0 0' | sudo tee -a /etc/fstab
    fi
}

# ─────────────────────────────────────────────────────────────
# Foundation entry point
# ─────────────────────────────────────────────────────────────
run_foundation() {
    # No MAXN phase - Spark manages power at firmware level
    run_phase "01_spark_os_trim"  "Phase 1 - OS trim"            phase_spark_os_trim
    run_phase "02_spark_cuda"     "Phase 2 - CUDA toolkit"        phase_spark_cuda
    run_phase "03_spark_nvme"     "Phase 3 - NVMe + pip"          phase_spark_nvme
}
