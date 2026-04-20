{ pkgs, ... }:

{
  imports = [
    ./hardware/pico-mini-b.nix
  ];

  services.ssh.enable = true;
  services.getty.enable = true;

  networking = {
    dhcp.enable = true;
    interface = "eth0";
    hostname = "luckfox";
  };

  boot.uboot.enable = true;
  rockchip.enable = true;
}