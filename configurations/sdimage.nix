# Flashable SD image for Luckfox Pico Mini B.
#
# The partition layout is selected automatically based on system.abRootfs.enable
# (set in configuration.nix).  No layout flag is needed here.
#
# ── A/B layout  (system.abRootfs.enable = true) ──────────────────────────────
#
#   Sector 0            : MBR + partition table
#   Sector 1 (byte 512) : slot indicator byte 'a'
#   Sector 64           : Rockchip SPL / idbloader
#   Sector 16384        : U-Boot proper
#   p1 (ext4 "boot")    : kernel + initramfs + boot.scr
#   p2 (squashfs)       : slot A rootfs  (read-only)
#   p3 (squashfs)       : slot B rootfs  (read-only)
#   p4 (ext4 "persist") : overlayfs upper/work dirs (survives upgrades)
#
#   Image size default: 2048 MiB
#   p1 = 64 MiB  |  p2 = p3 ≈ 863 MiB  |  p4 = 256 MiB
#
# ── Single-partition layout  (system.abRootfs.enable = false) ─────────────────
#
#   Sector 0            : MBR + partition table
#   Sector 64           : Rockchip SPL / idbloader
#   Sector 16384        : U-Boot proper
#   p1 (ext4 "rootfs")  : kernel + rootfs + extlinux.conf (all in one partition)
#
#   Image size default: 512 MiB
#
# ── Build ─────────────────────────────────────────────────────────────────────
#
#   nix build .#sdImage-flashable        # full SD card image
#   nix build .#rootfsPartition          # standalone squashfs (A/B upgrades only)
#
# ── Flash ─────────────────────────────────────────────────────────────────────
#
#   dd if=result/sd-flashable.img of=/dev/sdX bs=4M status=progress
#
# ── Upgrade (A/B only) ────────────────────────────────────────────────────────
#
#   nix build .#rootfsPartition
#   ssh root@luckfox upgrade < result/rootfs.squashfs

{ config, lib, ... }:

{
  imports = [
    ../configuration.nix
    # Builds the kernel, DTBs, and modules from the LuckfoxTECH SDK source.
    # Kept in a separate file so QEMU configs (which also import configuration.nix)
    # do not force this derivation to be evaluated.
    ../hardware/pico-mini-b-kernel.nix
  ];

  # Image size scales with the layout chosen by system.abRootfs.enable:
  #   A/B  (4 partitions): 2048 MiB — generous room for two squashfs slots
  #   Single (1 partition):  512 MiB — rootfs + kernel in one ext4 partition
  system.imageSize = lib.mkDefault (
    if config.system.abRootfs.enable then 2048 else 512
  );

  # Boot cmdline adapts to the layout:
  #   A/B  — no root= needed; the slot-select initramfs mounts the active
  #           squashfs slot and overlays the persist partition before switch_root.
  #   Single — direct extlinux.conf boot, kernel mounts p1 as the ext4 rootfs.
  boot.cmdline = lib.mkDefault (
    if config.system.abRootfs.enable
    then "console=ttyS0 init=/sbin/init panic=1"
    else "console=ttyS0 root=/dev/mmcblk0p1 rw rootfstype=ext4 init=/sbin/init"
  );
}
