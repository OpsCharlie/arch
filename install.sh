#!/bin/bash
set -e

echo "=== Arch Linux FULL AUTO INSTALL (VM/LAPTOP + GPU + SNAPSHOT + GRUB-BTRFS) ==="

DISK=$(lsblk -d -n -o NAME,TYPE | grep 'disk$' | awk '{print $1}' | head -1)
DEVICE="/dev/${DISK}"

echo "Using disk: $DEVICE"

read -r -s -p "Enter LUKS password: " LUKS_PW; echo
read -r -p "Enter username: " USERNAME
read -r -s -p "Enter user password: " USER_PW; echo

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
    nvme*) EFI="${DEVICE}p1"; LUKS_DEV="${DEVICE}p2" ;;
    *)     EFI="${DEVICE}1";  LUKS_DEV="${DEVICE}2" ;;
esac

parted --script "$DEVICE" \
   mklabel gpt \
   mkpart ESP fat32 1MiB 513MiB \
   set 1 esp on \
   mkpart cryptroot 513MiB 100%

mkfs.fat -F32 -n EFI "$EFI"

# -----------------------------
# LUKS
# -----------------------------
printf "%s" "$LUKS_PW" | cryptsetup luksFormat "$LUKS_DEV" -
printf "%s" "$LUKS_PW" | cryptsetup open "$LUKS_DEV" cryptroot -

# -----------------------------
# BTRFS
# -----------------------------
mkfs.btrfs -L CRYPTROOT /dev/mapper/cryptroot
mount /dev/mapper/cryptroot /mnt

btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@swap
btrfs subvolume create /mnt/@snapshots

umount /mnt

mount -o subvol=@ /dev/mapper/cryptroot /mnt
mkdir -p /mnt/{home,boot,swap,.snapshots}

mount -o subvol=@swap /dev/mapper/cryptroot /mnt/swap
truncate -s 0 /mnt/swap/swapfile
chattr +C /mnt/swap/swapfile
fallocate -l 4G /mnt/swap/swapfile
chmod 600 /mnt/swap/swapfile
mkswap /mnt/swap/swapfile

mount -o subvol=@home /dev/mapper/cryptroot /mnt/home
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

CPU_VENDOR=$(lscpu | awk '/Vendor ID/ {print $3}')
if [ "$CPU_VENDOR" = "GenuineIntel" ]; then
    UCODE="intel-ucode"
else
    UCODE="amd-ucode"
fi

GPU_PKGS=()
case "$GPU" in
    intel) GPU_PKGS=(mesa vulkan-intel intel-media-driver) ;;
    amd) GPU_PKGS=(mesa vulkan-radeon libva-mesa-driver) ;;
    nvidia) GPU_PKGS=(nvidia nvidia-utils nvidia-settings) ;;
esac

[ "$SYSTEM_TYPE" = "vm" ] && GPU_PKGS=()

# -----------------------------
# Packages
# -----------------------------
BASE_PKGS=(
    base base-devel btrfs-progs efibootmgr git grub grub-btrfs
    inotify-tools less linux linux-firmware linux-headers logrotate
    logrotate man-db man-pages nano networkmanager pipewire pipewire-jack
    pipewire-pulse snap-pac snap-pac-grub snapper sudo tlp vim wireplumber
    "$UCODE" 
)

GNOME_PKGS=(
    dconf-editor gdm gnome-browser-connector gnome-console
    gnome-control-center gnome-disk-utility gnome-keyring gnome-session
    gnome-shell gnome-shell-extensions gnome-software gnome-system-monitor
    gnome-text-editor gnome-tweaks gvfs gvfs-smb loupe nautilus packagekit
    sushi xdg-desktop-portal-gnome
)

EXTRA_PKGS=()
[ "$SYSTEM_TYPE" = "vm" ] && EXTRA_PKGS+=(qemu-guest-agent)

# -----------------------------
# Install
# -----------------------------
pacstrap /mnt \
    "${BASE_PKGS[@]}" \
    "${EXTRA_PKGS[@]}" \
    "${GPU_PKGS[@]}" \
    "${GNOME_PKGS[@]}"

genfstab -U /mnt >> /mnt/etc/fstab

grep -q '^/swap/swapfile ' /mnt/etc/fstab || echo "/swap/swapfile none swap defaults 0 0" >> /mnt/etc/fstab

UUID=$(blkid -s UUID -o value "$LUKS_DEV")

# -----------------------------
# CHROOT
# -----------------------------
arch-chroot /mnt /bin/bash <<EOF
set -ex

echo "KEYMAP=be-latin1" > /etc/vconsole.conf
echo "LANG=en_US.UTF-8" > /etc/locale.conf

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
mkinitcpio -P

# GRUB
sed -i "s|GRUB_CMDLINE_LINUX=\"\"|GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=$UUID:cryptroot root=/dev/mapper/cryptroot\"|" /etc/default/grub

grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

# users
useradd -m -G wheel "$USERNAME"
passwd -l root
echo "$USERNAME:$USER_PW" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# -----------------------------
# Services
# -----------------------------
systemctl enable NetworkManager.service
systemctl enable gdm.service
systemctl enable grub-btrfsd.service --root=/

if [ "$SYSTEM_TYPE" = "vm" ]; then
    systemctl enable qemu-guest-agent.service
fi

if [ "$SYSTEM_TYPE" = "physical" ]; then
    systemctl enable tlp.service
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
    /etc/snapper/configs/root
snapper --no-dbus create \
    --read-write \
    --cleanup-algorithm number \
    --description "initial install"

# -----------------------------
# Flatpak
# -----------------------------
#flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

EOF

echo "[DONE] Cleanup..."
umount -R /mnt
cryptsetup close cryptroot

echo "=== INSTALL COMPLETE ==="
