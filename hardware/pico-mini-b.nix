# Hardware profile for the Luckfox Pico Mini B.
#
# ── Kernel ────────────────────────────────────────────────────────────────────
#
# The kernel is built from source via pkgs/luckfox-kernel.nix and injected
# into system configurations automatically by flake.nix when the source hash
# is filled in.  No manual kernel files are needed.
#
# To enable source builds:
#   1. Edit pkgs/luckfox-kernel.nix
#   2. Fill in SDK_REV and SDK_HASH (instructions are in that file)
#   3. nix build .#luckfox-kernel        # verify it builds
#   4. nix build .#sdImage-flashable     # full SD image with built kernel
#
# Until the hash is filled in, device.kernel defaults to null and the SD
# image step is skipped (rootfs and U-Boot bundles still build fine).

{ ... }:

{
  device = {
    name = "pico-mini-b";
    # kernel and dtb are injected by flake.nix from pkgs/luckfox-kernel.nix
    # when SDK_REV / SDK_HASH are filled in.  Until then they remain null.
  };

  # ── A/B rootfs slot configuration ────────────────────────────────────────
  # Partition 1 holds the kernel, initramfs, and rootfs A.
  # Partition 2 holds rootfs B (no kernel — bootloader always reads from p1).
  # Enable in your configuration.nix with:  system.abRootfs.enable = true;
  # The SD image builder creates a two-partition image automatically.
  system.abRootfs = {
    slotDisk   = "/dev/mmcblk0";
    slotOffset = 512;               # byte 512 = sector 1, between MBR and SPL
    slotA      = "/dev/mmcblk0p1";
    slotB      = "/dev/mmcblk0p2";
  };

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
