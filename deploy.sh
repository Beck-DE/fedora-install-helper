#!/usr/bin/env bash
# ==============================================================================
# Unified Fedora Netinstall FDE & Minimal GNOME Orchestrator
# Coordinates: Pre-Install UI Patching, Post-Install Chroot, & LUKS Optimization
# ==============================================================================

set -euo pipefail

CHECKPOINT_FILE="/tmp/.install_phase1_complete"
PYTHON_SITE_DIR=$(python3 -c "import site; print(site.getsitepackages()[0])" 2>/dev/null || echo "/usr/lib64/python3.*/site-packages")
STORAGE_MOD_DIR="${PYTHON_SITE_DIR}/pyanaconda/modules/storage"
TARGET_ROOT="/mnt/sysroot"

# --- HELPER: BUMP CONSOLE FONT ---
setup_console() {
    if [ -f /usr/bin/setfont ]; then
        echo "Bumping console font for readability..."
        setfont latarcyrheb-sun32 || true
    fi
}

# ==============================================================================
# PHASE 1: PRE-INSTALL PATCHING (RUNS FIRST)
# ==============================================================================
run_phase1() {
    setup_console
    echo "=== PHASE 1: Patching Installer Environment ==="

    if pidof python3 >/dev/null; then
        echo "Killing active Anaconda instance..."
        kill $(pidof python3) || true
        sleep 1
    fi

    echo "Applying FDE base override..."
    sed -i.bak 's/encryption_support = False/encryption_support = True/g' \
        "${STORAGE_MOD_DIR}/bootloader/base.py"

    echo "Injecting smart /boot-only PBKDF2 hook..."
    PYTHON_INJECTION=$(cat << 'EOF'
from blivet.devices.luks import LUKSDevice
orig_init = LUKSDevice.__init__
def smart_luks_init(self, *args, **kwargs):
    orig_init(self, *args, **kwargs)
    if getattr(self.format, "mountpoint", "") == "/boot":
        self.format.pbkdf_args = {"pbkdf": "pbkdf2"}
LUKSDevice.__init__ = smart_luks_init
EOF
)
    SED_APPEND_STRING=$(echo "$PYTHON_INJECTION" | sed ':a;N;$!ba;s/\n/\\n/g')
    sed -i.bak "/from blivet.static_data import luks_data/a ${SED_APPEND_STRING}" \
        "${STORAGE_MOD_DIR}/initialization.py"

    echo "Enabling GRUB2 cryptodisk in generation template..."
    sed -i.bak 's/"GRUB_DISABLE_SUBMENU": "true",/"GRUB_DISABLE_SUBMENU": "true",\n        "GRUB_ENABLE_CRYPTODISK": "y",/g' \
        "${STORAGE_MOD_DIR}/bootloader/grub2.py"

    echo "--- Verification Check ---"
    grep "encryption_support =" "${STORAGE_MOD_DIR}/bootloader/base.py"
    grep -A 8 "from blivet.static_data import luks_data" "${STORAGE_MOD_DIR}/initialization.py"
    grep "GRUB_ENABLE_CRYPTODISK" "${STORAGE_MOD_DIR}/bootloader/grub2.py"
    echo "--------------------------"

    # Save state checkpoint
    touch "$CHECKPOINT_FILE"

    echo -e "\nPatches successfully applied!"
    echo "Relaunching Anaconda GUI..."
    anaconda &
    
    echo -e "\n👉 ACTION REQUIRED:"
    echo "1. Press Ctrl + Alt + F6 to return to the graphical installer screen."
    echo "2. Perform your manual partitioning setup exactly as noted."
    echo "3. Begin installation. When the installation concludes completely,"
    echo "   return here (Ctrl + Alt + F2) and run this exact script again."
    exit 0
}

# ==============================================================================
# PHASE 2: POST-INSTALL CHROOT & OPTIMIZATION (RUNS SECOND)
# ==============================================================================
run_phase2() {
    setup_console
    echo "=== PHASE 2: Executing Post-Install Target Configuration ==="

    if [ ! -d "$TARGET_ROOT/etc" ]; then
        echo "❌ Error: $TARGET_ROOT/etc not found. Did the installation complete successfully?"
        exit 1
    fi

    echo "Binding host file systems to target environment..."
    mount --bind /dev "$TARGET_ROOT/dev"
    mount --bind /proc "$TARGET_ROOT/proc"
    mount --bind /sys "$TARGET_ROOT/sys"
    cp /etc/resolv.conf "$TARGET_ROOT/etc/resolv.conf"

    echo "Entering chroot environment to execute system configuration..."
    chroot "$TARGET_ROOT" /usr/bin/env bash << 'CHROOT_EOF'
        set -euo pipefail
        echo "--> [1/4] Downloading slimmed down GNOME packages & Intel Wi-Fi firmware..."
        dnf install -y gnome-shell gdm nautilus gnome-terminal --setopt=install_weak_deps=False
        dnf install -y NetworkManager-wifi linux-firmware iwlwifi-mvm-firmware

        echo "--> [2/4] Generating and locking down secure LUKS keyfile..."
        mkdir -p /etc/cryptsetup-keys.d
        dd bs=512 count=8 if=/dev/urandom out=/etc/cryptsetup-keys.d/fedora.key 2>/dev/null
        chmod 400 /etc/cryptsetup-keys.d/fedora.key

        echo "--> [3/4] Provisioning cryptographic keyslot onto root BTRFS volume container..."
        echo "⚠️  PROMPT: Type your main encryption passphrase to register the internal keyfile:"
        ROOT_DEVICE=$(awk '$2 == "/" {print $1}' /etc/fstab | sed 's/UUID=//' | xargs -I {} blkid -O device -U {})
        cryptsetup luksAddKey "$ROOT_DEVICE" /etc/cryptsetup-keys.d/fedora.key

        echo "--> Updating system crypttab layout mapping..."
        sed -i 's/\snone\sluks/ \/etc\/cryptsetup-keys.d\/fedora.key luks/g' /etc/crypttab

        echo "--> Injecting configuration hook to bake keys into early initramfs layer..."
        echo 'install_items+=" /etc/cryptsetup-keys.d/fedora.key "' > /etc/dracut.conf.d/99-lukshack.conf
        dracut --regenerate-all --force

        echo "--> [4/4] Setting graphical environment default boot properties..."
        systemctl enable gdm
        systemctl set-default graphical.target
CHROOT_EOF

    echo "Exiting target system shell cleanly..."
    echo "Unmounting virtualization structures..."
    umount "$TARGET_ROOT/dev" "$TARGET_ROOT/proc" "$TARGET_ROOT/sys"

    # Clean up state tracker
    rm -f "$CHECKPOINT_FILE"

    echo -e "\n🎉 PROCESS FULLY COMPLETE!"
    echo "👉 Press Ctrl + Alt + F6 to flip back to the graphical UI and safely click 'Reboot System'."
}

# --- CONTROL LOGIC ---
if [ ! -f "$CHECKPOINT_FILE" ]; then
    run_phase1
else
    run_phase2
fi
