# Flashable SD image with A/B rootfs for zero-downtime SSH upgrades.
#
# Inherits settings from configuration.nix and adds:
#   - system.abRootfs: slot-select initramfs, /bin/upgrade, /bin/slot
#   - sdimage.nix creates two equal-size rootfs partitions
#   - Slot indicator byte 'a' written at sector 1 on initial flash
#
# Disk layout (Luckfox Pico Mini B):
#   Sector 0          : MBR + partition table
#   Sector 1 (byte 512): slot indicator byte 'a'
#   Sector 64         : Rockchip SPL / idbloader
#   Sector 16384      : U-Boot proper
#   Sector 4096       : ext4 rootfs A (partition 1) — kernel + boot.scr + initramfs + rootfs
#   Following p1      : ext4 rootfs B (partition 2) — rootfs only
#
# Build with:
#   nix build .#sdImage-ab          # full SD card image (flash to card)
#   nix build .#rootfsPartition     # standalone ext4 for SSH upgrades
#
# Flash with:
#   dd if=result/sd-flashable.img of=/dev/sdX bs=4M status=progress
#
# Upgrade running device (after first flash):
#   nix build .#rootfsPartition
#   ssh root@luckfox upgrade < result/rootfs.ext4
#
# Inspect active slot:
#   ssh root@luckfox slot

{ lib, ... }:

{
  imports = [ ../configuration.nix ];

  system.abRootfs.enable = true;

  # Each slot gets half the total image size.  512 MiB total → 256 MiB / slot.
  system.imageSize = lib.mkDefault 512;

  # boot.scr (U-Boot distro boot) sets root=LABEL=... dynamically.
  # extlinux.conf (fallback) uses the slot-select initramfs which handles
  # root mounting itself — no root= needed here for either path.
  boot.cmdline = lib.mkDefault "console=ttyS0 init=/sbin/init panic=1";
}
