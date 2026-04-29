# Luckfox board dispatch module.
#
# Set luckfox.support = true and luckfox.model in your configuration.nix to
# auto-configure USB role switch, slot offset, hostname, and other board-specific
# NON-DERIVATION settings for the selected model.
#
# ── What this module does NOT do ─────────────────────────────────────────────
#
# It intentionally does NOT set device.kernel / device.dtb / device.kernelModulesPath
# or boot.uboot.spl / boot.uboot.package.  Those reference derivations (the
# Luckfox SDK kernel and U-Boot builds) which Nix evaluates as part of any
# module that references them — even when the option is later overridden.
#
# QEMU configurations import configuration.nix (which enables luckfox.support)
# but do NOT need the SDK kernel.  Keeping derivation references out of this
# module ensures QEMU builds never pull in the luckfox-kernel or uboot derivations.
#
# Kernel / U-Boot paths are instead set in hardware/*.nix files that are only
# conditionally imported by lib/mkSystem.nix when the `model` specialArg is
# set to a real hardware target (not used for QEMU evaluations).
#
# ── Usage ─────────────────────────────────────────────────────────────────────
#
#   # configuration.nix
#   {
#     luckfox = {
#       support = true;
#       model   = "pico-mini-b";   # or "nova"
#     };
#   }
#
# The model also needs to match the `model` argument passed to mkSystem in
# flake.nix so that the correct hardware kernel file is imported:
#
#   picoMiniB = mkSystem { configuration = ./configuration.nix; model = "pico-mini-b"; };
#   nova      = mkSystem { configuration = ./configurations/nova-sdimage.nix; model = "nova"; };

{ config, lib, model ? null, ... }:

let
  cfg = config.luckfox;
  m   = cfg.model;
in {

  options.luckfox = {

    support = lib.mkEnableOption ''
      Luckfox board hardware support.

      Enables board-specific defaults for USB role switching, A/B slot offset,
      hostname, U-Boot, and Rockchip layout.  Does NOT force the Luckfox SDK
      kernel to be built — kernel/U-Boot derivations are imported by mkSystem
      based on the `model` specialArg, keeping QEMU builds lightweight.
    '';

    model = lib.mkOption {
      type    = lib.types.enum [ "pico-mini-b" "nova" ];
      default = if model != null then model else "pico-mini-b";
      description = ''
        Luckfox board model.  Controls non-derivation hardware constants:
        USB role-switch sysfs path, slot indicator offset, default hostname, etc.

          pico-mini-b — Luckfox Pico Mini B  (RV1103 / Cortex-A7, ARMv7)
          nova        — Luckfox Nova          (RK3308 / Cortex-A35, AArch64)

        This option must match the `model` argument passed to mkSystem in
        flake.nix, which controls which hardware kernel file is imported.
      '';
    };

  };

  config = lib.mkIf cfg.support (lib.mkMerge [

    # ── Settings common to all Luckfox models ────────────────────────────────
    {
      device.name              = lib.mkDefault m;
      rockchip.enable          = lib.mkDefault true;
      boot.uboot.enable        = lib.mkDefault true;
      system.abRootfs.slotOffset = lib.mkDefault 512;
    }

    # ── Pico Mini B (RV1103 / ARMv7 musl) ───────────────────────────────────
    (lib.mkIf (m == "pico-mini-b") {
      networking.hostname = lib.mkDefault "luckfox";

      # DWC2 OTG controller address on RV1103.  Override if your board's sysfs
      # path differs (check `ls /sys/class/usb_role/` on a running board).
      system.usb.roleSwitchPath = lib.mkDefault
        "/sys/class/usb_role/fcd00000.usb-role-switch/role";
    })

    # ── Nova (RK3308 / AArch64 musl) ─────────────────────────────────────────
    (lib.mkIf (m == "nova") {
      networking.hostname = lib.mkDefault "luckfox-nova";

      # RK3308 has USB 2.0 Host ports but no OTG; force host mode.
      # If your Nova variant has OTG, set system.usb.mode = "otg" in
      # configuration.nix to override this default.
      system.usb.mode = lib.mkDefault "host";
    })

  ]);
}
