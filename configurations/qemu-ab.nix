# QEMU A/B rootfs test configuration.
#
# Boots via generic U-Boot (ubootQemuArm, provided via -bios) using the same
# SD image that sdimage.nix generates for real hardware.  Only the bootloader
# differs: QEMU loads U-Boot via -bios instead of from raw disk sectors.
#
# ── Disk layout (virtio-blk /dev/vda) ────────────────────────────────────────
#
#   Sector 0    : MBR + partition table
#   Byte 512    : slot indicator byte ('a' or 'b')   ← managed by ab-rootfs.nix
#   Sector 4096 : p1 ext4 "boot"    — kernel + initramfs + boot.scr
#   After p1    : p2 squashfs        — slot A rootfs  (read-only)
#   After p2    : p3 squashfs        — slot B rootfs  (read-only)
#   After p3    : p4 ext4 "persist"  — overlayfs upper/work dirs
#
# ── Boot path ─────────────────────────────────────────────────────────────────
#
#   1. QEMU starts U-Boot via -bios ${ubootQemuArm}/u-boot.bin.
#   2. U-Boot distro_bootcmd finds boot.scr in virtio partition 1.
#   3. boot.scr loads kernel + initramfs from p1.
#   4. The slot-select initramfs reads the raw slot indicator byte.
#   5. It mounts the active squashfs (p2 or p3) and layers the persist (p4)
#      via overlayfs, then exec switch_root into the overlay.
#
# ── Usage ─────────────────────────────────────────────────────────────────────
#
#   nix run .#qemu-ab                       # launch the VM
#   ssh root@localhost -p <port> slot       # inspect active slot (A or B)
#
#   nix build .#qemu-ab-rootfs
#   ssh root@localhost -p <port> upgrade < result/rootfs.squashfs
#   # device reboots into the new slot automatically
#
# The QEMU disk is backed by a QCOW2 overlay so slot changes and rootfs
# upgrades persist across QEMU runs.  Pass --reset to start fresh from slot A.

{ lib, ... }:

{
  imports = [ ../configuration.nix ];

  # QEMU virt machine uses PL011 UART → ttyAMA0.
  services.getty.tty = "ttyAMA0";

  networking.hostname = lib.mkForce "luckfox-qemu-ab";

  # boot.scr sets bootargs without root= — the initramfs handles root mounting.
  #
  # quiet: suppresses per-driver kernel log spam.  The PL011 UART in QEMU TCG
  # is slow per-character — printing thousands of driver log lines measurably
  # extends boot time.  Remove quiet to see driver output for debugging.
  boot.cmdline = lib.mkForce "console=ttyAMA0 init=/sbin/init panic=1 quiet";

  # U-Boot is supplied via -bios, not embedded in the disk image.
  boot.uboot.enable = lib.mkForce false;
  rockchip.enable   = lib.mkForce false;

  # QEMU has ample RAM; zram is unnecessary.
  system.zram.enable = lib.mkForce false;

  # QEMU virt has no USB controller — disable gadget and mode-switch scripts.
  system.usbGadget.enable = lib.mkForce false;
  system.usb.mode         = lib.mkForce "otg";   # disables the role-switch script

  # A/B with squashfs + overlayfs.
  # Slots are found by partition number (p2/p3); persist by ext4 label (p4).
  system.abRootfs.enable = true;

  # 2048 MiB disk → p1=64 MiB boot, p2/p3=~863 MiB each, p4=256 MiB persist.
  #
  # RAM = 128 MB for QEMU A/B (real hardware uses 64 MB).
  # QEMU virt places its machine FDT at RAM_BASE + RAM_SIZE/2.  With 64 MB that
  # is 0x40000000 + 0x2000000 = 0x42000000 — exactly the same address used by
  # ramdisk_addr_r in boot.scr.  U-Boot marks it reserved and refuses to load
  # the initramfs ("Reading file would overwrite reserved memory").
  # 128 MB moves the FDT to 0x44000000, safely above our load range.
  # Zram is disabled — no kernel modules in the QEMU initramfs.
  system.imageSize = lib.mkDefault 2048;
}
