# Flashable SD image with A/B rootfs (squashfs + overlayfs) for Luckfox Pico Mini B.
#
# Disk layout:
#   Sector 0            : MBR + partition table
#   Sector 1 (byte 512) : slot indicator byte 'a'
#   Sector 64           : Rockchip SPL / idbloader
#   Sector 16384        : U-Boot proper
#   p1 (ext4 "boot")    : kernel + initramfs + boot.scr + extlinux.conf
#   p2 (squashfs)       : slot A rootfs  (read-only)
#   p3 (squashfs)       : slot B rootfs  (read-only)
#   p4 (ext4 "persist") : overlayfs upper/work dirs (survives upgrades)
#
# The initramfs (in p1) reads the slot indicator byte, mounts the active
# squashfs slot via overlayfs on the persist partition, and switch_root's in.
#
# Build:
#   nix build .#sdImage-ab           # full SD card image
#   nix build .#rootfsPartition      # standalone squashfs for SSH upgrades
#
# Flash:
#   dd if=result/sd-flashable.img of=/dev/sdX bs=4M status=progress
#
# Upgrade running device (after first flash):
#   nix build .#rootfsPartition
#   ssh root@luckfox upgrade < result/rootfs.squashfs
#
# Inspect active slot:
#   ssh root@luckfox slot

{ lib, ... }:

{
  imports = [ ../configuration.nix ];

  system.abRootfs.enable = true;

  # Each slot gets roughly half of (total − boot − persist).
  # 2048 MiB total: p1=64 MiB, p4=256 MiB, p2=p3≈863 MiB each.
  system.imageSize = lib.mkDefault 2048;

  # boot.scr loads kernel + initramfs; initramfs sets root= via overlayfs.
  # console=ttyS0 for the Luckfox hardware UART.
  boot.cmdline = lib.mkDefault "console=ttyS0 init=/sbin/init panic=1";
}
