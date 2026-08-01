#!/bin/bash
# ══════════════════════════════════════════════════════════════
# xavier/foundation.sh — Xavier (jp5/R35) OS prereq phases
#
# Sourced by seren-prepare-node.sh. Defines run_foundation() which executes
# all OS-level prereqs needed before any service can be installed.
#
# Phases (jq-tracked, resumable):
#   01_os_trim       — Disable bloat, install build tools
#   02_sqlite        — SQLite 3.45 from source (Ubuntu 20.04 ships 3.31)
#   03_python310     — Python 3.10 altinstall from source
#   04_cmake         — pip cmake<4 (system 3.16 too old; 4.x breaks protobuf)
#   05_cuda          — CUDA 12.2 toolkit + cuda-compat-12-2 driver shim
#   06_nvme          — Mount NVMe, swap, relocate pip cache + .local
#
# Do not run directly.
# ══════════════════════════════════════════════════════════════

# ─────────────────────────────────────────────────────────────
# Phase 1 — OS trim
# ─────────────────────────────────────────────────────────────
phase_xavier_os_trim() {
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
    sudo dpkg --configure -a 2>/dev/null || true
    sudo apt --fix-broken install -y 2>/dev/null || true
    sudo apt purge -y \
        docker.io docker-ce containerd.io \
        nvidia-docker2 nvidia-container-toolkit nvidia-container-toolkit-base \
        nvidia-container-runtime libnvidia-container-tools libnvidia-container1 \
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
    sudo add-apt-repository --remove ppa:deadsnakes/ppa -y 2>/dev/null || true

    sudo apt update
    sudo apt-mark hold \
        nvidia-docker2 nvidia-container-toolkit nvidia-container-runtime \
        libnvidia-container-tools libnvidia-container1 \
        2>/dev/null || true
    sudo apt upgrade -y
    sudo apt install -y \
        build-essential git curl wget net-tools i2c-tools espeak-ng \
        libcurl4-openssl-dev libssl-dev libffi-dev libjpeg-dev zlib1g-dev \
        libopenblas-dev libopenblas-base libopenmpi-dev libomp-dev \
        python3-pip python3-dev python3-setuptools python3-wheel \
        netcat software-properties-common jq
    sudo apt autoremove -y && sudo apt autoclean && sudo apt clean
}

# ─────────────────────────────────────────────────────────────
# Phase 2 — SQLite 3.45 from source (ChromaDB needs >= 3.35)
# ─────────────────────────────────────────────────────────────
phase_xavier_sqlite() {
    local SQLITE_VERSION; SQLITE_VERSION=$(sqlite3 --version 2>/dev/null | awk '{print $1}' || echo "0")
    local REQUIRED="3.45.0"
    local LOWEST; LOWEST=$(printf '%s\n%s\n' "$REQUIRED" "$SQLITE_VERSION" | sort -V | head -n1)
    if [ "$LOWEST" = "$REQUIRED" ]; then
        log "SQLite $SQLITE_VERSION is sufficient (>= $REQUIRED)"
        return 0
    fi

    # Try prebuilt tarball first (much faster than source build)
    if [ -n "${STAGED_SQLITE_TARBALL:-}" ] && [ -f "$STAGED_SQLITE_TARBALL" ]; then
        log "Installing SQLite from prebuilt tarball..."
        sudo tar xzf "$STAGED_SQLITE_TARBALL" -C /usr/local
        sudo ldconfig
        # Verify
        local NEW_VER; NEW_VER=$(sqlite3 --version 2>/dev/null | awk '{print $1}' || echo "0")
        log "SQLite now reports: $NEW_VER"
        return 0
    fi

    log "SQLite $SQLITE_VERSION too old — building 3.45 from source (~10 min)"
    cd /tmp
    sudo rm -rf sqlite-autoconf-3450000 sqlite-autoconf-3450000.tar.gz 2>/dev/null || true
    wget -q --show-progress https://www.sqlite.org/2024/sqlite-autoconf-3450000.tar.gz
    tar xzf sqlite-autoconf-3450000.tar.gz
    cd sqlite-autoconf-3450000
    ./configure --prefix=/usr/local
    make -j"$(nproc)"
    sudo make install
    sudo ldconfig
    cd ~ && sudo rm -rf /tmp/sqlite-autoconf-3450000*
}

# ─────────────────────────────────────────────────────────────
# Phase 3 — Python 3.10 altinstall from source
# ─────────────────────────────────────────────────────────────
phase_xavier_python310() {
    if command -v python3.10 &>/dev/null; then
        log "python3.10 already installed: $(python3.10 --version)"
        return 0
    fi

    # Runtime libs needed regardless of install path
    sudo apt install -y \
        zlib1g-dev libncurses5-dev libgdbm-dev libnss3-dev \
        libreadline-dev libffi-dev libsqlite3-dev libbz2-dev liblzma-dev

    # Try prebuilt tarball first (~30 sec vs ~30 min source build)
    if [ -n "${STAGED_PYTHON_TARBALL:-}" ] && [ -f "$STAGED_PYTHON_TARBALL" ]; then
        log "Installing Python 3.10 from prebuilt tarball..."
        sudo tar xzf "$STAGED_PYTHON_TARBALL" -C /usr/local
        sudo ldconfig
        # Verify
        if command -v python3.10 &>/dev/null; then
            log "Python 3.10 now reports: $(python3.10 --version)"
            # Tarball doesn't include pip — bootstrap it via ensurepip.
            # (build-prebuilts.sh tarballs the result of `make install` which
            # doesn't run ensurepip. We could fix that in the builder, but
            # bootstrapping here makes us robust to old/missing tarballs.)
            if ! python3.10 -m pip --version &>/dev/null; then
                log "Bootstrapping pip into Python 3.10..."
                sudo python3.10 -m ensurepip --upgrade || \
                    warn "ensurepip failed — falling back to source build"
                # ensurepip installs into /usr/local — make sure user pip works after
                sudo python3.10 -m pip install --upgrade pip 2>/dev/null || true
            fi
            # Final sanity check — pip must be importable for downstream phases
            if python3.10 -m pip --version &>/dev/null; then
                log "pip ready: $(python3.10 -m pip --version)"
                return 0
            else
                warn "pip bootstrap failed — falling back to source build"
            fi
        else
            warn "Prebuilt tarball install didn't yield a working python3.10 — falling back to source"
        fi
    fi

    log "Building Python 3.10 from source (~30 min)"
    cd /tmp
    sudo rm -rf Python-3.10.14 Python-3.10.14.tgz 2>/dev/null || true
    wget -q --show-progress https://www.python.org/ftp/python/3.10.14/Python-3.10.14.tgz
    tar xzf Python-3.10.14.tgz
    cd Python-3.10.14
    ./configure --enable-optimizations --prefix=/usr/local
    make -j"$(nproc)"
    sudo make altinstall
    python3.10 -m ensurepip --upgrade
    python3.10 -m pip install --upgrade pip
    cd ~ && sudo rm -rf /tmp/Python-3.10.14*
}

# ─────────────────────────────────────────────────────────────
# Phase 4 — CMake (pip-installed, pinned <4 to avoid protobuf breakage)
# ─────────────────────────────────────────────────────────────
phase_xavier_cmake() {
    export PATH=$HOME/.local/bin:/usr/local/bin:$PATH
    local CMAKE_MINOR
    CMAKE_MINOR=$(cmake --version 2>/dev/null | head -1 | awk '{print $3}' | cut -d. -f2 || echo "0")
    if [ "$CMAKE_MINOR" -ge 18 ] 2>/dev/null; then
        log "CMake sufficient: $(cmake --version | head -1)"
        return 0
    fi
    sudo apt remove cmake -y 2>/dev/null || true
    python3.10 -m pip install --user "cmake<4"
    grep -q '.local/bin' ~/.bashrc || echo 'export PATH=$HOME/.local/bin:$PATH' >> ~/.bashrc
    export PATH=$HOME/.local/bin:$PATH
}

# ─────────────────────────────────────────────────────────────
# Phase 5 — CUDA 12.2 toolkit + driver compat shim
# ─────────────────────────────────────────────────────────────
phase_xavier_cuda() {
    local NVCC_VER
    NVCC_VER=$(nvcc --version 2>/dev/null | grep "release" | awk '{print $6}' | cut -d',' -f1 || echo "0")
    if [[ "$NVCC_VER" != *"12.2"* ]]; then
        cd /tmp
        wget -q https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2004/arm64/cuda-keyring_1.1-1_all.deb
        sudo dpkg -i cuda-keyring_1.1-1_all.deb
        rm -f cuda-keyring_1.1-1_all.deb
        sudo apt-get update
        sudo apt-get install -y cuda-toolkit-12-2
    fi
    # The compat shim is required because R35.x ships an older driver than
    # what CUDA 12.2 expects. Without this, libcuda.so.1 won't resolve at
    # runtime even though nvcc is happy at build time.
    sudo apt-get install -y cuda-compat-12-2 2>/dev/null || true

    # Persist PATH/LD_LIBRARY_PATH for the target user
    if ! grep -q 'cuda-12.2/compat' "/home/$TARGET_USER/.bashrc" 2>/dev/null; then
        sudo -u "$TARGET_USER" sed -i '/cuda-12/d' "/home/$TARGET_USER/.bashrc" 2>/dev/null || true
        sudo -u "$TARGET_USER" tee -a "/home/$TARGET_USER/.bashrc" >/dev/null <<'EOF'
export PATH=/usr/local/cuda-12.2/bin:$HOME/.local/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/cuda-12.2/compat:/usr/local/cuda-12.2/lib64:$LD_LIBRARY_PATH
EOF
    fi
    export PATH=/usr/local/cuda-12.2/bin:$HOME/.local/bin:$PATH
    export LD_LIBRARY_PATH=/usr/local/cuda-12.2/compat:/usr/local/cuda-12.2/lib64:${LD_LIBRARY_PATH:-}
}

# ─────────────────────────────────────────────────────────────
# Phase 6 — NVMe + swap + pip relocation
# ─────────────────────────────────────────────────────────────
# Xavier eMMC is only 32GB. Without this phase, pip caches and pytorch
# wheels will fill it. Symlinks ~/.local/{bin,lib} and ~/.cache/pip to NVMe.
phase_xavier_nvme() {
    if ! lsblk | grep -q nvme0n1; then
        warn "No NVMe detected — skipping NVMe phase. eMMC is 32GB, you WILL fill it."
        mkdir -p ~/models
        return 0
    fi

    # Mount NVMe at /mnt/nvme
    if ! mount | grep -q "/mnt/nvme"; then
        # Check partition exists AND is recognizable as ext4. A partition that
        # exists but has stale NTFS/other signatures will fail to mount and
        # we'd rather wipe + reformat than have downstream phases blow up.
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
            # Wipe ALL signatures from disk + partition before recreating, otherwise
            # leftover NTFS/MBR fragments confuse blkid + the kernel.
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

        # Update fstab — replace any existing nvme line (might be wrong fstype)
        if grep -q '/dev/nvme0n1p1' /etc/fstab; then
            sudo sed -i '\|/dev/nvme0n1p1|d' /etc/fstab
        fi
        echo '/dev/nvme0n1p1 /mnt/nvme ext4 defaults 0 2' | sudo tee -a /etc/fstab >/dev/null
    fi

    # 16GB swap on NVMe (eMMC swap wears the chip out fast)
    if ! swapon --show | grep -q nvme; then
        sudo swapoff -a 2>/dev/null || true
        sudo fallocate -l 16G /mnt/nvme/16GB.swap
        sudo chmod 600 /mnt/nvme/16GB.swap
        sudo mkswap /mnt/nvme/16GB.swap
        sudo swapon /mnt/nvme/16GB.swap
        grep -q "16GB.swap" /etc/fstab || \
            echo '/mnt/nvme/16GB.swap none swap sw 0 0' | sudo tee -a /etc/fstab
    fi

    sudo -u "$TARGET_USER" mkdir -p /mnt/nvme/models /mnt/nvme/pip-packages /mnt/nvme/pip-cache

    # Relocate ~/.local and ~/.cache/pip to NVMe via symlinks. Idempotent:
    # checks for existing symlinks before clobbering.
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
# Foundation entry point — called by seren-prepare-node.sh
# ─────────────────────────────────────────────────────────────
run_foundation() {
    # Phase 0 runs first so the rest of the install (especially the source
    # builds) gets the benefit of max clocks. Skipped if --no-max-power.
    run_phase "00_max_power"         "Phase 0 — Max power mode"     phase_max_power
    run_phase "01_xavier_os_trim"   "Phase 1 — OS trim"           phase_xavier_os_trim
    # SQLite is ALWAYS installed on Xavier. New Python tarballs (built with
    # --sqlite first, post 2026.04.29-xavier) bake in an rpath pointing at
    # /usr/local/lib for libsqlite3, so the shared object must be present
    # at runtime regardless of whether ChromaDB was flagged. Older Python
    # tarballs link against system libsqlite3 and don't need this — but
    # installing 3.45 anyway is harmless (~5MB on disk).
    run_phase "02_xavier_sqlite"    "Phase 2 — SQLite 3.45"        phase_xavier_sqlite
    run_phase "03_xavier_python310" "Phase 3 — Python 3.10"        phase_xavier_python310
    # NVMe must run BEFORE CMake. Phase 4 (CMake) does `pip install --user`
    # which writes to ~/.local/lib/python3.10. Phase 6 (NVMe) creates that
    # path as a symlink to /mnt/nvme/pip-packages/lib. Newer pip is strict
    # about target dirs existing, so without phase 6 first, pip errors out.
    # The phase IDs stay numbered as-is to preserve compat with state files
    # from existing installs — only execution order changes.
    run_phase "06_xavier_nvme"      "Phase 6 — NVMe + swap + pip"  phase_xavier_nvme
    run_phase "04_xavier_cmake"     "Phase 4 — CMake"              phase_xavier_cmake
    run_phase "05_xavier_cuda"      "Phase 5 — CUDA 12.2 + compat" phase_xavier_cuda
}
