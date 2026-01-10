#!/bin/bash
set -e

# =============================================================================
# PLEX-OS BUILD SCRIPT (Debian Bookworm + Cage + PlexHTPC)
# =============================================================================
# WARNING: This script requires root privileges.
# USAGE: sudo ./build_plex_os.sh
# =============================================================================

# Configuration
OS_NAME="plex-os"
WORK_DIR="$(pwd)/build_work"
CHROOT_DIR="${WORK_DIR}/chroot"
IMAGE_DIR="${WORK_DIR}/image"
ISO_NAME="${OS_NAME}.iso"
DEBIAN_MIRROR="http://deb.debian.org/debian/"
DEBIAN_RELEASE="bookworm"

# Check for root
if [ "$(id -u)" -ne 0 ]; then
    echo "Please run as root: sudo ./build_plex_os.sh"
    exit 1
fi

echo "--- [1/7] Checking Dependencies ---"
# Added mtools and dosfstools for EFI partition creation
apt-get update
apt-get install -y debootstrap squashfs-tools xorriso grub-pc-bin grub-efi-amd64-bin mtools dosfstools

echo "--- [2/7] Cleaning previous builds ---"
if [ -d "$WORK_DIR" ]; then
    # Unmount everything to be safe
    umount "$CHROOT_DIR/proc" 2>/dev/null || true
    umount "$CHROOT_DIR/sys" 2>/dev/null || true
    umount "$CHROOT_DIR/dev/pts" 2>/dev/null || true
    umount "$CHROOT_DIR/dev" 2>/dev/null || true
    rm -rf "$WORK_DIR"
fi
mkdir -p "$CHROOT_DIR"
mkdir -p "$IMAGE_DIR"

echo "--- [3/7] Bootstrapping Debian ${DEBIAN_RELEASE} ---"
debootstrap --arch=amd64 --variant=minbase "$DEBIAN_RELEASE" "$CHROOT_DIR" "$DEBIAN_MIRROR"

echo "--- [4/7] Configuring the OS (Chroot) ---"

mount --bind /proc "$CHROOT_DIR/proc"
mount --bind /sys "$CHROOT_DIR/sys"
mount --bind /dev "$CHROOT_DIR/dev"
mount --bind /dev/pts "$CHROOT_DIR/dev/pts"

cat <<EOF > "$CHROOT_DIR/configure_internal.sh"
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

# 1. Install Basic System & Kernel
apt-get update
apt-get install -y --no-install-recommends \
    linux-image-amd64 systemd-sysv live-boot \
    network-manager net-tools wireless-tools \
    sudo curl ca-certificates locales \
    grub-pc-bin grub-efi-amd64-bin grub-efi-ia32-bin \
    iputils-ping

# 2. Install Audio, Graphics, Kiosk (Cage) & Snapd
apt-get install -y --no-install-recommends \
    cage xwayland \
    pipewire wireplumber \
    mesa-vulkan-drivers libgl1-mesa-dri \
    snapd \
    dbus-user-session \
    libpam-systemd \
    pciutils mesa-utils

# 3. Configure Locales
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/default/locale

# 4. Set Hostname & Hosts file
echo "${OS_NAME}" > /etc/hostname
cat <<HOSTS > /etc/hosts
127.0.0.1   localhost
127.0.1.1   ${OS_NAME}
::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
HOSTS

# 5. Create 'plex' user
useradd -m -s /bin/bash -G sudo,video,audio,render,plugdev plex
echo "plex:plex" | chpasswd
echo "plex ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/plex

# 6. (Configuration for Snap happens at runtime)

# 7. Auto-Login
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat <<SERVICE > /etc/systemd/system/getty@tty1.service.d/override.conf
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin plex --noclear %I \$TERM
SERVICE

# 8. Cage Launcher
cat <<'LAUNCH' > /home/plex/launch-kiosk.sh
#!/bin/bash
set -e

# Add Snap binaries to PATH
export PATH=\$PATH:/snap/bin

# Fix for QEMU/VMs and some hardware (cursor visibility and software fallback)
export WLR_NO_HARDWARE_CURSORS=1
export WLR_RENDERER_ALLOW_SOFTWARE=1

# Ensure XDG_RUNTIME_DIR is set (required for Wayland/Cage)
if [ -z "\$XDG_RUNTIME_DIR" ]; then
    export XDG_RUNTIME_DIR="/tmp/plex-runtime-\$(id -u)"
    if [ ! -d "\$XDG_RUNTIME_DIR" ]; then
        mkdir -p "\$XDG_RUNTIME_DIR"
        chmod 700 "\$XDG_RUNTIME_DIR"
    fi
fi

# Install Plex HTPC (Snap) if missing
# Snaps require systemd, so we install on first boot instead of build time
if ! snap list plex-htpc >/dev/null 2>&1; then
    echo "Plex HTPC not found. Waiting for internet to install..."
    until ping -c1 google.com >/dev/null 2>&1; do 
        sleep 2
    done
    
    echo "Preparing Snap environment..."
    # Fix "snapd too old" error by installing core first
    sudo snap install core
    # Ensure snapd itself is up to date
    sudo snap refresh snapd || true
    
    echo "Installing Plex HTPC..."
    sudo snap install plex-htpc
fi

# Run Plex via Cage
exec cage -s -- snap run plex-htpc
LAUNCH
chmod +x /home/plex/launch-kiosk.sh
chown plex:plex /home/plex/launch-kiosk.sh

# 9. Bash Profile
cat <<PROFILE >> /home/plex/.bash_profile
if [[ -z \$DISPLAY ]] && [[ \$(tty) = /dev/tty1 ]]; then
    ./launch-kiosk.sh
fi
PROFILE

apt-get clean
rm -rf /var/lib/apt/lists/*
EOF

chmod +x "$CHROOT_DIR/configure_internal.sh"
chroot "$CHROOT_DIR" /configure_internal.sh
rm "$CHROOT_DIR/configure_internal.sh"

echo "--- [5/7] Packing Root Filesystem (SquashFS) ---"
umount "$CHROOT_DIR/proc"
umount "$CHROOT_DIR/sys"
umount "$CHROOT_DIR/dev/pts"
umount "$CHROOT_DIR/dev"

mkdir -p "$IMAGE_DIR/live"
mksquashfs "$CHROOT_DIR" "$IMAGE_DIR/live/filesystem.squashfs" -comp xz -noappend

echo "--- [6/7] Configuring Hybrid Bootloader (BIOS + UEFI) ---"
# Copy Kernel
cp "$CHROOT_DIR/boot/vmlinuz-"* "$IMAGE_DIR/live/vmlinuz"
cp "$CHROOT_DIR/boot/initrd.img-"* "$IMAGE_DIR/live/initrd"

mkdir -p "$IMAGE_DIR/boot/grub"

# Create grub.cfg
cat <<GRUB > "$IMAGE_DIR/boot/grub/grub.cfg"
search --set=root --file /live/vmlinuz
insmod all_video
set default=0
set timeout=5

menuentry "Plex OS" {
    linux /live/vmlinuz boot=live quiet splash
    initrd /live/initrd
}
GRUB

# --- UEFI SETUP ---
mkdir -p "$IMAGE_DIR/EFI/BOOT"
grub-mkstandalone \
    --format=x86_64-efi \
    --output="$IMAGE_DIR/EFI/BOOT/BOOTX64.EFI" \
    --locales="" \
    --fonts="" \
    "boot/grub/grub.cfg=$IMAGE_DIR/boot/grub/grub.cfg"

# Create EFI Partition Image
dd if=/dev/zero of="$IMAGE_DIR/boot/grub/efi.img" bs=1M count=5
mkfs.vfat "$IMAGE_DIR/boot/grub/efi.img" >/dev/null
mcopy -s -i "$IMAGE_DIR/boot/grub/efi.img" "$IMAGE_DIR/EFI" ::

# --- BIOS SETUP ---
# We use the grub modules FROM THE CHROOT to ensure compatibility
GRUB_LIB_DIR="$CHROOT_DIR/usr/lib/grub/i386-pc"

if [ ! -d "$GRUB_LIB_DIR" ]; then
    echo "Error: GRUB i386-pc not found in chroot. Did install fail?"
    exit 1
fi

# Build core.img for BIOS
grub-mkimage \
    --directory "$GRUB_LIB_DIR" \
    --prefix=/boot/grub \
    --format=i386-pc \
    --output="$IMAGE_DIR/boot/grub/core.img" \
    biosdisk iso9660 part_msdos part_gpt search_fs_uuid all_video normal linux

# Combine cdboot.img and core.img
cat "$GRUB_LIB_DIR/cdboot.img" "$IMAGE_DIR/boot/grub/core.img" > "$IMAGE_DIR/boot/grub/bios.img"

echo "--- [7/7] Generating Hybrid ISO ---"
xorriso \
    -as mkisofs \
    -iso-level 3 \
    -full-iso9660-filenames \
    -volid "PLEXOS" \
    -o "$ISO_NAME" \
    \
    -eltorito-boot boot/grub/bios.img \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
    \
    -eltorito-alt-boot \
    -e boot/grub/efi.img \
        -no-emul-boot \
        -isohybrid-gpt-basdat \
    \
    "$IMAGE_DIR"

echo "========================================================"
echo "Done! ISO created: $(pwd)/$ISO_NAME"
echo "========================================================"