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
# ── Kernel ────────────────────────────────────────────────────────────────────
#
# The kernel is built from source via pkgs/ox64-kernel.nix (OpenBouffalo Linux
# fork, cross-compiled to riscv64) and injected into system configurations
# automatically by flake.nix when the source hash is filled in.
#
# To enable source builds:
#   1. Edit pkgs/ox64-kernel.nix
#   2. Fill in KERNEL_REV and KERNEL_HASH (instructions are in that file)
#   3. nix build .#ox64-kernel           # verify it builds
#   4. nix build .#ox64-rootfs           # rootfs with built kernel
#
# Pre-built kernel fallback (ox64-firmware.nix):
# If you prefer to use the OpenBouffalo release binaries instead of building
# from source, the ox64-firmware.nix fetcher is still available:
#   nix build .#ox64-firmware
# The firmware package also provides the M0 pre-loader blobs which are
# always needed in the FAT boot partition regardless of how the kernel is built.
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
# NOTE: sdimage.nix handles the Luckfox (ext4-only) SD layout.  The Ox64
# FAT32 boot partition is managed separately via the OpenBouffalo sdcard.img.
# Use that image as a base and flash the Nix-built rootfs onto p2 (and p3
# when using A/B):
#   dd if=result/rootfs.img of=/dev/sdX2 bs=4M status=progress
#
# For A/B: also copy the slot-select initramfs into the FAT boot partition:
#   nix build .#slotSelectInitramfs
#   mount /dev/sdX1 /mnt
#   cp result/initramfs-slotselect.cpio.gz /mnt/
#   # add  INITRD /initramfs-slotselect.cpio.gz  to extlinux/extlinux.conf
#   umount /mnt
#
# ── U-Boot ──────────────────────────────────────────────────────────────────
# U-Boot for Ox64 lives in https://github.com/openbouffalo/u-boot.
# It reads extlinux/extlinux.conf from the FAT32 boot partition.
# Pre-built U-Boot is included in the OpenBouffalo sdcard.img release.

{ pkgs, lib, ... }:

let
  # Pre-built kernel + M0 pre-loader blobs from the OpenBouffalo release.
  # Used as the kernel/dtb source when pkgs/ox64-kernel.nix hashes aren't set,
  # AND always needed for the M0 pre-loader blobs in the FAT boot partition.
  firmware = import ../pkgs/ox64-firmware.nix { inherit pkgs; };

  # Source-built kernel from pkgs/ox64-kernel.nix (null if hash not filled in).
  # flake.nix injects device.kernel/dtb/kernelModulesPath from this when non-null,
  # so these device settings below act as the firmware-blob fallback.
  firmwareKernel = "${firmware}/Image";
  firmwareDtb    = "${firmware}/bl808-pine64-ox64.dtb";
in

{
  device = {
    name = "ox64";

    # Fallback: pre-built kernel from the OpenBouffalo firmware release.
    # lib.mkDefault gives this lower priority so flake.nix can override with
    # a source-built kernel (via ox64KernelModule) when hashes are filled in.
    kernel = lib.mkDefault firmwareKernel;
    dtb    = lib.mkDefault firmwareDtb;
  };

  # Ox64 serial console is UART0 at 2 Mbaud
  services.getty = {
    tty  = "ttyS0";
    baud = 2000000;
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

  # Rockchip-specific modules don't apply to BL808
  rockchip.enable   = false;
  boot.uboot.enable = false;

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
