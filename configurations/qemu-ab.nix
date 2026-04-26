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
#   Sector 4096 : ext4  slot A  (label: rootfs-a) — kernel + boot.scr + rootfs
#   Following A : ext4  slot B  (label: rootfs-b) — rootfs only
#
# ── Usage ─────────────────────────────────────────────────────────────────────
#
#   nix run .#qemu-ab                       # launch the VM
#   ssh root@localhost -p <port> slot       # inspect active slot (A or B)
#
#   nix build .#qemu-ab-rootfs
#   ssh root@localhost -p <port> upgrade < result/rootfs.ext4
#   # device reboots into the new slot automatically
#
# The QEMU disk is backed by a QCOW2 overlay so slot changes and rootfs
# upgrades persist across QEMU runs.  Pass --reset to start fresh from slot A.
#
# ── How the A/B boot path works ──────────────────────────────────────────────
#
#   1. QEMU starts U-Boot via -bios ${ubootQemuArm}/u-boot.bin.
#   2. U-Boot distro_bootcmd finds /boot.scr in virtio partition 1.
#   3. boot.scr reads sector 1 (the raw slot indicator byte) via
#      "${devtype} read ${loadaddr} 1 1".
#   4. If byte == 'b': setenv rootlabel rootfs-b; else: setenv rootlabel rootfs-a.
#   5. setenv bootargs "… root=LABEL=${rootlabel} rootwait rw"
#   6. ext4load loads /zImage from partition 1.
#   7. bootz starts the kernel; kernel finds the active partition by label.
#   8. /sbin/init starts in the real rootfs — no initramfs involved.

{ pkgs, lib, ... }:

{
  imports = [ ../configuration.nix ];

  # QEMU virt machine uses PL011 UART → ttyAMA0.
  services.getty.tty = "ttyAMA0";

  networking.hostname = lib.mkForce "luckfox-qemu-ab";

  # boot.scr appends root=LABEL=… rootwait rw at runtime; no root= here.
  boot.cmdline = lib.mkForce "console=ttyAMA0 init=/sbin/init panic=1";

  # U-Boot is supplied via -bios, not embedded in the disk image.
  boot.uboot.enable = lib.mkForce false;
  rockchip.enable   = lib.mkForce false;

  # QEMU has ample RAM; zram is unnecessary.
  system.zram.enable = lib.mkForce false;

  # A/B — partitions found at runtime by ext4 label (rootfs-a / rootfs-b).
  # Works for both /dev/vda* (QEMU virtio) and /dev/mmcblk0p* (real hardware).
  system.abRootfs.enable = true;

  # 512 MiB total → ~256 MiB per slot (sector 4096 onward, split in half).
  system.imageSize = lib.mkDefault 512;

  # ── QEMU-only debug tools (not in production) ────────────────────────────
  # lsblk is not in busybox; pull it from util-linux (musl cross-build → static).
  packages = [
    (pkgs.runCommand "qemu-debug-tools" {} ''
      mkdir -p $out/sbin
      cp -L $(find ${pkgs.util-linux} -name lsblk ! -type d | head -1) $out/sbin/lsblk
      chmod +x $out/sbin/lsblk
    '')
  ];
}
