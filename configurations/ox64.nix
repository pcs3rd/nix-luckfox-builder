# Pine64 Ox64 (BL808) configuration.
#
# Architecture: RV64GCV (C906) @ 480 MHz, 64 MB PSRAM, musl libc
#
# Build with:
#   nix build .#packages.<system>.ox64
#
# This target requires the flake.nix to define an ox64 system using:
#   crossSystem = { config = "riscv64-unknown-linux-musl"; }
#
# See hardware/ox64.nix for how to obtain the kernel and device tree.

{ pkgs, lib, ... }:

let
  localPkgs = import ../pkgs { inherit pkgs; };
in

{
  imports = [
    ../hardware/ox64.nix
  ];

  packages = with localPkgs; [
    sysinfo
    nano
  ];

  system.zram = {
    enable    = true;
    size      = "16M";     # conservative — only 64 MB total PSRAM
    algorithm = "lz4";
  };

  services.getty = {
    enable = true;
    tty    = "ttyS0";
    baud   = 2000000;
  };

  services.ssh.enable = true;

  networking = {
    dhcp.enable = true;
    hostname    = "ox64";
  };

  # Ox64 does not use Rockchip tooling
  rockchip.enable   = false;
  boot.uboot.enable = false;

  system.imageSize = 256;   # rootfs partition size in MiB

  users.root.hashedPassword = "!";   # lock account until you set a password
}
