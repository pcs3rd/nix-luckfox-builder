# QEMU test configuration for the Luckfox Pico Mini B rootfs.
#
# Inherits everything from configuration.nix and overrides only what differs
# for QEMU's generic "virt" ARM machine (Cortex-A7):
#   - Serial console on ttyAMA0  (PL011 UART, not ttyS0)
#   - Kernel passed directly to QEMU; rootfs served as a read-only virtio-blk disk
#   - Network via virtio-net (udhcpc on eth0)
#
# U-Boot and the Rockchip layout are forced off — QEMU loads the kernel
# directly, bypassing the bootloader entirely.

{ lib, ... }:

{
  imports = [ ../configuration.nix ];

  # QEMU virt machine exposes the serial port as ttyAMA0 (PL011), not ttyS0
  services.getty.tty = "ttyAMA0";

  # Distinguish the QEMU hostname from real hardware
  networking.hostname = lib.mkForce "luckfox-qemu";

  # Boot from the virtio-blk disk QEMU attaches as /dev/vda (read-only).
  boot.cmdline = lib.mkForce "console=ttyAMA0 root=/dev/vda ro init=/sbin/init panic=1";

  # configuration.nix enables these; force them off for QEMU
  boot.uboot.enable = lib.mkForce false;
  rockchip.enable   = lib.mkForce false;

  # meshing-around (and its bundled Python) is kept enabled here.
  # The stdlib trimming in pkgs/meshing-around.nix removes ~45 MB of unused
  # modules (tkinter, test/, idlelib, lib2to3, …), and QEMU runs at 512 MB,
  # so the initramfs fits comfortably.  Re-disable with lib.mkForce false if
  # you ever hit a kernel panic due to initramfs size.

  # zram requires kernel modules (/lib/modules/<ver>/…/zram.ko).
  # The QEMU initramfs has no kernel modules tree, so modprobe would fail.
  # 512 MB QEMU RAM is ample anyway — disable zram for the initramfs build.
  system.zram.enable = lib.mkForce false;

}
