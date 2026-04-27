# Luckfox Pico Mini B — kernel built from LuckfoxTECH SDK source.
#
# Import this in real-hardware configurations to build the kernel, DTBs,
# and modules from source.  Do NOT import this in QEMU configurations —
# Nix evaluates all module definitions even for overridden options, so
# importing this file in a QEMU config would force the luckfox-kernel
# derivation to build even though the QEMU ARM kernel is used instead.
#
# ── Usage ────────────────────────────────────────────────────────────────────
#
# In configurations/sdimage-ab.nix (or any other real-hardware config):
#
#   imports = [ ../configuration.nix ../hardware/pico-mini-b-kernel.nix ];
#
# ── DTB name ─────────────────────────────────────────────────────────────────
#
# After the first build, inspect the generated DTBs to confirm the filename:
#
#   nix build .#luckfox-kernel && ls result/dtbs/
#
# Common values for the Pico Mini B:
#   rv1103-luckfox-pico-mini-b.dtb
#   rv1106-luckfox-pico-mini-b.dtb
#   luckfox-pico-mini-b.dtb
#
# Update device.dtb below if the name differs.

{ pkgs, ... }:

let
  luckfoxKernel = import ../pkgs/luckfox-kernel.nix { inherit pkgs; };
in

{
  device.kernel            = "${luckfoxKernel}/zImage";
  device.dtb               = "${luckfoxKernel}/dtbs/rv1103-luckfox-pico-mini-b.dtb";
  # Enable kernel modules (required for =m drivers like zram):
  device.kernelModulesPath = "${luckfoxKernel}/lib/modules";
}
