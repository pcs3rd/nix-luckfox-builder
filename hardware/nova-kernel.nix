# Luckfox Nova — kernel, DTB, and U-Boot paths built from source.
#
# Imported by mkSystem when model = "nova".  Do NOT import this in QEMU
# configurations — it forces the nova-kernel and nova-uboot derivations to
# be evaluated, which triggers their full builds.
#
# ── DTB selection ──────────────────────────────────────────────────────────────
#
# pkgs/nova-kernel.nix ships an out-of-tree DTS for the Nova under:
#   arch/arm64/boot/dts/rockchip/rk3308-luckfox-nova.dts
#
# If a board-specific DTB is added upstream before you build, check:
#   nix build .#nova-kernel && ls result/dtbs/
# and update the dtbName fallback below accordingly.

{ pkgs, lib, ... }:

let
  novaKernel = import ../pkgs/nova-kernel.nix { inherit pkgs; };
  novaUboot  = import ../pkgs/nova-uboot.nix  { inherit pkgs; };

  # Prefer the Luckfox-specific DTB; fall back to the generic RK3308B EVB tree.
  dtbName =
    if builtins.pathExists "${novaKernel}/dtbs/rk3308-luckfox-nova.dtb"
    then "rk3308-luckfox-nova.dtb"
    else "rk3308b-evb-v10.dtb";

in {
  device.kernel            = "${novaKernel}/Image";
  device.dtb               = "${novaKernel}/dtbs/${dtbName}";
  device.kernelModulesPath = "${novaKernel}/lib/modules";

  # idbloader.img → stored at boot.uboot.spl, written to raw disk offset 0x8000.
  # u-boot.itb    → stored at boot.uboot.package, written to raw disk offset 0x2000000.
  # The uboot module (modules/core/uboot.nix) copies these to $out/SPL and
  # $out/u-boot.bin respectively, which is what sdimage.nix expects.
  boot.uboot.spl     = "${novaUboot}/idbloader.img";
  boot.uboot.package = "${novaUboot}/u-boot.itb";
}
