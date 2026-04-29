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
# In configurations/sdimage.nix (or any other real-hardware config):
#
#   imports = [ ../configuration.nix ../hardware/pico-mini-b-kernel.nix ];
#
# ── DTB selection ─────────────────────────────────────────────────────────────
#
# The SDK's rv1106_defconfig builds generic RV1103G/RV1106G evaluation-board
# DTBs; board-specific Luckfox Pico files are added in postPatch (see
# pkgs/luckfox-kernel.nix) if the DTS source exists in the chosen revision.
#
# To confirm what DTBs are available after a build:
#   nix build .#luckfox-kernel && ls result/dtbs/
#
# ── DTB hierarchy (first existing file wins at runtime) ───────────────────────
#
#   rv1103-luckfox-pico-mini-b.dtb   ← board-specific, built if DTS present
#   rv1103g-evb-v10.dtb              ← RV1103G EVB fallback (always built)
#
# The sdimage builder copies whichever path device.dtb points at; if it
# doesn't exist the build fails with a clear "No such file" error — inspect
# result/dtbs/ and update device.dtb accordingly.

{ pkgs, lib, ... }:

let
  luckfoxKernel = import ../pkgs/luckfox-kernel.nix { inherit pkgs; };

  # Prefer the board-specific DTB; fall back to the generic RV1103G EVB tree.
  # The EVB pinout is close enough to the Pico Mini B for initial bring-up;
  # replace with a proper board DTS once one is available for this SDK revision.
  dtbName =
    if builtins.pathExists "${luckfoxKernel}/dtbs/rv1103-luckfox-pico-mini-b.dtb"
    then "rv1103-luckfox-pico-mini-b.dtb"
    else "rv1103g-evb-v10.dtb";
in

{
  device.kernel            = "${luckfoxKernel}/zImage";
  device.dtb               = "${luckfoxKernel}/dtbs/${dtbName}";
  device.kernelModulesPath = "${luckfoxKernel}/lib/modules";
}
