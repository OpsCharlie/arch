# Arch Linux Install — UEFI + LUKS

Automated install script handles partitioning, LUKS, GRUB, users, and network.

## Quick Start (from Arch ISO)

```bash
loadkeys be-latin1
pacman -Sy git
git clone https://github.com/OpsCharlie/arch.git
./arch/install.sh
```

Script prompts for:
- Username
- LUKS password
- Root password
- User password

## Manual Steps (after reboot)
### Install GNOME

```bash
pacman -S gnome gdm pipewire pipewire-pulse pipewire-jack wireplumber
systemctl enable gdm
reboot
```

## What the script does

1. **Partitioning** — EFI (512MB) + LUKS partition
2. **LUKS encryption** — encrypts root with password
3. **Base system** — installs base, linux, grub, vim, sudo, networkmanager, git
4. **Locale/Timezone** — en_US.UTF-8, Europe/Brussels, be-latin1 keymap
5. **mkinitcpio** — keyboard, keymap, encrypt hooks for LUKS
6. **GRUB** — configured with cryptdevice for LUKS unlock
7. **User** — creates user in wheel group, enables sudo
8. **NetworkManager** — enabled for network config


## Troubleshooting

**No LUKS prompt at boot?**
```bash
# From ISO
cryptsetup open /dev/vda2 cryptroot
mount /dev/mapper/cryptroot /mnt
mount /dev/vda1 /mnt/boot
mount --bind /proc /mnt/proc
mount --bind /dev /mnt/dev
mount --bind /sys /mnt/sys
mount --bind /run /mnt/run
arch-chroot /mnt
```

