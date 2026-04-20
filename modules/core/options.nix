
{ lib, ... }:

with lib;

{
  options = {

    services = {
      ssh.enable = mkEnableOption "ssh";
      getty.enable = mkEnableOption "getty";
    };

    networking = {
      dhcp.enable = mkEnableOption "dhcp";
      interface = mkOption { type = types.str; default = "eth0"; };
      hostname = mkOption { type = types.str; default = "luckfox"; };
    };

    overlay = {
      enable = mkEnableOption "overlay";
    };

    boot.uboot = {
      enable = mkEnableOption "uboot mode A";
      spl = mkOption { type = types.nullOr types.path; default = null; };
      package = mkOption { type = types.nullOr types.path; default = null; };
      env = mkOption { type = types.attrsOf types.str; default = {}; };
    };

    rockchip = {
      enable = mkEnableOption "rockchip NAND/eMMC layout";
    };

    system = {
      imageSize = mkOption { type = types.int; default = 256; };
    };

    device = {
      name = mkOption { type = types.str; };
      kernel = mkOption { type = types.path; };
      dtb = mkOption { type = types.path; };
    };

    system.build = {
      rootfs = mkOption { type = types.path; readOnly = true; };
      image = mkOption { type = types.path; readOnly = true; };
      uboot = mkOption { type = types.path; readOnly = true; };
      firmware = mkOption { type = types.path; readOnly = true; };
      rockchip = mkOption { type = types.path; readOnly = true; };
    };
  };
}
