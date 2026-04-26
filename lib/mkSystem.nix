{ pkgs, lib }:

# configuration may be a single module (path or attrset) or a list of modules.
{ configuration }:

lib.evalModules {
  specialArgs = { inherit pkgs lib; };

  modules = lib.toList configuration ++ [
    ../modules/core/options.nix
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
