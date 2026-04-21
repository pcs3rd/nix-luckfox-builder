{ lib, ... }:

with lib;

{
  options = {
    services = {
      ssh.enable = mkEnableOption "ssh";

      "meshing-around" = {
        enable = mkEnableOption "meshing-around Meshtastic BBS bot";

        interface = {
          type = mkOption {
            type        = types.enum [ "serial" "tcp" "ble" ];
            default     = "serial";
            description = ''
              Meshtastic connection type.
                serial — connect via USB serial (e.g. /dev/ttyACM0 or /dev/ttyUSB0).
                tcp    — connect over TCP/IP (hostname must be set).
                ble    — connect via Bluetooth LE (mac must be set).
            '';
          };

          serialPort = mkOption {
            type        = types.str;
            default     = "/dev/ttyACM0";
            description = ''
              Serial device path for the Meshtastic radio.
              Written to config.ini as [interface] port = ...
              Only used when interface.type = "serial".
            '';
          };

          host = mkOption {
            type        = types.str;
            default     = "";
            description = ''
              TCP hostname or IP address of the Meshtastic node.
              Written to config.ini as [interface] hostname = ...
              Only used when interface.type = "tcp".
            '';
          };

          mac = mkOption {
            type        = types.str;
            default     = "";
            description = ''
              Bluetooth LE MAC address of the Meshtastic radio.
              Written to config.ini as [interface] mac = ...
              Only used when interface.type = "ble".
            '';
          };
        };
      };

      meshtasticd = {
        enable = mkEnableOption "meshtasticd Meshtastic Linux-native daemon";

        configFile = mkOption {
          type        = types.nullOr types.path;
          default     = null;
          description = ''
            Path to a meshtasticd config.yaml to install at
            /etc/meshtasticd/config.yaml.  When null the default template
            shipped by the package is used.
          '';
        };

        extraArgs = mkOption {
          type        = types.listOf types.str;
          default     = [];
          description = "Additional arguments passed verbatim to meshtasticd.";
        };
      };

      "mesh-bbs" = {
        enable = mkEnableOption "mesh-bbs minimal Meshtastic BBS + store-and-forward bot";

        interface = {
          type = mkOption {
            type        = types.enum [ "serial" "tcp" ];
            default     = "serial";
            description = ''
              Meshtastic connection type.
                serial — connect via USB serial (e.g. /dev/ttyACM0 or /dev/ttyUSB0).
                tcp    — connect over TCP/IP (host must be set).
            '';
          };

          serialPort = mkOption {
            type        = types.str;
            default     = "/dev/ttyACM0";
            description = "Serial device path for the Meshtastic radio. Only used when type = serial.";
          };

          host = mkOption {
            type        = types.str;
            default     = "";
            description = "TCP hostname or IP of the Meshtastic node. Only used when type = tcp.";
          };
        };

        channel = mkOption {
          type        = types.int;
          default     = 0;
          description = ''
            Meshtastic channel index (0-7) to monitor for BBS/SNF commands.
            The bot only responds to direct messages received on this channel.
            Node-presence tracking and store-and-forward delivery are channel-agnostic:
            a node coming online on any channel will still receive its queued messages.
          '';
        };

        listLimit = mkOption {
          type        = types.int;
          default     = 10;
          description = ''
            Maximum number of posts shown by the `bbs list` command.
            Keep this low enough that the reply fits in a handful of LoRa packets.
          '';
        };

        maxMessageLen = mkOption {
          type        = types.int;
          default     = 200;
          description = ''
            Maximum bytes per outgoing message chunk.
            Meshtastic LoRa payloads are at most 237 bytes; leaving headroom for
            framing overhead means 200 is a safe default.  Increase to ~230 on
            high-bandwidth channels (WiFi mesh), decrease on congested networks.
          '';
        };

        dataDir = mkOption {
          type        = types.str;
          default     = "/var/lib/mesh-bbs";
          description = ''
            Directory where BBS posts and store-and-forward queues are stored
            as JSON files.  Must be writable at runtime; typically on the
            overlay partition when using sdOverlay.
          '';
        };
      };

      companion-satellite = {
        enable = mkEnableOption "Bitfocus Companion Satellite client";

        host = mkOption {
          type        = types.str;
          default     = "companion.local";
          description = "Hostname or IP address of the main Companion server to connect to.";
        };

        port = mkOption {
          type        = types.int;
          default     = 16622;
          description = "TCP port of the Companion server's satellite listener (default: 16622).";
        };
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
      kernelModulesPath = mkOption {
        type        = types.nullOr types.path;
        default     = null;
        description = ''
          Path to a kernel lib/modules directory to include in the rootfs.
          The directory must contain a subdirectory named after the kernel version
          (e.g. lib/modules/5.10.110+/).  modprobe will find modules there at runtime.

          Example — using the luckfox-kernel-modules package:
            device.kernelModulesPath = "''${localPkgs.luckfox-kernel-modules}/lib/modules";
        '';
      };
    };

    system.usb = {
      mode = mkOption {
        type    = types.enum [ "host" "device" "otg" ];
        default = "otg";
        description = ''
          USB OTG port operating mode.
            host    — USB-A: connect keyboards, hubs, drives, etc.
            device  — USB peripheral: appear to a host computer as a serial
                      port, ethernet adapter, or mass-storage device depending
                      on which kernel gadget driver is loaded.
            otg     — let the hardware ID pin decide automatically (default).
                      No configuration script is generated.
        '';
      };

      roleSwitchPath = mkOption {
        type    = types.nullOr types.str;
        default = null;
        description = ''
          Absolute path to the kernel USB role switch sysfs file, e.g.:
            /sys/class/usb_role/fcd00000.usb-role-switch/role   (RV1103)
            /sys/class/usb_role/4200000.usb-role-switch/role    (BL808)
          When null (the default), the path is auto-detected at boot by
          scanning /sys/class/usb_role/.  Set this explicitly if your board
          has more than one USB controller and auto-detection picks the wrong one.
        '';
      };
    };

    system.mcu = {
      enable = mkEnableOption ''
        /bin/mcu helper script for controlling an attached MCU's reset and bootloader pins
        via GPIO (using a MOSFET as an electronic switch).
      '';

      resetPin = mkOption {
        type        = types.int;
        default     = 47;
        description = ''
          Linux GPIO number for the RESET pin MOSFET gate.
          Find it with:  gpioinfo  or  cat /sys/kernel/debug/gpio
          The script drives this pin LOW for 100 ms to simulate a button press.
        '';
      };

      bootloaderPin = mkOption {
        type        = types.int;
        default     = (-1);
        description = ''
          Linux GPIO number for a dedicated BOOT/BOOTSEL pin, or -1 to use the
          double-tap-reset convention instead (RP2040 UF2 style).
          When set, `mcu bootloader` holds this pin LOW while pulsing RESET once
          (STM32 DFU / nRF52 OTA style).
        '';
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
