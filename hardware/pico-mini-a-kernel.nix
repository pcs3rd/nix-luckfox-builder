# Luckfox Pico Mini A — kernel built from LuckfoxTECH SDK source.
#
# The Pico Mini A and Pico Mini B use the same RV1103 silicon and the same
# DRAM, so the SPL, DDR init blob, and U-Boot are identical between them.
# The only hardware difference is that the Mini A has NO onboard SPI NOR
# flash (the Mini B has an 8 MiB W25Q64 or similar).
#
# Consequently:
#   • The kernel, DTB, and modules come from the same luckfox-kernel derivation.
#   • DTB preference: Mini A board-specific > Mini B board-specific > EVB fallback.
#     Many SDK revisions don't ship a dedicated Mini A DTS; the Mini B DTS works
#     because the peripheral layout is the same.  Once a Mini A DTS appears in the
#     SDK, the build will automatically pick it up.
#   • Do NOT flash spi.img to a Mini A — it has no SPI flash.
#
# ── Usage ────────────────────────────────────────────────────────────────────
#
#   imports = [ ../configuration.nix ../hardware/pico-mini-a-kernel.nix ];
#
# ── DTB selection ─────────────────────────────────────────────────────────────
#
# Run `nix build .#luckfox-kernel && ls result/dtbs/` to see what the current
# SDK revision builds.  Update this file if a Mini A-specific DTB appears.

{ pkgs, lib, ... }:

let
  luckfoxKernel = import ../pkgs/luckfox-kernel.nix { inherit pkgs; };

  # Prefer board-specific Mini A DTB, fall back to Mini B (same hardware minus
  # SPI flash, which is handled by the kernel at runtime, not at DTB level),
  # then fall back to the generic RV1103G EVB tree.
  dtbName =
    if      builtins.pathExists "${luckfoxKernel}/dtbs/rv1103-luckfox-pico-mini-a.dtb"
    then "rv1103-luckfox-pico-mini-a.dtb"
    else if builtins.pathExists "${luckfoxKernel}/dtbs/rv1103-luckfox-pico-mini-b.dtb"
    then "rv1103-luckfox-pico-mini-b.dtb"
    else "rv1103g-evb-v10.dtb";
in

{
  device.kernel            = "${luckfoxKernel}/zImage";
  device.dtb               = "${luckfoxKernel}/dtbs/${dtbName}";
  device.kernelModulesPath = "${luckfoxKernel}/lib/modules";
}
