#!/usr/bin/env bash
# ==============================================================================
# Beck-D/fedora-install-helper
# Pre-Install UI Patching, Post-Install Chroot, & LUKS Optimization
# ==============================================================================

set -euo pipefail

# Log everything (stdout+stderr) to a file as well as the console, so a failure
# at a bare TTY can still be diagnosed afterward.
exec > >(tee -a /tmp/fde-install.log) 2>&1

CHECKPOINT_FILE="/tmp/.install_phase1_complete"
PYTHON_SITE_DIR=$(python3 -c "import site; print(site.getsitepackages()[0])" 2>/dev/null || true)
if [ -z "${PYTHON_SITE_DIR:-}" ]; then
    # Glob-expand the fallback instead of using it as a literal path
    PYTHON_SITE_DIR=$(compgen -G "/usr/lib64/python3.*/site-packages" | head -n1)
    if [ -z "$PYTHON_SITE_DIR" ]; then
        echo "❌ Error: could not determine Python site-packages directory."
        exit 1
    fi
fi
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

    # Only target the Anaconda process itself, not every python3 on the system
    ANACONDA_PID=$(pgrep -f '/usr/bin/anaconda' || true)
    if [ -n "$ANACONDA_PID" ]; then
        echo "Killing active Anaconda instance (pid $ANACONDA_PID)..."
        kill "$ANACONDA_PID" || true
        sleep 1
    fi

    echo "Applying FDE base override..."
    if grep -q 'encryption_support = True' "${STORAGE_MOD_DIR}/bootloader/base.py"; then
        echo "  (already patched, skipping)"
    else
        sed -i.bak 's/encryption_support = False/encryption_support = True/g' \
            "${STORAGE_MOD_DIR}/bootloader/base.py"
    fi

    echo "Injecting smart /boot-only PBKDF2 hook..."
    if grep -q "smart_luks_init" "${STORAGE_MOD_DIR}/initialization.py"; then
        echo "  (already patched, skipping)"
    else
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
    fi

    echo "Enabling GRUB2 cryptodisk in generation template..."
    if grep -q "GRUB_ENABLE_CRYPTODISK" "${STORAGE_MOD_DIR}/bootloader/grub2.py"; then
        echo "  (already patched, skipping)"
    else
        sed -i.bak 's/"GRUB_DISABLE_SUBMENU": "true",/"GRUB_DISABLE_SUBMENU": "true",\n        "GRUB_ENABLE_CRYPTODISK": "y",/g' \
            "${STORAGE_MOD_DIR}/bootloader/grub2.py"
    fi

    echo "--- Verification Check ---"
    if ! grep -q 'encryption_support = True' "${STORAGE_MOD_DIR}/bootloader/base.py"; then
        echo "❌ Error: encryption_support patch did not apply (upstream string may have changed)."
        exit 1
    fi
    if ! grep -q "GRUB_ENABLE_CRYPTODISK" "${STORAGE_MOD_DIR}/bootloader/grub2.py"; then
        echo "❌ Error: GRUB cryptodisk patch did not apply."
        exit 1
    fi
    grep "encryption_support =" "${STORAGE_MOD_DIR}/bootloader/base.py"
    grep -A 8 "from blivet.static_data import luks_data" "${STORAGE_MOD_DIR}/initialization.py"
    grep "GRUB_ENABLE_CRYPTODISK" "${STORAGE_MOD_DIR}/bootloader/grub2.py"
    echo "--------------------------"

    # Save state checkpoint
    touch "$CHECKPOINT_FILE"

    echo -e "\nPatches successfully applied!"
    echo "Relaunching Anaconda GUI..."
    setsid anaconda >/tmp/anaconda-relaunch.log 2>&1 < /dev/null &
    disown

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
    # Ensure bind mounts are always torn down, even on failure mid-chroot
    trap 'umount "$TARGET_ROOT/dev" "$TARGET_ROOT/proc" "$TARGET_ROOT/sys" 2>/dev/null || true' EXIT
    mount --bind /dev "$TARGET_ROOT/dev"
    mount --bind /proc "$TARGET_ROOT/proc"
    mount --bind /sys "$TARGET_ROOT/sys"
    cp /etc/resolv.conf "$TARGET_ROOT/etc/resolv.conf"

    # Resolve root's mapped device from the live mount table (more robust than
    # re-parsing fstab's UUID=/LABEL= syntax from inside the chroot)
    ROOT_MAPPED_DEV=$(findmnt -n -o SOURCE "$TARGET_ROOT")
    if [ -z "$ROOT_MAPPED_DEV" ]; then
        echo "❌ Error: could not resolve source device for $TARGET_ROOT via findmnt."
        exit 1
    fi
    ROOT_MAPPER_NAME=$(basename "$ROOT_MAPPED_DEV")
    echo "Resolved root mapping: $ROOT_MAPPER_NAME ($ROOT_MAPPED_DEV)"

    echo "Entering chroot environment to execute system configuration..."
    chroot "$TARGET_ROOT" /usr/bin/env ROOT_MAPPER_NAME="$ROOT_MAPPER_NAME" bash << 'CHROOT_EOF'
        set -euo pipefail
        echo "--> [1/4] Downloading slimmed down GNOME packages & Intel Wi-Fi firmware..."
        dnf install -y gnome-shell gdm nautilus gnome-terminal --setopt=install_weak_deps=False
        dnf install -y NetworkManager-wifi linux-firmware iwlwifi-mvm-firmware

        echo "--> [2/4] Installing Clevis/TPM2 tooling for automatic root unlock..."
        dnf install -y clevis clevis-luks clevis-dracut tpm2-tools

        if [ ! -e /dev/tpmrm0 ] && [ ! -e /dev/tpm0 ]; then
            echo "❌ Error: no TPM2 device found (/dev/tpmrm0 or /dev/tpm0)."
            echo "   Enable the TPM in firmware/BIOS, or re-run without TPM binding."
            exit 1
        fi

        echo "--> [3/4] Binding root volume to the TPM2 (Clevis) so it unlocks automatically..."
        echo "⚠️  PROMPT: Type your main encryption passphrase to authorize the new TPM2 binding:"

        # ROOT_MAPPER_NAME was resolved outside the chroot via findmnt and passed in
        if [ -z "${ROOT_MAPPER_NAME:-}" ]; then
            echo "❌ Error: ROOT_MAPPER_NAME was not passed into the chroot environment."
            exit 1
        fi

        # Ask cryptsetup for the actual underlying LUKS block device for that mapping,
        # since fstab/blkid only ever see the already-decrypted device
        ROOT_DEVICE=$(cryptsetup status "$ROOT_MAPPER_NAME" | awk '/device:/ {print $2}')

        if [ -z "$ROOT_DEVICE" ] || [ ! -b "$ROOT_DEVICE" ]; then
            echo "❌ Error: could not resolve underlying LUKS block device for mapping '$ROOT_MAPPER_NAME'."
            exit 1
        fi

        echo "Resolved root LUKS device: $ROOT_DEVICE (mapping: $ROOT_MAPPER_NAME)"

        # Bind to PCR 7 (Secure Boot policy state) only. This is the minimal,
        # least-brittle choice — it survives kernel/initrd updates. Sealing to
        # additional PCRs (e.g. 0,2,4) ties the binding to firmware/bootloader
        # measurements too, which is stronger but requires re-enrolling after
        # every firmware or GRUB update.
        clevis luks bind -y -d "$ROOT_DEVICE" tpm2 '{"pcr_bank":"sha256","pcr_ids":"7"}'

        if ! clevis luks list -d "$ROOT_DEVICE" | grep -q tpm2; then
            echo "❌ Error: Clevis TPM2 binding did not register on $ROOT_DEVICE."
            exit 1
        fi
        echo "Clevis TPM2 binding confirmed on $ROOT_DEVICE."

        echo "--> Enabling the Clevis dracut module for automatic unlock at boot..."
        echo 'add_dracutmodules+=" clevis "' > /etc/dracut.conf.d/50-clevis.conf

        echo "--> Restoring SELinux contexts on newly written files..."
        if command -v restorecon >/dev/null 2>&1; then
            restorecon -v /etc/dracut.conf.d/50-clevis.conf || true
        fi

        dracut --regenerate-all --force

        echo "--> [4/4] Setting graphical environment default boot properties..."
        systemctl enable gdm
        systemctl set-default graphical.target
CHROOT_EOF

    echo "Exiting target system shell cleanly..."
    echo "Unmounting virtualization structures..."
    # (handled by the EXIT trap set above, so this happens even on failure)

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
