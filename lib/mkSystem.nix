{ pkgs, lib }:

{ configuration }:

lib.evalModules {
  specialArgs = { inherit pkgs lib; };

  modules = [
    configuration

    ../modules/core/options.nix
    ../modules/core/rootfs.nix
    ../modules/core/services.nix
    ../modules/core/networking.nix
    ../modules/core/uboot.nix
    ../modules/core/image.nix
    ../modules/core/rockchip.nix
    ../modules/core/firmware.nix
    ../modules/core/sdimage.nix
    ../modules/services/default.nix
    ../modules/networking/dhcp.nix
  ];
}
