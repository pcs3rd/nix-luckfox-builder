# Hardware profile for the Luckfox Pico Mini B.
#
# The kernel, DTBs, and modules are built from the LuckfoxTECH SDK source by
# pkgs/luckfox-kernel.nix — no pre-built binaries need to be dropped in
# manually.
#
# ── Finding the right DTB ─────────────────────────────────────────────────────
#
# The first build will print the DTBs installed in result/dtbs/.  If the name
# below doesn't match, update device.dtb to the correct path.  Common values:
#
#   ${luckfoxKernel}/dtbs/rv1103-luckfox-pico-mini-b.dtb
#   ${luckfoxKernel}/dtbs/rv1106-luckfox-pico-mini-b.dtb
#   ${luckfoxKernel}/dtbs/luckfox-pico-mini-b.dtb
#
# Build and inspect:
#   nix build .#packages.<system>.luckfox-kernel
#   ls result/dtbs/

{ pkgs, ... }:

let
  luckfoxKernel = import ../pkgs/luckfox-kernel.nix { inherit pkgs; };
in

{
  device = {
    name   = "pico-mini-b";
    kernel = "${luckfoxKernel}/zImage";
    # Adjust the DTB filename to match what `nix build .#luckfox-kernel` produces.
    # See result/dtbs/ after the first build.
    dtb    = "${luckfoxKernel}/dtbs/rv1103-luckfox-pico-mini-b.dtb";
    # Kernel modules — enables modprobe for =m drivers (zram, etc.)
    kernelModulesPath = "${luckfoxKernel}/lib/modules";
  };

  # ── A/B rootfs slot configuration ────────────────────────────────────────
  # Enables squashfs + overlayfs A/B upgrades with 4 partitions:
  #   p1 = ext4 "boot"    (kernel + initramfs + boot.scr)
  #   p2 = squashfs slot A  (read-only rootfs)
  #   p3 = squashfs slot B  (read-only rootfs)
  #   p4 = ext4 "persist"  (overlayfs upper/work dirs)
  # Enable in your configuration.nix with:  system.abRootfs.enable = true;
  system.abRootfs.slotOffset = 512;   # byte 512 = sector 1, between MBR and SPL

  # ── USB OTG port (RV1103 DWC2 controller at 0xfcd00000) ─────────────────
  # The RV1103 has a single USB 2.0 OTG port exposed via the Micro-USB
  # connector.  Default is "otg" (ID-pin detection).  Override in
  # configuration.nix if you want to force a specific mode:
  #
  #   system.usb.mode = "host";    # connect USB devices
  #   system.usb.mode = "device";  # appear as USB peripheral to a host PC
  #
  # The role switch sysfs path for RV1103.  Confirm with:
  #   ls /sys/class/usb_role/          (on a running board)
  # If the name differs, set system.usb.roleSwitchPath explicitly.
  system.usb.roleSwitchPath = "/sys/class/usb_role/fcd00000.usb-role-switch/role";
}
