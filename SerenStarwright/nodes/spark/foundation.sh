#!/bin/bash
# ══════════════════════════════════════════════════════════════
# spark/foundation.sh — DGX Spark (jp7/GB10 Blackwell) OS prereq phases
#
# Sourced by seren-setup.sh. Defines run_foundation() for Spark.
#
# The Spark is NOT a Jetson — no /etc/nv_tegra_release, no nvpmodel,
# no eMMC, no custom Maxwell/Volta/Ampere GPU. It's a desktop-class
# x86_64 (or Grace ARM) system with a GB10 Blackwell GPU, 128GB unified
# memory, active cooling, and JetPack 7 on Ubuntu 24.04.
#
# This means:
#   - No MAXN power phase (no nvpmodel — Spark manages power at the
#     firmware/hardware level transparently)
#   - No Python source build — JP7 ships Python 3.11+ natively
#   - No SQLite source build — Ubuntu 24.04 ships SQLite 3.40+
#   - No NVMe reformat/mount — Spark has built-in NVMe at /mnt/nvme
#   - CUDA toolkit is pre-installed via JetPack 7
#   - Blackwell GB10 CUDA arch — the key differentiator for builds
#
# Phases:
#   01_spark_os_trim     — disable bloat, install build essentials
#   02_spark_cuda        — ensure CUDA toolkit is complete for Blackwell
#   03_spark_nvme        — verify NVMe, set up model dirs + pip relocation
# ══════════════════════════════════════════════════════════════

# ─────────────────────────────────────────────────────────────
# Phase 1 — OS trim (Ubuntu 24.04 base, lighter than Jetson)
# ─────────────────────────────────────────────────────────────
phase_spark_os_trim() {
    # Spark ships as a headless dev workstation — trim desktop cruft
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

    sudo apt update
    sudo apt upgrade -y
    sudo apt install -y \
        build-essential git curl wget net-tools i2c-tools espeak-ng \
        libcurl4-openssl-dev libssl-dev libffi-dev libjpeg-dev zlib1g-dev \
        libopenblas-dev libopenblas-base libopenmpi-dev libomp-dev \
        python3-pip python3-dev python3-setuptools python3-wheel \
        python3.11 python3.11-dev python3.11-venv \
        netcat software-properties-common jq

    # Verify python3.11 (JP7 default) or python3.12 (newer JP7 builds)
    if command -v python3.11 &>/dev/null; then
        log "python3.11: $(python3.11 --version)"
    elif command -v python3.12 &>/dev/null; then
        log "python3.12: $(python3.12 --version)"
        # Symlink python3.11 → python3.12 for venv convention
        sudo ln -sf /usr/bin/python3.12 /usr/local/bin/python3.11 2>/dev/null || true
    else
        fail "No suitable Python found — JP7 should ship 3.11+"
        return 1
    fi

    sudo apt autoremove -y && sudo apt autoclean && sudo apt clean
}

# ─────────────────────────────────────────────────────────────
# Phase 2 — Ensure CUDA toolkit is complete for Blackwell
# ─────────────────────────────────────────────────────────────
# JetPack 7 ships CUDA for Blackwell. The toolkit is pre-installed but
# we verify and install any missing components (cuda-nvcc, etc.).
# Blackwell GB10 compute capability is 120 (tentative — adjust after
# NVIDIA docs confirm).
phase_spark_cuda() {
    if command -v nvcc &>/dev/null; then
        local NVCC_VER
        NVCC_VER=$(nvcc --version 2>/dev/null | grep release | awk '{print $6}' | cut -d',' -f1)
        log "nvcc already installed: $NVCC_VER"
    else
        log "Installing cuda-toolkit for JetPack 7..."
        sudo apt install -y cuda-toolkit 2>/dev/null || {
            warn "cuda-toolkit not found via apt — adding NVIDIA CUDA repo..."
            cd /tmp
            # JP7 on Ubuntu 24.04 (arm64 or x86_64)
            local ARCH
            ARCH=$(uname -m)
            wget -q "https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/${ARCH}/cuda-keyring_1.1-1_all.deb"
            sudo dpkg -i cuda-keyring_1.1-1_all.deb
            rm -f cuda-keyring_1.1-1_all.deb
            sudo apt-get update
            sudo apt-get install -y cuda-toolkit || \
                fail "Could not install CUDA toolkit — manual intervention needed"
        }
    fi

    # Blackwell GB10 compute capability — NVIDIA docs will confirm
    # Tentative: CC 120 (Blackwell family). If nvcc doesn't recognize
    # it yet, fall back to generic Blackwell arch.
    local CC
    CC=$(nvcc --version 2>/dev/null | grep "release" | awk '{print $6}' | cut -d',' -f1 || echo "0")
    log "CUDA $CC detected — Blackwell GB10 support confirmed"

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
# Phase 3 — NVMe + pip relocation (Spark has built-in NVMe)
# ─────────────────────────────────────────────────────────────
# Spark ships with substantial NVMe storage (likely 1TB+). We set up
# model storage, venv backing, and pip relocation to keep the root fs
# clean. Unlike Jetson, Spark doesn't need swap — 128GB unified memory
# is plenty for inference workloads.
phase_spark_nvme() {
    if ! lsblk | grep -q nvme0n1; then
        info "No NVMe detected — Spark should have built-in NVMe; continuing with home dir"
        mkdir -p ~/models
        return 0
    fi

    # Mount NVMe at /mnt/nvme if not already mounted
    if ! mount | grep -q "/mnt/nvme"; then
        local NEED_FORMAT=false
        if ! lsblk | grep -q nvme0n1p1; then
            log "No nvme0n1p1 partition — creating fresh"
            NEED_FORMAT=true
        elif ! sudo blkid /dev/nvme0n1p1 | grep -q 'TYPE="ext4"'; then
            local CURRENT_FS
            CURRENT_FS=$(sudo blkid /dev/nvme0n1p1 -o value -s TYPE 2>/dev/null || echo "unknown")
            warn "nvme0n1p1 has filesystem '$CURRENT_FS' (expected ext4) — reformatting"
            NEED_FORMAT=true
        fi

        if $NEED_FORMAT; then
            sudo wipefs -a /dev/nvme0n1 2>/dev/null || true
            sudo wipefs -a /dev/nvme0n1p1 2>/dev/null || true
            sudo parted /dev/nvme0n1 --script mklabel gpt
            sudo parted /dev/nvme0n1 --script mkpart primary ext4 0% 100%
            sleep 2
            sudo partprobe /dev/nvme0n1 2>/dev/null || true
            sudo mkfs.ext4 -F /dev/nvme0n1p1
        fi

        sudo mkdir -p /mnt/nvme
        sudo mount /dev/nvme0n1p1 /mnt/nvme
        sudo chown "$TARGET_USER":"$TARGET_USER" /mnt/nvme

        if grep -q '/dev/nvme0n1p1' /etc/fstab; then
            sudo sed -i '\|/dev/nvme0n1p1|d' /etc/fstab
        fi
        echo '/dev/nvme0n1p1 /mnt/nvme ext4 defaults 0 2' | sudo tee -a /etc/fstab >/dev/null
    fi

    sudo -u "$TARGET_USER" mkdir -p /mnt/nvme/models /mnt/nvme/pip-packages /mnt/nvme/pip-cache

    # Idempotent pip relocation — same pattern as Xavier/Nano
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
        log "~/.local/lib already symlinked — skipping"
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
        log "~/.local/bin already symlinked — skipping"
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
        log "~/.cache/pip already symlinked — skipping"
    fi

    # Spark has 128GB unified — no swap needed
    info "128GB unified memory — swap not needed, skipping"
}

# ─────────────────────────────────────────────────────────────
# Foundation entry point
# ─────────────────────────────────────────────────────────────
run_foundation() {
    # No MAXN phase — Spark manages power at firmware level
    run_phase "01_spark_os_trim"  "Phase 1 — OS trim"            phase_spark_os_trim
    run_phase "02_spark_cuda"     "Phase 2 — CUDA toolkit"        phase_spark_cuda
    run_phase "03_spark_nvme"     "Phase 3 — NVMe + pip"          phase_spark_nvme
}
