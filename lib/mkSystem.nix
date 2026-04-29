{ pkgs, lib, buildDate ? "unknown" }:

# configuration — a single module (path or attrset) or a list of modules.
# model         — optional board model string.  When set, the corresponding
#                 hardware kernel file is imported so the real SDK kernel and
#                 U-Boot derivations are available.  Omit for QEMU evaluations
#                 to avoid forcing the Luckfox SDK kernel to be built.
#
#   Valid values:  "pico-mini-b"  — imports hardware/pico-mini-b-kernel.nix
#                  "nova"         — imports hardware/nova-kernel.nix
#                  null (default) — no hardware kernel file imported (QEMU)
{ configuration, model ? null }:

let
  # Hardware kernel files, conditionally included based on model.
  # Each file sets device.kernel, device.dtb, device.kernelModulesPath,
  # boot.uboot.spl, and boot.uboot.package for the selected board.
  # These are kept in separate files so Nix only evaluates the derivations
  # for the board that is actually being built.
  hardwareModules =
    if      model == "pico-mini-b" then [ ../hardware/pico-mini-b-kernel.nix ]
    else if model == "nova"        then [ ../hardware/nova-kernel.nix ]
    else                                [];

in lib.evalModules {
  # buildDate is formatted from self.lastModifiedDate in flake.nix.
  # model is passed through so luckfox-board.nix can use it as the default
  # value for the luckfox.model option without the user having to repeat it.
  specialArgs = { inherit pkgs lib buildDate model; };

  modules = lib.toList configuration ++ hardwareModules ++ [
    ../modules/core/options.nix
    ../modules/core/luckfox-board.nix
    ../modules/core/rootfs.nix
    ../modules/core/services.nix
    ../modules/core/networking.nix
    ../modules/core/uboot.nix
    ../modules/core/image.nix
    ../modules/core/rockchip.nix
    ../modules/core/firmware.nix
    ../modules/core/sdimage.nix
    ../modules/core/mcu.nix
    ../modules/core/usb.nix
    ../modules/core/usb-gadget.nix
    ../modules/core/ab-rootfs.nix
    ../modules/services/default.nix
    ../modules/networking/dhcp.nix
  ];
}
