# QEMU A/B rootfs test configuration.
#
# Boots with a slot-select initramfs that reads /dev/vda at byte 512 to
# determine which ext4 partition to switch_root into.  This lets you test the
# full A/B upgrade flow (/bin/upgrade, slot-flip, reboot) in QEMU without
# real hardware.
#
# ── Disk layout (virtio-blk /dev/vda) ────────────────────────────────────────
#
#   Sector 0    : MBR + partition table
#   Byte 512    : slot indicator byte ('a' or 'b')   ← managed by ab-rootfs.nix
#   Sector 4096 : ext4  slot A  (/dev/vda1) — active on first boot
#   Following A : ext4  slot B  (/dev/vda2) — standby
#
# ── Usage ─────────────────────────────────────────────────────────────────────
#
#   nix run .#qemu-ab                       # launch the VM
#   ssh root@localhost -p <port> slot       # inspect active slot (A or B)
#   ssh root@localhost -p <port> slot       # upgrade to a new rootfs:
#
#   nix build .#qemu-ab-rootfs
#   ssh root@localhost -p <port> upgrade < result/rootfs.ext4
#   # device reboots into the new slot automatically
#
# The QEMU disk is backed by a QCOW2 overlay so slot changes and rootfs
# upgrades persist for the lifetime of the QEMU process but the base image in
# the Nix store stays pristine.  Each nix run .#qemu-ab starts fresh.
#
# ── How the A/B boot path works ──────────────────────────────────────────────
#
#   1. QEMU loads the ARM kernel and the slot-select initramfs directly.
#   2. The initramfs /init reads byte 512 of /dev/vda (the raw disk).
#   3. If byte == 'b': mount /dev/vda2; else mount /dev/vda1.
#   4. exec switch_root into the mounted partition.
#   5. /sbin/init starts in the real rootfs.

{ lib, ... }:

{
  imports = [ ../configuration.nix ];

  # QEMU virt machine uses PL011 UART → ttyAMA0.
  services.getty.tty = "ttyAMA0";

  networking.hostname = lib.mkForce "luckfox-qemu-ab";

  # No root= here — the slot-select initramfs decides which partition to mount.
  boot.cmdline = lib.mkForce "console=ttyAMA0 panic=1";

  # QEMU loads the kernel directly; no bootloader needed.
  boot.uboot.enable = lib.mkForce false;
  rockchip.enable   = lib.mkForce false;

  # No kernel modules tree in the initramfs, so zram modprobe would fail.
  system.zram.enable = lib.mkForce false;

  # A/B — partitions are found at runtime by filesystem label so no device
  # paths are needed here.  Works for both /dev/vda* and /dev/mmcblk0p*.
  system.abRootfs.enable = true;

  # 512 MiB total → ~256 MiB per slot (sector 4096 onward, split in half).
  system.imageSize = lib.mkDefault 512;
}
