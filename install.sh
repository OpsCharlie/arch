#!/bin/bash
set -e

echo "=== Arch Linux FULL AUTO INSTALL (VM/LAPTOP + GPU + SNAPSHOT + GRUB-BTRFS) ==="

DISK=$(lsblk -d -n -o NAME,TYPE | grep 'disk$' | awk '{print $1}' | head -1)
DEVICE="/dev/${DISK}"

echo "Using disk: $DEVICE"

read -r -p "Enter username: " USERNAME
read -r -s -p "Enter LUKS password: " LUKS_PW; echo
read -r -s -p "Enter root password: " ROOT_PW; echo
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
# BTRFS
# -----------------------------
mkfs.btrfs /dev/mapper/cryptroot
mount /dev/mapper/cryptroot /mnt

btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots

umount /mnt

mount -o subvol=@ /dev/mapper/cryptroot /mnt
mkdir -p /mnt/{home,boot}

mount -o subvol=@home /dev/mapper/cryptroot /mnt/home
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
    base linux linux-headers linux-firmware
    grub efibootmgr base-devel git sudo vim nano
    networkmanager
    pipewire pipewire-pulse pipewire-jack wireplumber
    btrfs-progs snapper grub-btrfs inotify-tools
    $UCODE tlp
)

GNOME_PKGS=(
    gnome-shell gnome-session gnome-control-center gdm
    nautilus gvfs xdg-desktop-portal-gnome
    gnome-console gnome-system-monitor gnome-text-editor
    gnome-disk-utility gnome-keyring loupe sushi
    gnome-software packagekit flatpak
    gnome-tweaks dconf-editor
    gnome-shell-extensions gnome-browser-connector
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

UUID=$(blkid -s UUID -o value "$LUKS_DEV")

# -----------------------------
# CHROOT
# -----------------------------
arch-chroot /mnt /bin/bash <<EOF
set -e

echo "KEYMAP=be-latin1" > /etc/vconsole.conf
echo "LANG=en_US.UTF-8" > /etc/locale.conf

ln -sf /usr/share/zoneinfo/Europe/Brussels /etc/localtime

sed -i 's/#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen
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
echo "root:$ROOT_PW" | chpasswd
echo "$USERNAME:$USER_PW" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# services (symlinks)
ln -sf /usr/lib/systemd/system/NetworkManager.service \
/etc/systemd/system/multi-user.target.wants/NetworkManager.service

ln -sf /usr/lib/systemd/system/gdm.service \
/etc/systemd/system/display-manager.service

if [ "$SYSTEM_TYPE" = "vm" ]; then
    ln -sf /usr/lib/systemd/system/qemu-guest-agent.service \
    /etc/systemd/system/multi-user.target.wants/qemu-guest-agent.service
fi

if [ "$SYSTEM_TYPE" = "physical" ]; then
    ln -sf /usr/lib/systemd/system/tlp.service \
    /etc/systemd/system/multi-user.target.wants/tlp.service
fi

ln -sf /usr/lib/systemd/system/grub-btrfsd.service \
/etc/systemd/system/multi-user.target.wants/grub-btrfsd.service

# -----------------------------
# SNAPPER (first boot safe)
# -----------------------------
cat <<'EOF2' > /etc/systemd/system/firstboot-snapper.service
[Unit]
Description=Snapper init
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/bin/bash -c '
if [ ! -f /etc/snapper/configs/root ]; then
    snapper -c root create-config /
    sed -i "s/TIMELINE_CREATE=.*/TIMELINE_CREATE=no/" /etc/snapper/configs/root
    snapper create -d "initial snapshot"
fi
systemctl disable firstboot-snapper.service
rm -f /etc/systemd/system/firstboot-snapper.service
'

RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF2

ln -sf /etc/systemd/system/firstboot-snapper.service \
/etc/systemd/system/multi-user.target.wants/firstboot-snapper.service

# -----------------------------
# Flatpak
# -----------------------------
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

EOF

echo "[DONE] Cleanup..."
umount -R /mnt
cryptsetup close cryptroot

echo "=== INSTALL COMPLETE ==="
