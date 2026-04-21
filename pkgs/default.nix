# Package set for the Luckfox Pico Mini B.
#
# Import this file to get an attrset of all local packages:
#
#   pkgSet = import ./pkgs { inherit pkgs; };
#
# Then reference individual packages:
#   pkgSet.uboot      — U-Boot SPL + binary
#   pkgSet.sysinfo    — static system-info utility
#   pkgSet.htop       — htop (if enabled)

{ pkgs }:

{
  uboot                  = import ./uboot.nix                  { inherit pkgs; };
  luckfox-kernel-modules = import ./luckfox-kernel-modules.nix { inherit pkgs; };
  sysinfo                = import ./sysinfo/sysinfo.nix        { inherit pkgs; };
  htop                   = import ./htop.nix                   { inherit pkgs; };
  nano                   = import ./nano.nix                   { inherit pkgs; };
  meshing-around         = import ./meshing-around.nix         { inherit pkgs; };
  meshtasticd            = import ./meshtasticd.nix            { inherit pkgs; };
  rf24                   = import ./rf24.nix                   { inherit pkgs; };
  nrfnet                 = import ./nrfnet.nix                 { inherit pkgs; };
  "mesh-bbs"             = import ./mesh-bbs                   { inherit pkgs; };
  meshtastic-cli         = import ./meshtastic-cli.nix         { inherit pkgs; };
  # ox64-firmware intentionally omitted here — it is imported directly by
  # hardware/ox64.nix using the pkgsRv64 package set, not the ARMv7 pkgs.
  # Build it with:  nix build .#packages.<system>.ox64-firmware
}
