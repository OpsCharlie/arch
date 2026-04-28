#!/bin/bash
set -e

cleanup() {
    set +e
    umount -R /mnt 2>/dev/null
    cryptsetup close cryptroot 2>/dev/null
}
trap cleanup ERR

echo "=== Arch Linux FULL AUTO INSTALL (VM/LAPTOP + GPU + SNAPSHOT + GRUB-BTRFS) ==="

DISK=$(lsblk -d -n -o NAME,TYPE | grep 'disk$' | awk '{print $1}' | head -1)
DEVICE="/dev/${DISK}"

echo "Using disk: $DEVICE"

read -r -s -p "Enter LUKS password: " LUKS_PW
echo
read -r -p "Enter username: " USERNAME
read -r -s -p "Enter user password: " USER_PW
echo

# -----------------------------
# VM or physical
# -----------------------------
SYSTEM_TYPE="physical"
if systemd-detect-virt -q 2>/dev/null; then
    SYSTEM_TYPE="vm"
fi
echo "[*] System type: $SYSTEM_TYPE"

# -----------------------------
# Partitioning
# -----------------------------
case "$DISK" in
    nvme*)
        EFI="${DEVICE}p1"
        LUKS_DEV="${DEVICE}p2"
        ;;
    *)
        EFI="${DEVICE}1"
        LUKS_DEV="${DEVICE}2"
        ;;
esac

parted --script "$DEVICE" \
    mklabel gpt \
    mkpart ESP fat32 1MiB 513MiB \
    set 1 esp on \
    mkpart cryptroot 513MiB 100%

mkfs.fat -F32 -n EFI "$EFI"

# -----------------------------
# SSD detection (for TRIM/discard)
# -----------------------------
IS_SSD=0

LUKS_OPEN_OPTS=""
DISCARD_CMDLINE=""
BTRFS_OPTS="noatime,compress=zstd:3,space_cache=v2"
if [ "$SYSTEM_TYPE" != "vm" ] && [ -r "/sys/block/${DISK}/queue/rotational" ] && [ "$(cat /sys/block/${DISK}/queue/rotational)" = "0" ]; then
    IS_SSD=1
    LUKS_OPEN_OPTS="--allow-discards --perf-no_read_workqueue --perf-no_write_workqueue"
    DISCARD_CMDLINE=":allow-discards"
    BTRFS_OPTS+=",ssd,discard=async"
else
    BTRFS_OPTS+=",autodefrag"
fi

echo "[*] SSD detected: $IS_SSD"
# -----------------------------
# LUKS
# -----------------------------
printf "%s" "$LUKS_PW" | cryptsetup luksFormat "$LUKS_DEV" -
# shellcheck disable=SC2086
printf "%s" "$LUKS_PW" | cryptsetup open $LUKS_OPEN_OPTS "$LUKS_DEV" cryptroot -

# -----------------------------
# BTRFS
# -----------------------------
mkfs.btrfs -L CRYPTROOT /dev/mapper/cryptroot
mount /dev/mapper/cryptroot /mnt

btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@log
btrfs subvolume create /mnt/@swap
btrfs subvolume create /mnt/@snapshots

umount /mnt

mount -o subvol=@ /dev/mapper/cryptroot /mnt
mkdir -p /mnt/{home,boot,swap,.snapshots,var/log}

mount -o subvol=@swap /dev/mapper/cryptroot /mnt/swap
btrfs filesystem mkswapfile --size 4g --uuid clear /mnt/swap/swapfile

mount -o subvol=@home /dev/mapper/cryptroot /mnt/home
mount -o subvol=@log /dev/mapper/cryptroot /mnt/var/log
mount -o subvol=@snapshots /dev/mapper/cryptroot /mnt/.snapshots
mount "$EFI" /mnt/boot

# -----------------------------
# GPU detect
# -----------------------------
detect_gpu() {
    if lspci | grep -qi "nvidia"; then
        echo "nvidia"
    elif lspci | grep -qi "amd\|advanced micro devices"; then
        echo "amd"
    elif lspci | grep -qi "intel"; then
        echo "intel"
    else
        echo "unknown"
    fi
}

GPU=$(detect_gpu)

CPU_VENDOR=$(awk -F': ' '/^vendor_id/ {print $2; exit}' /proc/cpuinfo)
case "$CPU_VENDOR" in
    GenuineIntel) UCODE="intel-ucode" ;;
    AuthenticAMD) UCODE="amd-ucode" ;;
    *)
        echo "Unsupported CPU vendor: '$CPU_VENDOR'" >&2
        exit 1
        ;;
esac

GPU_PKGS=()
case "$GPU" in
    intel) GPU_PKGS=(mesa vulkan-intel intel-media-driver) ;;
    amd) GPU_PKGS=(mesa vulkan-radeon libva-mesa-driver) ;;
    nvidia) GPU_PKGS=(nvidia-dkms nvidia-utils nvidia-settings) ;;
esac

[ "$SYSTEM_TYPE" = "vm" ] && GPU_PKGS=()

# -----------------------------
# Packages
# -----------------------------
BASE_PKGS=(
    base base-devel bash-completion btrfs-progs efibootmgr git grub grub-btrfs
    inotify-tools less linux linux-firmware linux-headers logrotate man-db
    man-pages networkmanager pipewire pipewire-alsa pipewire-jack pipewire-pulse
    python python-pip snap-pac snapper sudo tlp vim wireplumber
    "$UCODE"
)

GNOME_PKGS=(
    dconf-editor extension-manager gdm gnome-console gnome-control-center
    gnome-disk-utility gnome-keyring gnome-session gnome-shell
    gnome-shell-extensions gnome-software gnome-system-monitor
    gnome-text-editor gnome-tweaks gvfs gvfs-smb loupe nautilus packagekit
    sushi xdg-desktop-portal-gnome
)

EXTRA_PKGS=(ansible)
[ "$SYSTEM_TYPE" = "vm" ] && EXTRA_PKGS+=(qemu-guest-agent spice-vdagent)
[ "$GPU" = "intel" ] && [ "$SYSTEM_TYPE" != "vm" ] && EXTRA_PKGS+=(sof-firmware)

# -----------------------------
# Install
# -----------------------------
pacstrap /mnt \
    "${BASE_PKGS[@]}" \
    "${EXTRA_PKGS[@]}" \
    "${GPU_PKGS[@]}" \
    "${GNOME_PKGS[@]}"

genfstab -U /mnt >>/mnt/etc/fstab

# Add noatime + compress=zstd to all btrfs entries
sed -i -E "s|(^\S+\s+\S+\s+btrfs\s+)([^ \t]+)|\1\2,$BTRFS_OPTS|" /mnt/etc/fstab

grep -q '^/swap/swapfile ' /mnt/etc/fstab || echo "/swap/swapfile none swap defaults 0 0" >>/mnt/etc/fstab

UUID=$(blkid -s UUID -o value "$LUKS_DEV")

# -----------------------------
# NVIDIA tweaks (KMS + early load)
# -----------------------------
NVIDIA_MODULES=""
NVIDIA_CMDLINE=""
if [ "$GPU" = "nvidia" ] && [ "$SYSTEM_TYPE" != "vm" ]; then
    NVIDIA_MODULES="nvidia nvidia_modeset nvidia_uvm nvidia_drm"
    NVIDIA_CMDLINE=" nvidia-drm.modeset=1 nvidia-drm.fbdev=1"
fi

# -----------------------------
# CHROOT
# -----------------------------
arch-chroot /mnt /bin/bash <<EOF
set -e

echo "KEYMAP=be-latin1" > /etc/vconsole.conf

ln -sf /usr/share/zoneinfo/Europe/Brussels /etc/localtime

sed -e 's/#en_US/en_US/g' -e 's/#nl_BE/nl_BE/g' -i /etc/locale.gen
locale-gen
{
    echo "LANG=en_US.UTF-8"
    echo "LC_NUMERIC=nl_BE.UTF-8"
    echo "LC_TIME=nl_BE.UTF-8"
    echo "LC_COLLATE=en_US.UTF-8"
    echo "LC_MONETARY=nl_BE.UTF-8"
    echo "LC_NAME=nl_BE.UTF-8"
    echo "LC_ADDRESS=nl_BE.UTF-8"
    echo "LC_TELEPHONE=nl_BE.UTF-8"
    echo "LC_MEASUREMENT=nl_BE.UTF-8"
} > /etc/locale.conf
hwclock --systohc

echo "archlinux" > /etc/hostname

# initramfs
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block keyboard keymap encrypt filesystems fsck)/' /etc/mkinitcpio.conf
if [ -n "$NVIDIA_MODULES" ]; then
    sed -i "s/^MODULES=.*/MODULES=($NVIDIA_MODULES)/" /etc/mkinitcpio.conf
fi
# Disable fallback preset (saves ~50% of /boot initramfs space)
sed -i "s/^PRESETS=.*/PRESETS=('default')/" /etc/mkinitcpio.d/linux.preset
rm -f /boot/initramfs-linux-fallback.img
mkinitcpio -P

# GRUB
sed -i "s|GRUB_CMDLINE_LINUX=\"\"|GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=$UUID:cryptroot$DISCARD_CMDLINE root=/dev/mapper/cryptroot$NVIDIA_CMDLINE\"|" /etc/default/grub

grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB

# users
useradd -m -G wheel "$USERNAME"
passwd -l root
echo "$USERNAME:$USER_PW" | chpasswd
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/10-wheel
chmod 440 /etc/sudoers.d/10-wheel
visudo -cf /etc/sudoers.d/10-wheel

# -----------------------------
# Services
# -----------------------------
systemctl enable NetworkManager.service
systemctl enable gdm.service
systemctl enable grub-btrfsd.service
systemctl enable systemd-timesyncd.service

if [ "$SYSTEM_TYPE" = "vm" ]; then
    systemctl enable qemu-guest-agent.service
fi

if [ "$SYSTEM_TYPE" = "physical" ]; then
    systemctl enable tlp.service
fi

if [ "$IS_SSD" = "1" ]; then
    systemctl enable fstrim.timer
fi


# -----------------------------
# SNAPPER
# -----------------------------
umount /.snapshots
rmdir /.snapshots
snapper --no-dbus -c root create-config /
# Fix the .snapshots directory (replace directory with our subvolume)
btrfs subvolume delete /.snapshots
mkdir /.snapshots
chmod 750 /.snapshots
mount /.snapshots

sed -i \
    -e 's/^TIMELINE_CREATE=.*/TIMELINE_CREATE="no"/' \
    -e 's/^TIMELINE_CLEANUP=.*/TIMELINE_CLEANUP="no"/' \
    -e 's/^ALLOW_GROUPS=.*/ALLOW_GROUPS="wheel"/' \
    -e 's/^SYNC_ACL=.*/SYNC_ACL="yes"/' \
    /etc/snapper/configs/root
snapper --no-dbus create \
    --read-write \
    --cleanup-algorithm number \
    --description "initial install"

grub-mkconfig -o /boot/grub/grub.cfg
EOF

echo "[DONE] Cleanup..."
umount -R /mnt
cryptsetup close cryptroot

echo "=== INSTALL COMPLETE ==="
