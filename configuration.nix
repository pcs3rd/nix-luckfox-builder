{ pkgs, ... }:

let
  uboot = import ./pkgs/uboot.nix { inherit pkgs; };
in

{
  imports = [
    ./hardware/pico-mini-b.nix
  ];

  services.ssh.enable = true;
  services.getty.enable = true;

  networking = {
    dhcp.enable = true;
    hostname = "luckfox";
  };

  boot.uboot = {
    enable  = true;
    spl     = "${uboot}/SPL";
    package = "${uboot}/u-boot.bin";
  };

  rockchip.enable = true;
}
