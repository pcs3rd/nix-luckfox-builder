# Self-expanding flashable SD image configuration.
#
# Inherits all settings from configuration.nix and adds:
#   - resize2fs + sfdisk in the rootfs
#   - /sbin/expand-rootfs first-boot script
#
# On first power-on with a freshly-flashed card:
#   Boot 1 — expand-rootfs detects free space, rewrites the partition table
#             to fill the card, then reboots.
#   Boot 2 — expand-rootfs runs resize2fs to grow the ext4 filesystem, then
#             marks itself done (never runs again).
#
# Build with:
#   nix build .#sdImage-flashable
#
# Flash with:
#   dd if=result of=/dev/sdX bs=4M status=progress

{ lib, ... }:

{
  imports = [ ../configuration.nix ];

  system.sdExpand.enable = true;

  # Give the image a bit more breathing room than the default 256 MiB so there
  # is space for the rootfs, kernel, and extlinux config with room to spare.
  system.imageSize = lib.mkDefault 512;
}
