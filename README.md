# Arch Linux Install — UEFI + LUKS

## 1. Partitioning

```bash
lsblk
cgdisk /dev/vda
```

- `/dev/vda1` → EFI (512MB, hex code ef00)
- `/dev/vda2` → LUKS (remaining, hex code 8300)

```bash
mkfs.fat -F32 /dev/vda1
```

## 2. LUKS encryption

```bash
cryptsetup luksFormat /dev/vda2
cryptsetup open /dev/vda2 cryptroot
```

## 3. Filesystems and mount

```bash
mkfs.ext4 /dev/mapper/cryptroot
mount /dev/mapper/cryptroot /mnt
mkdir -p /mnt/boot
mount /dev/vda1 /mnt/boot
```

## 4. Base system

```bash
pacstrap /mnt base linux linux-firmware grub efibootmgr base-devel vim
genfstab -U /mnt >> /mnt/etc/fstab
arch-chroot /mnt
```

## 5. Locale and timezone

```bash
echo "KEYMAP=be-latin1" > /etc/vconsole.conf
echo "LANG=en_US.UTF-8" > /etc/locale.conf
ln -sf /usr/share/zoneinfo/Europe/Brussels /etc/localtime
vim /etc/locale.gen  # uncomment en_US.UTF-8
locale-gen
hwclock --systohc
```

## 6. Initramfs

```bash
vim /etc/mkinitcpio.conf
# HOOKS=(base udev autodetect modconf block encrypt fsck)
mkinitcpio -P
```

## 7. GRUB

```bash
vim /etc/default/grub
# GRUB_CMDLINE_LINUX_DEFAULT="cryptdevice=UUID=$(blkid -s UUID -o value /dev/vda2):cryptroot"
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg
```

## 8. Root password and exit

```bash
passwd
exit
umount -R /mnt
reboot
```

## 9. Network (running system)

```bash
ip link set enp1s0 up
vim /etc/systemd/network/enp1s0.network
# Add: [Match] Name=enp1s0, [Network] DHCP=ipv4
systemctl enable --now systemd-networkd
systemctl enable --now systemd-resolved
```

## 10. User and sudo

```bash
useradd -m -G wheel your_username
passwd your_username
pacman -S sudo
EDITOR=vim visudo
# Uncomment: %wheel ALL=(ALL) ALL
```

## 11. GUI (GNOME)

```bash
pacman -Syyu
pacman -S gnome gnome-shell gdm networkmanager
systemctl enable gdm NetworkManager
systemctl disable systemd-networkd
reboot
```

Start GNOME from login or with `startx`.

