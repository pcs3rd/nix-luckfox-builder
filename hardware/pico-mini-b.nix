# Hardware profile for the Luckfox Pico Mini B.
#
# Place your Luckfox SDK build outputs here before building:
#   hardware/kernel/zImage
#   hardware/kernel/pico-mini-b.dtb
#
# Until those files are present, kernel and dtb default to null and the SD
# image step will be skipped (rootfs + uboot bundles still build fine).

{ ... }:

{
  device = {
    name   = "pico-mini-b";
    # Uncomment once you have the SDK kernel outputs:
    # kernel = ./kernel/zImage;
    # dtb    = ./kernel/pico-mini-b.dtb;
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
