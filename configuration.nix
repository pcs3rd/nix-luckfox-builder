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

{ pkgs, buildDate ? "unknown", ... }:

let
  localPkgs = import ./pkgs { inherit pkgs; };
in

{
  # ── Board selection ─────────────────────────────────────────────────────────
  # The luckfox-board module (modules/core/luckfox-board.nix) sets the kernel,
  # DTB, U-Boot paths, hostname, and USB role-switch path automatically.
  # Change model to "pico-mini-a" for the Mini A (no SPI flash).
  luckfox = {
    support = true;
    model   = "pico-mini-a";   # "pico-mini-a" | "pico-mini-b"
  };

  # ── Extra packages ──────────────────────────────────────────────────────────
  # Binaries from each package's bin/ are copied into /bin on the rootfs.
  # Prefer pkgs.pkgsStatic.foo — static binaries need no dynamic linker.
  packages = with localPkgs; [
    sysinfo        # lightweight system-info utility (static)
    #top           # interactive process viewer
    #nano           # text editor
   #meshtastic-cli # meshtastic CLI  (`meshtastic --info`, `--sendtext`, etc.)
    # nrfnet is added automatically when services.nrfnet.enable = true
  ];

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
  # When enabled, the image uses squashfs slots + overlayfs for persistence:
  #   p1 ext4 "boot"    — kernel + initramfs
  #   p2 squashfs       — slot A rootfs (read-only, compressed)
  #   p3 squashfs       — slot B rootfs (read-only, compressed)
  #   p4 ext4 "persist" — overlay writable layer (survives reboots)
  # /bin/upgrade and /bin/slot are added to the rootfs automatically.
  #
  # Build:   nix build .#sdImage-ab
  # Flash:   dd if=result/sd-flashable.img of=/dev/sdX bs=4M status=progress
  # Upgrade: nix build .#rootfsPartition
  #          ssh root@luckfox upgrade < result/rootfs.squashfs
  #
  system.abRootfs = {
    enable      = true;
    swapSize    = 32;   # MiB of disk swap in persist partition — disable with 0
    persistSize = 64;   # MiB for overlayfs upper/work dirs (default 256 is excessive)
  };

  # Total SD image size in MiB.  Slots get whatever's left after boot + persist:
  #   512 MiB − 2 MiB gap − 64 MiB boot − 64 MiB persist = 382 MiB ÷ 2 = 191 MiB/slot
  # Increase if your rootfs squashfs ever exceeds ~150 MiB.
  system.imageSize = 512;
  # ── Services ────────────────────────────────────────────────────────────────

  services.getty.enable = true;    # serial console on ttyS0
  services.ssh.enable   = false;    # dropbear SSH; set users.root.hashedPassword first

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

  # ── Login banner ────────────────────────────────────────────────────────────
  # /etc/issue — shown by getty before the login prompt.
  # \n = hostname, \l = tty, \r = kernel release.
  system.banner = ''
    Luckfox Pico Mini B — \n  (\l)
    Kernel \r  |  Built ${buildDate}
  '';

  # /etc/motd — shown after successful login.
  system.motd = ''
    Type 'slot' to check the active A/B slot.
    Type 'upgrade < image' to update the inactive slot.
  '';

  # ── Networking ──────────────────────────────────────────────────────────────
  # hostname is set automatically by luckfox-board based on the model.
  # Override here if needed: networking.hostname = "my-device";
  networking.dhcp.enable = true;

  # ── Users ───────────────────────────────────────────────────────────────────
  # Generate a new hash with:  openssl passwd -6 yourpassword
  # The default "!" locks the root account (no password login).
  users.root.hashedPassword = "$6$C.ixvv4jaDPZ1/1a$hU.1hdJ8ExItvl0gOL6wH7Itene4DOP8AHUfaXPHC4TGoeOGGyVC.CmkwNStNYRLxkrHsPHQTLF5W1zy4yL1x/";
}
