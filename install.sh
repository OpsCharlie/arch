#!/bin/bash
set -e

echo "=== Arch Linux Automated Install ==="

DISK=$(lsblk -d -n -o NAME,TYPE | grep 'disk$' | awk '{print $1}' | head -1)
DEVICE="/dev/${DISK}"

echo "Using disk: $DEVICE"

read -r -p "Enter username: " USERNAME
read -r -s -p "Enter LUKS password: " LUKS_PW; echo
read -r -s -p "Enter root password: " ROOT_PW; echo
read -r -s -p "Enter user password: " USER_PW; echo

# Partition mapping
case "$DISK" in
    nvme*) EFI="${DEVICE}p1"; LUKS_DEV="${DEVICE}p2" ;;
    *)     EFI="${DEVICE}1";  LUKS_DEV="${DEVICE}2" ;;
esac

echo "[1] Partitioning..."
if lsblk "$DEVICE" | grep -q part; then
    echo "Warning: partitions already exist on $DEVICE"
    read -p "Wipe them? (yes/no): " CONFIRM
    [ "$CONFIRM" != "yes" ] && exit 1
fi

parted -s "$DEVICE" mklabel gpt
parted -s "$DEVICE" mkpart ESP fat32 1MiB 513MiB
parted -s "$DEVICE" set 1 esp on
parted -s "$DEVICE" mkpart cryptroot 513MiB 100%

echo "[2] Format EFI..."
mkfs.fat -F32 "$EFI"

echo "[3] LUKS encryption..."
printf "%s" "$LUKS_PW" | cryptsetup luksFormat "$LUKS_DEV" -
printf "%s" "$LUKS_PW" | cryptsetup open "$LUKS_DEV" cryptroot -

echo "[4] Filesystems..."
mkfs.ext4 /dev/mapper/cryptroot

mount /dev/mapper/cryptroot /mnt
mkdir -p /mnt/boot
mount "$EFI" /mnt/boot

echo "[5] Base system..."
pacstrap /mnt base linux linux-headers linux-firmware grub efibootmgr base-devel vim sudo networkmanager git

echo "[6] fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

echo "[7] System configuration..."

arch-chroot /mnt /bin/bash <<EOF
set -e

# Locale & time
echo "KEYMAP=be-latin1" > /etc/vconsole.conf
echo "LANG=en_US.UTF-8" > /etc/locale.conf

ln -sf /usr/share/zoneinfo/Europe/Brussels /etc/localtime
sed -i 's/#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen
hwclock --systohc

# Hostname
echo "archvm" > /etc/hostname

# mkinitcpio (LUKS FIXED)
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block keyboard keymap encrypt filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# GRUB LUKS config
UUID=\$(blkid -s UUID -o value "$LUKS_DEV")

sed -i "s|GRUB_CMDLINE_LINUX=\"\"|GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=\$UUID:cryptroot root=/dev/mapper/cryptroot\"|" /etc/default/grub

grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

# Users
useradd -m -G wheel "$USERNAME"
echo "root:$ROOT_PW" | chpasswd
echo "$USERNAME:$USER_PW" | chpasswd

# sudo
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Network
systemctl enable NetworkManager

EOF

echo "[8] Cleanup..."
umount -R /mnt
cryptsetup close cryptroot

echo "=== DONE === Remove ISO and reboot ==="
