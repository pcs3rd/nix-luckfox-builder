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

    overlay.enable = mkEnableOption "overlay";

    boot = {
      cmdline = mkOption {
        type = types.str;
        default = "console=ttyS0 root=/dev/mmcblk0p1 rw rootfstype=ext4";
        description = "Linux kernel command line";
      };

      uboot = {
        enable = mkEnableOption "uboot";
        spl = mkOption { type = types.nullOr types.path; default = null; };
        package = mkOption { type = types.nullOr types.path; default = null; };
        env = mkOption { type = types.attrsOf types.str; default = {}; };
      };
    };

    rockchip.enable = mkEnableOption "rockchip";

    device = {
      name = mkOption { type = types.str; };
      kernel = mkOption { type = types.path; };
      dtb = mkOption { type = types.path; };
    };

    system = {
      imageSize = mkOption { type = types.int; default = 256; };
    };

    system.build = {
      rootfs = mkOption { type = types.path; readOnly = true; };
      image = mkOption { type = types.path; readOnly = true; };
      uboot = mkOption { type = types.path; readOnly = true; };
      rockchip = mkOption { type = types.path; readOnly = true; };
      firmware = mkOption { type = types.path; readOnly = true; };
    };
  };
}