#!/bin/bash
# ══════════════════════════════════════════════════════════════
# nano/foundation.sh — Orin Nano (jp6/R36) OS prereq phases
#
# Sourced by seren-setup.sh. Defines run_foundation() for Nano.
#
# Nano is much lighter than Xavier:
#   - Python 3.10 native via JetPack 6 (no source build needed)
#   - SQLite 3.37+ from Ubuntu 22.04 (good enough for ChromaDB)
#   - CUDA 12.6 already installed; just need cuda-nvcc-12-6 explicitly
#   - JetPack 6 ships everything we need at the OS level
#
# Phases:
#   01_nano_os_trim    — disable bloat, install build essentials
#   02_nano_cuda_nvcc  — ensure cuda-nvcc-12-6 (often missing from base flash)
#   03_nano_nvme       — mount NVMe + swap + pip relocation (if NVMe present)
# ══════════════════════════════════════════════════════════════

# ─────────────────────────────────────────────────────────────
# Phase 1 — OS trim (lighter than Xavier, Ubuntu 22.04 base)
# ─────────────────────────────────────────────────────────────
phase_nano_os_trim() {
    sudo systemctl set-default multi-user.target
    sudo systemctl disable gdm3.service lightdm.service 2>/dev/null || true

    local DISABLE_SERVICES=(
        snapd.service snapd.socket snapd.seeded.service
        ModemManager.service bluetooth.service
        cups.service cups-browsed.service
        unattended-upgrades.service whoopsie.service apport.service
        avahi-daemon.service power-profiles-daemon.service thermald.service
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
    sudo systemctl disable --now nvzramconfig.service 2>/dev/null || true
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
        python3.10 python3.10-dev python3.10-venv \
        netcat software-properties-common jq

    # Verify python3.10 is actually there (it should be, but warn loud if not)
    if ! command -v python3.10 &>/dev/null; then
        fail "python3.10 not found after apt install — JetPack 6 should ship this"
        return 1
    fi
    log "python3.10: $(python3.10 --version)"

    sudo apt autoremove -y && sudo apt autoclean && sudo apt clean
}

# ─────────────────────────────────────────────────────────────
# Phase 2 — Ensure cuda-nvcc-12-6 is installed
# ─────────────────────────────────────────────────────────────
# JetPack 6 ships CUDA 12.6 runtime but cuda-nvcc-12-6 is sometimes a
# separate package that doesn't get installed by the base flash.
# Without it, llama.cpp / pytorch can't compile against CUDA.
phase_nano_cuda_nvcc() {
    if command -v nvcc &>/dev/null; then
        local NVCC_VER; NVCC_VER=$(nvcc --version 2>/dev/null | grep release | awk '{print $6}' | cut -d',' -f1)
        log "nvcc already installed: $NVCC_VER"
        return 0
    fi

    log "Installing cuda-nvcc-12-6 explicitly..."
    sudo apt install -y cuda-nvcc-12-6 2>/dev/null || {
        warn "cuda-nvcc-12-6 not found via apt — adding NVIDIA CUDA repo..."
        cd /tmp
        wget -q https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/arm64/cuda-keyring_1.1-1_all.deb
        sudo dpkg -i cuda-keyring_1.1-1_all.deb
        rm -f cuda-keyring_1.1-1_all.deb
        sudo apt-get update
        sudo apt-get install -y cuda-nvcc-12-6 || \
            fail "Could not install cuda-nvcc-12-6 — manual intervention needed"
    }

    # PATH for nvcc (bashrc persistence)
    if ! grep -q 'cuda-12.6/bin' "/home/$TARGET_USER/.bashrc" 2>/dev/null; then
        sudo -u "$TARGET_USER" tee -a "/home/$TARGET_USER/.bashrc" >/dev/null <<'EOF'
export PATH=/usr/local/cuda-12.6/bin:$HOME/.local/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/cuda-12.6/lib64:$LD_LIBRARY_PATH
EOF
    fi
    export PATH=/usr/local/cuda-12.6/bin:$HOME/.local/bin:$PATH
    export LD_LIBRARY_PATH=/usr/local/cuda-12.6/lib64:${LD_LIBRARY_PATH:-}
}

# ─────────────────────────────────────────────────────────────
# Phase 3 — NVMe + swap + pip relocation (only if NVMe present)
# ─────────────────────────────────────────────────────────────
# Nano often has NVMe but isn't required for it (microSD boot is supported).
# If no NVMe, skip this phase — the Nano's onboard storage is bigger than
# Xavier's 32GB eMMC, so it's less critical.
phase_nano_nvme() {
    if ! lsblk | grep -q nvme0n1; then
        info "No NVMe detected — skipping NVMe phase (Nano has more onboard storage than Xavier)"
        mkdir -p ~/models
        return 0
    fi

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

    # 8GB swap on NVMe (smaller than Xavier — Nano is 8GB unified, less need)
    if ! swapon --show | grep -q nvme; then
        sudo swapoff -a 2>/dev/null || true
        sudo fallocate -l 8G /mnt/nvme/8GB.swap
        sudo chmod 600 /mnt/nvme/8GB.swap
        sudo mkswap /mnt/nvme/8GB.swap
        sudo swapon /mnt/nvme/8GB.swap
        grep -q "8GB.swap" /etc/fstab || \
            echo '/mnt/nvme/8GB.swap none swap sw 0 0' | sudo tee -a /etc/fstab
    fi

    sudo -u "$TARGET_USER" mkdir -p /mnt/nvme/models /mnt/nvme/pip-packages /mnt/nvme/pip-cache

    # Idempotent pip relocation — same pattern as Xavier
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
}

# ─────────────────────────────────────────────────────────────
# Foundation entry point
# ─────────────────────────────────────────────────────────────
run_foundation() {
    # Phase 0 runs first — Orin Nano Super gets a meaningful boost
    # (15W default → 25W MAXN). Skipped if --no-max-power.
    run_phase "00_max_power"      "Phase 0 — Max power mode"     phase_max_power
    run_phase "01_nano_os_trim"   "Phase 1 — OS trim"            phase_nano_os_trim
    run_phase "02_nano_cuda_nvcc" "Phase 2 — cuda-nvcc-12-6"     phase_nano_cuda_nvcc
    run_phase "03_nano_nvme"      "Phase 3 — NVMe + swap + pip"  phase_nano_nvme
}
