# Flashable SD image with persistent overlayfs.
#
# Inherits all settings from configuration.nix and adds:
#   - init-overlay: kernel init= entry point that sets up overlayfs
#   - sfdisk, mkfs.ext4, blkid, blockdev in the rootfs
#
# Boot layout:
#   Partition 1 (/dev/mmcblk0p1) — ext4 rootfs, read-only lower layer
#   Partition 2 (/dev/mmcblk0p2) — ext4 overlay (created on first boot from
#                                   the unpartitioned space after partition 1)
#
# On first power-on with a freshly-flashed card:
#   Boot 1 — init-overlay creates and formats the overlay partition, then
#             completes the normal boot.  The rootfs partition is never
#             modified again.
#
# On all subsequent boots:
#   init-overlay mounts the overlay and overlays it on the read-only rootfs.
#   All writes (config changes, package installs, logs) go to the overlay.
#   Wipe the overlay partition to get a clean slate without reflashing.
#
# Build with:
#   nix build .#sdImage-flashable
#
# Flash with:
#   dd if=result of=/dev/sdX bs=4M status=progress

{ lib, ... }:

{
  imports = [ ../configuration.nix ];

  system.sdOverlay.enable = true;

  # Rootfs partition size.  Free space beyond this on the physical card becomes
  # the overlay partition (created on first boot).
  system.imageSize = lib.mkDefault 512;

  # The kernel must start init-overlay as PID 1.  It sets up the overlay then
  # execs /sbin/init.  Mount the rootfs read-only so all writes go to overlay.
  boot.cmdline = lib.mkForce
    "console=ttyS0 root=/dev/mmcblk0p1 ro rootfstype=ext4 init=/sbin/init-overlay";
}
