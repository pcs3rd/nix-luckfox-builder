# nix-luckfox-builder — main system configuration
#
# This file is the single place to customise the firmware image.
# It is imported by both the real-hardware build and the QEMU test configs.
#
# After editing, rebuild with:
#   nix build .#packages.aarch64-darwin.pico-mini-b
# or flash directly:
#   nix build .#packages.aarch64-darwin.sdImage-flashable
#   dd if=result/sd-flashable.img of=/dev/sdX bs=4M status=progress

{ pkgs, ... }:

let
  localPkgs = import ./pkgs { inherit pkgs; };
in

{
  imports = [
    ./hardware/pico-mini-b.nix
  ];

  # ── Extra packages ──────────────────────────────────────────────────────────
  # Binaries from each package's bin/ are copied into /bin on the rootfs.
  # Prefer pkgs.pkgsStatic.foo — static binaries need no dynamic linker.
  packages = with localPkgs; [
    sysinfo        # lightweight system-info utility (static)
    htop           # interactive process viewer
    nano           # text editor
    meshtastic-cli # meshtastic CLI  (`meshtastic --info`, `--sendtext`, etc.)
    pkgs.pkgsStatic.util-linux # lsblk, blkid, etc. — static so no dynamic linker needed
    # nrfnet is added automatically when services.nrfnet.enable = true
  ];

  # ── Kernel modules ──────────────────────────────────────────────────────────
  # Required for CONFIG_ZRAM=m and any other =m driver.
  # Uncomment once you have verified the luckfox-kernel-modules build succeeds:
  #   nix build .#packages.aarch64-darwin.pico-mini-b
  # device.kernelModulesPath = "${localPkgs.luckfox-kernel-modules}/lib/modules";

  # ── System ──────────────────────────────────────────────────────────────────

  # USB OTG port mode — "host" | "device" | "otg" (auto/ID-pin, default)
  #system.usb.mode = "host";

  # USB gadget — exposes virtual functions when the OTG port is in device mode.
  # "acm" gives a CDC-ACM serial console; connect with: screen /dev/ttyACM0 115200
  system.usb.mode = "device";
  system.usbGadget = {
    enable    = true;
    functions = [ "acm" ];
    product   = "Luckfox";
  };

  # Compressed RAM swap — ~96 MB effective swap on a 64 MB board at near-zero latency.
  system.zram = {
    enable    = true;
    size      = "32M";
    algorithm = "lz4";
  };

  # MCU control — toggle GPIO pins via MOSFET to reset/bootload an attached MCU.
  system.mcu = {
    enable        = true;
    resetPin      = 47;   # GPIO connected to the RESET MOSFET gate
    bootloaderPin = -1;   # -1 = double-tap reset (RP2040); set for BOOT pin (STM32/nRF)
  };

  # ── A/B rootfs (zero-downtime SSH upgrades) ─────────────────────────────────
  # When enabled, the image gains two equal-size rootfs partitions and a tiny
  # slot-select initramfs that mounts the active one at boot.  /bin/upgrade
  # and /bin/slot are added to the rootfs automatically.
  #
  # Build:   nix build .#sdImage-ab
  # Flash:   dd if=result/sd-flashable.img of=/dev/sdX bs=4M status=progress
  # Upgrade: nix build .#rootfsPartition
  #          ssh root@luckfox upgrade < result/rootfs.ext4
  #
  system.abRootfs.enable = true;

  # ── Bootloader ──────────────────────────────────────────────────────────────
  boot.uboot = {
    enable  = true;
    spl     = "${localPkgs.uboot}/SPL";
    package = "${localPkgs.uboot}/u-boot.img";
  };

  rockchip.enable = true;

  # ── Services ────────────────────────────────────────────────────────────────

  services.getty.enable = true;    # serial console on ttyS0
  services.ssh.enable   = true;    # dropbear SSH; set users.root.hashedPassword first

  # mesh-bbs: minimal Meshtastic BBS + store-and-forward bot.
  # Commands via direct message: bbs list/read/post, snf send/list
  services."mesh-bbs" = {
    enable        = false;
    interface = {
      type       = "serial";
      serialPort = "/dev/ttyACM0";   # or /dev/ttyUSB0 for UART adapters
      # type     = "tcp";
      # host     = "192.168.1.x";
    };
    channel       = 0;     # Meshtastic channel index to monitor (0-7)
    listLimit     = 10;    # max posts shown by `bbs list`
    maxMessageLen = 200;   # bytes per outgoing LoRa chunk (max ~230)
    dataDir       = "/var/lib/mesh-bbs";
  };

  # nrfnet: TUN/TAP tunnel over nRF24L01+.
  # Setting enable = true installs /bin/nrfnet but does NOT auto-start the daemon.
  # Run manually: nrfnet --primary --spi_device=/dev/spidev0.0 --channel=42
  services.nrfnet = {
    enable    = false;
    role      = "primary";         # or "secondary"
    spiDevice = "/dev/spidev0.0";
    channel   = 42;
  };

  # meshing-around: full-featured Meshtastic BBS bot (weather, games, APRS, …).
  # Disabled by default — use mesh-bbs above for a leaner alternative.
  services."meshing-around" = {
    enable = false;
    interface = {
      type       = "serial";
      serialPort = "/dev/ttyACM0";
      # type     = "tcp";
      # host     = "192.168.1.x";
    };
  };

  # meshtasticd: Linux-native Meshtastic daemon (runs a full mesh node on the SBC).
  services.meshtasticd = {
    enable = false;
    # configFile = ./meshtasticd-config.yaml;   # omit to use built-in template
  };

  # companion-satellite: Bitfocus Companion peripheral client.
  # Connects USB HID devices (Stream Deck, etc.) to a remote Companion server.
  # See pkgs/companion-satellite.nix for the one-time hash setup step.
  services.companion-satellite = {
    enable = false;
    host   = "companion.local";   # hostname or IP of your Companion server
    port   = 16622;
  };

  # ── Networking ──────────────────────────────────────────────────────────────
  networking = {
    dhcp.enable = true;
    hostname    = "luckfox";
  };

  # ── Users ───────────────────────────────────────────────────────────────────
  # Generate a new hash with:  openssl passwd -6 yourpassword
  # The default "!" locks the root account (no password login).
  users.root.hashedPassword = "$6$C.ixvv4jaDPZ1/1a$hU.1hdJ8ExItvl0gOL6wH7Itene4DOP8AHUfaXPHC4TGoeOGGyVC.CmkwNStNYRLxkrHsPHQTLF5W1zy4yL1x/";
}
