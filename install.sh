#!/bin/bash
set -e

echo "=== Arch Linux Automated Install ==="

DISK=$(lsblk -d -n -o NAME,TYPE | grep 'disk$' | awk '{print $1}' | head -1)
echo "Using disk: /dev/${DISK}"
read -r -p "Enter username: " USERNAME
read -r -s -p "Enter LUKS password: " LUKS_PW; echo
read -r -s -p "Enter root password: " ROOT_PW; echo
read -r -s -p "Enter user password: " USER_PW; echo

export USERNAME ROOT_PW USER_PW LUKS DISK
DEVICE="/dev/${DISK}"
case "$DISK" in
    nvme*) EFI="${DEVICE}p1"; LUKS="${DEVICE}p2" ;;
    vd*)   EFI="${DEVICE}1";  LUKS="${DEVICE}2" ;;
    sd*)  EFI="${DEVICE}1";  LUKS="${DEVICE}2" ;;
esac

echo "[1] Partitioning..."
if lsblk "$DEVICE" | grep -q part; then
    echo "Warning: partitions already exist on $DEVICE"
    read -p "Wipe them? (yes/no): " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        echo "Aborted."
        exit 1
    fi
fi
parted -s "$DEVICE" mklabel gpt
parted -s "$DEVICE" mkpart ESP 1MiB 513MiB
parted -s "$DEVICE" mkpart cryptroot 513MiB 100%
parted -s "$DEVICE" set 1 boot on

echo "[2] Format EFI..."
mkfs.fat -F32 "$EFI"

echo "[3] LUKS encryption..."
echo -n "$LUKS_PW" | cryptsetup luksFormat "$LUKS"
echo -n "$LUKS_PW" | cryptsetup open "$LUKS" cryptroot

echo "[4] Filesystems..."
mkfs.ext4 /dev/mapper/cryptroot
mount /dev/mapper/cryptroot /mnt
mkdir -p /mnt/boot
mount "$EFI" /mnt/boot

echo "[5] Base system..."
pacstrap /mnt base linux linux-firmware grub efibootmgr base-devel vim sudo networkmanager

echo "[6] Configure system..."
genfstab -U /mnt > /mnt/etc/fstab

arch-chroot /mnt /bin/bash <<'EOF'
set -ex

echo "KEYMAP=be-latin1" > /etc/vconsole.conf
echo "LANG=en_US.UTF-8" > /etc/locale.conf
ln -sf /usr/share/zoneinfo/Europe/Brussels /etc/localtime
sed -i 's/#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen
hwclock --systohc

sed -i 's/HOOKS=(.*)/HOOKS=(base udev autodetect modconf block encrypt fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

UUID=$(blkid -s UUID -o value "$LUKS")
sed -i "s|GRUB_CMDLINE_LINUX_DEFAULT=\"\"|GRUB_CMDLINE_LINUX_DEFAULT=\"cryptdevice=UUID=${UUID}:cryptroot\"|" /etc/default/grub
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

useradd -m -G wheel "$USERNAME"
echo "root:$ROOT_PW" | chpasswd
echo "$USERNAME:$USER_PW" | chpasswd
sed -i 's/# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/' /etc/sudoers

systemctl enable NetworkManager
EOF

echo "[7] Unmount..."
umount -R /mnt
cryptsetup close cryptroot

echo "=== Done. Remove ISO and reboot ==="
