# Hardware profile for the Pine64 Ox64 (BL808 RISC-V SoC).
#
# The BL808 contains three cores:
#   D0  — RV64GCV (C906) @ 480 MHz  — runs Linux
#   M0  — RV32IMAFCP (E907) @ 320 MHz — runs RTOS / WiFi firmware
#   LP  — RV32EMC (E902) @ 150 MHz   — ultra-low-power
#
# Only D0 runs Linux. M0/LP are handled by firmware blobs loaded by U-Boot.
# RAM: 64 MB PSRAM (shared; Linux sees ~58 MB after firmware reservations).
#
# ── Fetching the kernel blob ─────────────────────────────────────────────────
#
# The kernel Image and DTB are fetched from the OpenBouffalo buildroot release
# by pkgs/ox64-firmware.nix using fetchurl + a pinned SHA256 hash.
#
# Before your first build:
#   1. Open pkgs/ox64-firmware.nix.
#   2. Run the nix-prefetch-url command shown there to get the hash.
#   3. Paste it into BUILDROOT_SHA256.
#
# After that, `nix build .#packages.<system>.ox64-rootfs` will fetch,
# verify, and unpack the blobs automatically — no manual downloads needed.
#
# ── SD card layout ───────────────────────────────────────────────────────────
#
# The Ox64 expects an SD card with these partitions:
#
# Without A/B:
#   p1 — FAT32 boot partition (kernel, DTB, pre-loaders, extlinux.conf)
#   p2 — ext4 rootfs (what this builder produces)
#
# With A/B (system.abRootfs.enable = true):
#   p1 — FAT32 boot partition (kernel, DTB, pre-loaders, extlinux.conf,
#                              slot-select initramfs — set-and-forget)
#   p2 — ext4 rootfs A  (active on first boot)
#   p3 — ext4 rootfs B  (populated on first upgrade)
#
# ── Full SD image (recommended) ──────────────────────────────────────────────
#
# ox64-sdimage.nix builds a 2-partition image that includes both the FAT32
# boot partition (pre-loaders + kernel + DTB + extlinux.conf) and the ext4
# rootfs — no OpenBouffalo sdcard.img needed as a base:
#
#   nix build .#packages.<system>.ox64-sd-image
#   dd if=result/ox64-sdcard.img of=/dev/sdX bs=4M status=progress
#
# ── Rootfs-only update (subsequent upgrades) ──────────────────────────────────
#
# For fast rootfs-only updates over SSH (the FAT boot partition is never
# touched after initial flash):
#
#   dd if=result/image.img of=/dev/sdX2 bs=4M status=progress
#
# With A/B enabled, use /bin/upgrade on the device instead:
#   nix build .#ox64-rootfs-partition
#   ssh root@ox64 upgrade < result/rootfs.ext4
#
# ── U-Boot ──────────────────────────────────────────────────────────────────
# U-Boot for Ox64 lives in https://github.com/openbouffalo/u-boot.
# It reads extlinux/extlinux.conf from the FAT32 boot partition.
# Pre-built U-Boot is included in the OpenBouffalo sdcard.img release.

{ pkgs, lib, ... }:

let
  firmware = import ../pkgs/ox64-firmware.nix { inherit pkgs; };
in

{
  device = {
    name   = "ox64";

    # Fetched automatically from the OpenBouffalo release once you fill in
    # BUILDROOT_SHA256 in pkgs/ox64-firmware.nix.
    kernel      = "${firmware}/Image";
    dtb         = "${firmware}/bl808-pine64-ox64.dtb";

    # Expose the full firmware derivation so ox64-sdimage.nix can include the
    # D0/M0 pre-loaders in the FAT32 boot partition.
    ox64Firmware = firmware;
  };

  # Ox64 serial console is UART0 at 2 Mbaud.
  # mkDefault so QEMU configs can override to ttyAMA0 / 115200.
  services.getty = {
    tty  = lib.mkDefault "ttyS0";
    baud = lib.mkDefault 2000000;
  };

  # Root on mmcblk0p2; p1 is the FAT32 boot partition.
  # With A/B enabled, the actual root is chosen at runtime by the
  # slot-select initramfs — this cmdline is the fallback / informational value.
  boot.cmdline = "console=ttyS0,2000000 root=/dev/mmcblk0p2 rw rootfstype=ext4 rootwait";

  # ── A/B rootfs slot configuration ────────────────────────────────────────
  # p1 is the FAT32 boot partition (never upgraded).
  # Rootfs A lives on p2, rootfs B on p3.
  # Enable in your configuration.nix with:  system.abRootfs.enable = true;
  system.abRootfs = {
    slotDisk   = "/dev/mmcblk0";
    slotOffset = 512;               # byte 512 = sector 1, between MBR and FAT p1
    slotA      = "/dev/mmcblk0p2"; # p1 is the FAT32 boot partition (never upgraded)
    slotB      = "/dev/mmcblk0p3";
  };

  # Rockchip-specific modules don't apply to BL808.
  # mkForce so these win over any conflicting values in configuration.nix.
  rockchip.enable   = lib.mkForce false;
  boot.uboot.enable = lib.mkForce false;

  # ── USB OTG port (BL808 USB controller) ──────────────────────────────────
  # The Ox64 has a single USB 2.0 OTG port.  Default is "otg" (ID-pin).
  # Override in configuration.nix:
  #   system.usb.mode = "host";    # connect USB devices
  #   system.usb.mode = "device";  # appear as USB peripheral to a host PC
  #
  # BL808 USB controller base address is 0x20072000; the role switch node
  # name in sysfs depends on the DTS binding.  If auto-detection fails,
  # confirm the name with  ls /sys/class/usb_role/  on a running Ox64
  # and set roleSwitchPath explicitly.
  # system.usb.roleSwitchPath = "/sys/class/usb_role/20072000.usb-role-switch/role";
}
