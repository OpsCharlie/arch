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
- LUKS password
- Root password
- User password


## What the script does

1. **Partitioning** — EFI (512MB) + LUKS partition, btrfs root partition
2. **LUKS encryption** — encrypts root with password
3. **Base system** — installs base, linux, grub, vim, sudo, networkmanager, git
4. **Snapper** — Configures Snapper for snapshots pre/post package installs 
5. **Locale/Timezone** — en_US.UTF-8, Europe/Brussels, be-latin1 keymap
6. **mkinitcpio** — keyboard, keymap, encrypt hooks for LUKS
7. **GRUB** — configured with cryptdevice for LUKS unlock
8. **User** — creates user in wheel group, enables sudo
9. **NetworkManager** — enabled for network config


## Troubleshooting

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

