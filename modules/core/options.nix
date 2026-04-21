{ lib, ... }:

with lib;

{
  options = {
    services = {
      ssh.enable = mkEnableOption "ssh";

      "meshing-around" = {
        enable = mkEnableOption "meshing-around Meshtastic BBS bot";
      };

      nrfnet = {
        enable = mkEnableOption "nrfnet TUN/TAP tunnel over nRF24L01+";

        role = mkOption {
          type        = types.enum [ "primary" "secondary" ];
          default     = "primary";
          description = "Node role: primary initiates the tunnel, secondary listens.";
        };

        spiDevice = mkOption {
          type        = types.str;
          default     = "/dev/spidev0.0";
          description = "SPI device connected to the nRF24L01+ module.";
        };

        channel = mkOption {
          type        = types.int;
          default     = 0;
          description = "RF channel (0–125) shared between primary and secondary.";
        };

        extraArgs = mkOption {
          type        = types.listOf types.str;
          default     = [];
          description = "Additional arguments passed verbatim to the nrfnet binary.";
        };
      };

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

      sdOverlay = {
        enable = mkEnableOption ''
          overlayfs using the SD card's free space instead of expanding the rootfs.
          On first boot a second partition is created from the unpartitioned space
          after the rootfs and formatted as ext4.  All writes go to this overlay
          partition; the rootfs partition is never modified.
        '';
        device = mkOption {
          type    = types.str;
          default = "/dev/mmcblk0p2";
          description = "Block device that holds the overlay upper/work dirs (created on first boot).";
        };
      };

      zram = {
        enable = mkEnableOption "zram compressed swap";
        size = mkOption {
          type        = types.str;
          default     = "32M";
          description = ''
            Size of the zram swap device, e.g. "32M" or "64M".
            The device compresses ~3:1 on average so 32M of zram gives
            roughly 96M of effective swap at near-zero latency.
          '';
        };
        algorithm = mkOption {
          type    = types.enum [ "lz4" "lzo" "lzo-rle" "zstd" ];
          default = "lz4";
          description = ''
            Compression algorithm for zram.
              lz4     — fastest compression/decompression; good default.
              lzo     — slightly better ratio than lz4, still very fast.
              lzo-rle — run-length variant of lzo; marginally better for text.
              zstd    — best compression ratio; slightly more CPU intensive.
          '';
        };
      };
    };

    services.user = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          enable = mkEnableOption "this service";
          script = mkOption {
            type        = types.lines;
            description = "Shell script body for the service (shebang is added automatically).";
          };
          action = mkOption {
            type    = types.enum [ "respawn" "once" "sysinit" "wait" "askfirst" ];
            default = "respawn";
            description = ''
              busybox init action type.
                respawn  — restart the process when it exits (long-running daemons).
                once     — run once, do not restart.
                sysinit  — run during early init, block until finished.
                wait     — run once, block until finished (after sysinit).
            '';
          };
        };
      });
      default     = {};
      description = "User-defined services written as shell scripts and wired into inittab.";
    };

    packages = mkOption {
      type        = types.listOf types.package;
      default     = [];
      description = ''
        Extra packages to include in the rootfs.
        Binaries from each package's bin/ and sbin/ are copied into /bin and /sbin.
        Prefer pkgs.pkgsStatic.foo — static binaries are self-contained and need
        no dynamic linker.  Dynamic binaries require their shared libraries too.
      '';
    };

    users = {
      root = {
        hashedPassword = lib.mkOption {
          type        = types.str;
          default     = "!";
          description = ''
            Hashed password for the root account (/etc/shadow format).
            Generate with:  openssl passwd -6 yourpassword
            The default "!" locks the account (no password login possible).
          '';
        };
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
