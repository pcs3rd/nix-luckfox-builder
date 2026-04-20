{ lib, ... }:

with lib;

{
  options = {
    services = {
      ssh.enable = mkEnableOption "ssh";

      getty = {
        enable = mkEnableOption "getty";
        tty = mkOption {
          type        = types.str;
          default     = "ttyS0";
          description = "Serial console device. Use ttyS0 for real hardware, ttyAMA0 for QEMU virt.";
        };
        baud = mkOption {
          type        = types.int;
          default     = 115200;
          description = "Baud rate for the serial console.";
        };
      };
    };

    networking = {
      dhcp.enable = mkEnableOption "dhcp";
      interface = mkOption {
        type    = types.str;
        default = "eth0";
      };
      hostname = mkOption {
        type    = types.str;
        default = "luckfox";
      };
    };

    overlay.enable = mkEnableOption "overlay";

    boot = {
      cmdline = mkOption {
        type        = types.str;
        default     = "console=ttyS0 root=/dev/mmcblk0p1 rw rootfstype=ext4";
        description = "Kernel command line passed by the bootloader.";
      };

      uboot = {
        enable  = mkEnableOption "uboot";
        spl     = mkOption {
          type        = types.nullOr types.path;
          default     = null;
          description = "Path to the SPL binary (e.g. ./uboot/SPL). Leave null if not yet available.";
        };
        package = mkOption {
          type        = types.nullOr types.path;
          default     = null;
          description = "Path to u-boot.bin. Leave null if not yet available.";
        };
        env = mkOption {
          type    = types.attrsOf types.str;
          default = {};
        };
      };
    };

    rockchip.enable = mkEnableOption "rockchip";

    system = {
      imageSize = mkOption {
        type        = types.int;
        default     = 256;
        description = "Size of the generated disk image in MiB.";
      };

      sdExpand = {
        enable = mkEnableOption "self-expanding root filesystem on first boot";
      };
    };

    device = {
      name = mkOption {
        type    = types.str;
        default = "unknown";
      };
      kernel = mkOption {
        type        = types.nullOr types.path;
        default     = null;
        description = "Path to the kernel zImage. Required for SD image builds.";
      };
      dtb = mkOption {
        type        = types.nullOr types.path;
        default     = null;
        description = "Path to the device tree blob. Required for SD image builds.";
      };
    };

    system.build = {
      rootfs    = mkOption { type = types.path; readOnly = true; };
      initramfs = mkOption { type = types.path; readOnly = true; };
      image     = mkOption { type = types.path; readOnly = true; };
      sdImage   = mkOption { type = types.path; readOnly = true; };
      uboot     = mkOption { type = types.path; readOnly = true; };
      rockchip  = mkOption { type = types.path; readOnly = true; };
      firmware  = mkOption { type = types.path; readOnly = true; };
    };
  };
}
