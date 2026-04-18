#!/bin/bash
set -e

echo "=== Arch Linux FULL AUTO INSTALL (VM/LAPTOP + GPU + SNAPSHOT) ==="

DISK=$(lsblk -d -n -o NAME,TYPE | grep 'disk$' | awk '{print $1}' | head -1)
DEVICE="/dev/${DISK}"

echo "Using disk: $DEVICE"

read -r -p "Enter username: " USERNAME
read -r -s -p "Enter LUKS password: " LUKS_PW; echo
read -r -s -p "Enter root password: " ROOT_PW; echo
read -r -s -p "Enter user password: " USER_PW; echo

# -----------------------------
# Detect VM vs physical
# -----------------------------
SYSTEM_TYPE="physical"
if systemd-detect-virt -q 2>/dev/null; then
    SYSTEM_TYPE="vm"
fi
echo "[*] System type: $SYSTEM_TYPE"

# -----------------------------
# Partition mapping
# -----------------------------
case "$DISK" in
    nvme*) EFI="${DEVICE}p1"; LUKS_DEV="${DEVICE}p2" ;;
    *)     EFI="${DEVICE}1";  LUKS_DEV="${DEVICE}2" ;;
esac

echo "[1] Partitioning..."
parted -s "$DEVICE" mklabel gpt
parted -s "$DEVICE" mkpart ESP fat32 1MiB 513MiB
parted -s "$DEVICE" set 1 esp on
parted -s "$DEVICE" mkpart cryptroot 513MiB 100%

mkfs.fat -F32 "$EFI"

# -----------------------------
# LUKS
# -----------------------------
printf "%s" "$LUKS_PW" | cryptsetup luksFormat "$LUKS_DEV" -
printf "%s" "$LUKS_PW" | cryptsetup open "$LUKS_DEV" cryptroot -

# -----------------------------
# BTRFS layout
# -----------------------------
mkfs.btrfs /dev/mapper/cryptroot

mount /dev/mapper/cryptroot /mnt

btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots

umount /mnt

mount -o subvol=@ /dev/mapper/cryptroot /mnt
mkdir -p /mnt/{home,.snapshots,boot}

mount -o subvol=@home /dev/mapper/cryptroot /mnt/home
mount "$EFI" /mnt/boot

# -----------------------------
# GPU detection
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
echo "[*] GPU detected: $GPU"

CPU_VENDOR=$(lscpu | grep "Vendor ID" | awk '{print $3}')

if [ "$CPU_VENDOR" = "GenuineIntel" ]; then
    UCODE="intel-ucode"
else
    UCODE="amd-ucode"
fi

case "$GPU" in
    intel)
        GPU_PKGS="mesa vulkan-intel intel-media-driver"
        ;;
    amd)
        GPU_PKGS="mesa vulkan-radeon libva-mesa-driver"
        ;;
    nvidia)
        GPU_PKGS="nvidia nvidia-utils nvidia-settings"
        ;;
esac

if [ "$SYSTEM_TYPE" = "vm" ]; then
    GPU_PKGS=""
fi

# -----------------------------
# Packages
# -----------------------------
BASE_PKGS=(
    base linux linux-headers linux-firmware
    grub efibootmgr base-devel git sudo vim nano
    networkmanager
    pipewire pipewire-pulse pipewire-jack wireplumber
    btrfs-progs snapper grub-btrfs $UCODE tlp
)

GNOME_BASE=(
    gnome-shell gnome-session gnome-control-center gdm
    nautilus gvfs xdg-desktop-portal-gnome
)

GNOME_PERF=(
    gnome-console gnome-system-monitor gnome-text-editor
    gnome-disk-utility gnome-keyring loupe sushi
)

GNOME_POWER=(
    git vim gnome-tweaks dconf-editor
    gnome-shell-extensions
    gnome-browser-connector
)

EXTRA_PKGS=()

if [ "$SYSTEM_TYPE" = "vm" ]; then
    EXTRA_PKGS+=(qemu-guest-agent)
fi

# -----------------------------
# Install system
# -----------------------------
pacstrap /mnt \
    "${BASE_PKGS[@]}" \
    "${EXTRA_PKGS[@]}" \
    $GPU_PKGS \
    "${GNOME_BASE[@]}" \
    "${GNOME_PERF[@]}" \
    "${GNOME_POWER[@]}"

genfstab -U /mnt >> /mnt/etc/fstab

# -----------------------------
# CHROOT
# -----------------------------

UUID=$(blkid -s UUID -o value "$LUKS_DEV")

arch-chroot /mnt /bin/bash <<EOF
set -e

echo "KEYMAP=be-latin1" > /etc/vconsole.conf
echo "LANG=en_US.UTF-8" > /etc/locale.conf

ln -sf /usr/share/zoneinfo/Europe/Brussels /etc/localtime

sed -i 's/#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen
hwclock --systohc

echo "archlinux" > /etc/hostname

# mkinitcpio
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block keyboard keymap encrypt filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# GRUB
sed -i "s|GRUB_CMDLINE_LINUX=\"\"|GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=$UUID:cryptroot root=/dev/mapper/cryptroot\"|" /etc/default/grub

grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

# users
useradd -m -G wheel "$USERNAME"
echo "root:$ROOT_PW" | chpasswd
echo "$USERNAME:$USER_PW" | chpasswd

sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# -----------------------------
# SERVICES (SYMLINK METHOD)
# -----------------------------

# NetworkManager
ln -sf /usr/lib/systemd/system/NetworkManager.service \
/etc/systemd/system/multi-user.target.wants/NetworkManager.service

# GDM (display manager)
ln -sf /usr/lib/systemd/system/gdm.service \
/etc/systemd/system/display-manager.service

# VM
if [ "$SYSTEM_TYPE" = "vm" ]; then
    ln -sf /usr/lib/systemd/system/qemu-guest-agent.service \
    /etc/systemd/system/multi-user.target.wants/qemu-guest-agent.service
fi

# Laptop power
if [ "$SYSTEM_TYPE" = "physical" ]; then
    ln -sf /usr/lib/systemd/system/tlp.service \
    /etc/systemd/system/multi-user.target.wants/tlp.service
fi

# -----------------------------
# SNAPPER
# -----------------------------
snapper -c root create-config /

sed -i 's/TIMELINE_CREATE=.*/TIMELINE_CREATE="no"/' /etc/snapper/configs/root

ln -sf /usr/lib/systemd/system/grub-btrfsd.service \
/etc/systemd/system/multi-user.target.wants/grub-btrfsd.service

EOF

echo "[DONE] Cleanup..."
umount -R /mnt
cryptsetup close cryptroot

echo "=== INSTALL COMPLETE ==="
