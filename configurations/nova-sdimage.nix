# Flashable SD image for the Luckfox Nova (RK3308B / AArch64).
#
# Build:   nix build .#nova-sdImage-flashable
# Flash:   dd if=result/sd-flashable.img of=/dev/sdX bs=4M status=progress
#
# Hardware kernel, DTB, and U-Boot are imported automatically by mkSystem
# (lib/mkSystem.nix) when called with model = "nova" — no explicit
# hardware/ import needed here.

{ config, lib, ... }:

{
  imports = [ ../configuration.nix ];

  # Override the model for Nova builds.
  # configuration.nix sets luckfox.model = "pico-mini-b" by default;
  # this forces Nova board settings (hostname, USB mode, etc.).
  luckfox.model = lib.mkForce "nova";

  system.imageSize = lib.mkDefault (
    if config.system.abRootfs.enable then 2048 else 512
  );

  # RK3308 UART2 at 1500000 baud is the standard Nova console.
  # Adjust if your Nova variant uses a different UART or baud rate.
  boot.cmdline = lib.mkDefault (
    if config.system.abRootfs.enable
    then "console=ttyS2,1500000 init=/sbin/init panic=1"
    else "console=ttyS2,1500000 root=/dev/mmcblk0p1 rw rootfstype=ext4 init=/sbin/init"
  );
}
