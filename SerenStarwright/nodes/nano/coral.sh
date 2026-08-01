#!/bin/bash
# ══════════════════════════════════════════════════════════════
# nano/coral.sh — Install Coral M.2 TPU support (Nano)
#
# Same logic as xavier/coral.sh but uses jp6/orin tagged modules
# and --break-system-packages for pip on Ubuntu 22.04.
#
# Coral on Nano is the more common deployment — Nano boards often
# have an M.2 A+E slot perfect for the Coral card, and edge
# inference is the Nano's strength.
#
# REBOOT REQUIRED for kernel cmdline changes.
# ══════════════════════════════════════════════════════════════

install_coral() {
    local USER_HOME="/home/$TARGET_USER"

    # ── Hardware check (informational) ──
    if lspci 2>/dev/null | grep -qi "Global Unichip\|089a"; then
        log "Coral TPU detected on PCIe bus ✓"
    else
        warn "Coral TPU not detected on PCIe bus"
        warn "Make sure the M.2 A+E card is properly seated"
        warn "Continuing — module install doesn't require hardware present"
    fi

    # ── Verify staged modules ──
    if [ -z "${STAGED_GASKET_KO:-}" ] || [ ! -f "$STAGED_GASKET_KO" ]; then
        fail "Staged Coral gasket module missing. Prebuilts/build phase didn't run or failed."
        fail "Expected at: ${STAGED_GASKET_KO:-<unset>}"
        return 1
    fi
    if [ ! -f "$STAGED_APEX_KO" ]; then
        fail "Staged Coral apex module missing at: $STAGED_APEX_KO"
        return 1
    fi

    # ── Manifest kernel-version check (best-effort) ──
    if [ -n "${STAGED_CORAL_MANIFEST:-}" ] && [ -f "$STAGED_CORAL_MANIFEST" ]; then
        local PREBUILT_KERNEL
        PREBUILT_KERNEL=$(grep '^kernel=' "$STAGED_CORAL_MANIFEST" | cut -d= -f2)
        if [ -n "$PREBUILT_KERNEL" ] && [ "$PREBUILT_KERNEL" != "$KERNEL_VER" ]; then
            warn "Prebuilt was compiled against kernel $PREBUILT_KERNEL"
            warn "Your running kernel is        $KERNEL_VER"
            warn "Modules MAY load via vermagic forcing, but if modprobe fails,"
            warn "re-run seren-prepare-node.sh with --build to compile against current kernel."
        else
            log "Manifest kernel matches running kernel ✓"
        fi
    fi

    # ── Install modules ──
    local MODULE_DIR="/lib/modules/$KERNEL_VER/kernel/drivers/staging/gasket"
    log "Installing modules to $MODULE_DIR"
    sudo mkdir -p "$MODULE_DIR"
    sudo cp "$STAGED_GASKET_KO" "$MODULE_DIR/gasket.ko"
    sudo cp "$STAGED_APEX_KO"   "$MODULE_DIR/apex.ko"
    sudo chmod 644 "$MODULE_DIR/gasket.ko" "$MODULE_DIR/apex.ko"
    sudo depmod -a
    log "Modules installed and depmod refreshed ✓"

    if sudo modprobe gasket 2>/dev/null && sudo modprobe apex 2>/dev/null; then
        log "Modules loaded successfully ✓"
        [ -c /dev/apex_0 ] && log "/dev/apex_0 present ✓" || \
            warn "/dev/apex_0 not present — may need reboot for kernel cmdline"
        sudo modprobe -r apex 2>/dev/null || true
        sudo modprobe -r gasket 2>/dev/null || true
    else
        warn "modprobe failed — likely needs reboot for kernel cmdline"
    fi

    # ── Kernel cmdline (extlinux) ──
    local EXTLINUX="/boot/extlinux/extlinux.conf"
    if [ -f "$EXTLINUX" ]; then
        if ! grep -q "pcie_aspm=off" "$EXTLINUX"; then
            sudo sed -i '/^[[:space:]]*APPEND/ s/$/ pcie_aspm=off/' "$EXTLINUX"
            log "Added pcie_aspm=off to kernel cmdline ✓"
        else
            log "pcie_aspm=off already present ✓"
        fi
        if ! grep -q "gasket.dma_bit_mask=32" "$EXTLINUX"; then
            sudo sed -i '/^[[:space:]]*APPEND/ s/$/ gasket.dma_bit_mask=32/' "$EXTLINUX"
            log "Added gasket.dma_bit_mask=32 to kernel cmdline ✓"
        else
            log "gasket.dma_bit_mask=32 already present ✓"
        fi
    else
        warn "extlinux.conf not found at $EXTLINUX"
        warn "Manually add to bootloader cmdline: pcie_aspm=off gasket.dma_bit_mask=32"
    fi

    # ── Boot blacklist ──
    sudo tee /etc/modprobe.d/coral-blacklist.conf > /dev/null << 'EOF'
# Coral M.2 TPU — blacklisted at boot, loaded on demand
blacklist gasket
blacklist apex
EOF
    log "Boot blacklist installed ✓"

    # ── Udev rule ──
    sudo tee /etc/udev/rules.d/65-coral-tpu.rules > /dev/null << EOF
SUBSYSTEM=="apex", MODE="0660", GROUP="$TARGET_USER"
EOF
    sudo udevadm control --reload-rules
    log "Udev rule installed ✓"

    # ── Sudoers append ──
    if sudo grep -q "modprobe.*apex" /etc/sudoers.d/seren 2>/dev/null; then
        log "Sudoers already has modprobe rules for $TARGET_USER ✓"
    else
        log "Adding Coral modprobe rules to /etc/sudoers.d/seren..."
        sudo tee -a /etc/sudoers.d/seren > /dev/null << SUDOERS

# Coral TPU — on-demand load/unload
$TARGET_USER ALL=(root) NOPASSWD: /sbin/modprobe -r apex
$TARGET_USER ALL=(root) NOPASSWD: /sbin/modprobe -r gasket
$TARGET_USER ALL=(root) NOPASSWD: /sbin/modprobe apex
$TARGET_USER ALL=(root) NOPASSWD: /sbin/modprobe gasket
SUDOERS
        sudo chmod 440 /etc/sudoers.d/seren
        sudo visudo -cf /etc/sudoers.d/seren >/dev/null && log "Sudoers validated ✓" || \
            fail "Sudoers file failed validation"
    fi

    # ── Python libs (jp6 needs --break-system-packages) ──
    log "Installing pycoral + tflite-runtime under python3.10..."
    sudo -u "$TARGET_USER" python3.10 -m pip install --user --break-system-packages tflite-runtime 2>/dev/null || \
        warn "tflite-runtime via pip failed — may need manual install for aarch64"
    sudo -u "$TARGET_USER" python3.10 -m pip install --user --break-system-packages pycoral 2>/dev/null || \
        warn "pycoral via pip failed — may need manual install for aarch64"

    # ── Test helper ──
    sudo -u "$TARGET_USER" tee "$USER_HOME/test-coral.sh" > /dev/null << 'TESTSCRIPT'
#!/bin/bash
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo "Loading Coral modules..."
sudo modprobe gasket
sudo modprobe apex
sleep 2

if [ -c /dev/apex_0 ]; then
    echo -e "${GREEN}✓${NC} /dev/apex_0 exists — Coral TPU is alive!"
    echo ""
    echo "PCIe device:"
    lspci | grep -i "Global Unichip\|089a" || echo "  (not visible via lspci)"
    echo ""
    echo "Loaded modules:"
    lsmod | grep -E "gasket|apex"
    echo ""
    echo "Library check:"
    python3.10 -c "import tflite_runtime.interpreter as tflite; print('  tflite_runtime OK')" 2>/dev/null || echo "  tflite_runtime: NOT FOUND"
    python3.10 -c "from pycoral.utils import edgetpu; print('  pycoral OK')" 2>/dev/null || echo "  pycoral: NOT FOUND"
    echo ""
    echo "Unload to free RAM:"
    echo "  sudo modprobe -r apex && sudo modprobe -r gasket"
else
    echo -e "${RED}✗${NC} /dev/apex_0 not found"
    echo "Troubleshooting:"
    echo "  1. dmesg | grep -i 'apex\|gasket\|coral'"
    echo "  2. lspci | grep -i '089a'"
    echo "  3. cat /proc/cmdline | grep pcie_aspm"
    echo "  4. Did you reboot after seren-setup with --coral?"
fi
TESTSCRIPT
    sudo chmod +x "$USER_HOME/test-coral.sh"

    log "Coral TPU setup complete"
    log "REBOOT REQUIRED for kernel cmdline changes"
    log "After reboot: ~/test-coral.sh"
}
