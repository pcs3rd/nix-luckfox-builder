# Luckfox board hardware abstraction module.
#
# Declares the luckfox.support and luckfox.model options and sets all
# hardware-specific configuration — kernel, DTB, U-Boot, USB paths, hostname —
# based on the chosen model.
#
# ── Usage in configuration.nix ───────────────────────────────────────────────
#
#   luckfox = {
#     support = true;
#     model   = "pico-mini-b";   # or "pico-mini-a"
#   };
#
# ── QEMU configurations ───────────────────────────────────────────────────────
#
# QEMU configs import configuration.nix (which sets luckfox.support = true),
# so add this to any QEMU config to opt out of all Luckfox hardware settings:
#
#   luckfox.support = lib.mkForce false;
#
# This prevents the Luckfox kernel/U-Boot derivations from even being described
# during Nix evaluation for QEMU builds.
#
# ── Board summary ─────────────────────────────────────────────────────────────
#
#   pico-mini-a  RV1103, no SPI flash.  Boot ROM → SD card directly.
#                No SPI flashing needed or possible.
#
#   pico-mini-b  RV1103 + 8 MiB SPI NOR flash.  Boot ROM tries SPI first;
#                SPI must be blank or contain our SPL to reach SD card.

{ config, lib, pkgs, ... }:

let
  cfg = config.luckfox;
  m   = cfg.model;
in

{
  options.luckfox = {
    support = lib.mkEnableOption "Luckfox board hardware support";

    model = lib.mkOption {
      type    = lib.types.enum [ "pico-mini-a" "pico-mini-b" ];
      default = "pico-mini-b";
      description = ''
        Target board model.  Controls which DTB, hostname, and hardware paths
        are used.

          "pico-mini-a" — RV1103, no SPI NOR flash.
          "pico-mini-b" — RV1103, 8 MiB SPI NOR flash onboard.
      '';
    };
  };

  # All config is inside lib.mkIf cfg.support so that QEMU builds (which set
  # luckfox.support = false) never force evaluation of any kernel/U-Boot paths.
  config = lib.mkIf cfg.support (
    let
      # Lazily imported — only evaluated when luckfox.support = true.
      luckfoxKernel = import ../../pkgs/luckfox-kernel.nix { inherit pkgs; };
      # U-Boot is built with the system boot.cmdline baked in as CONFIG_BOOTARGS.
      # BOOTCOMMAND loads zImage/board.dtb/initramfs directly (no boot.scr/source).
      uboot = import ../../pkgs/uboot.nix { inherit pkgs; cmdline = config.boot.cmdline; };

      # DTB selection: prefer board-specific, fall back to EVB generic.
      # builtins.pathExists checks the Nix store at eval time; returns false on
      # a fresh system (kernel not yet built).  On the first build the EVB DTB
      # is used; subsequent builds with the kernel cached use the board DTB.
      # Run `nix build .#luckfox-kernel && ls result/dtbs/` to inspect.
      miniADtb =
        if      builtins.pathExists "${luckfoxKernel}/dtbs/rv1103-luckfox-pico-mini-a.dtb"
        then "rv1103-luckfox-pico-mini-a.dtb"
        else if builtins.pathExists "${luckfoxKernel}/dtbs/rv1103-luckfox-pico-mini-b.dtb"
        then "rv1103-luckfox-pico-mini-b.dtb"
        else    "rv1103g-evb-v10.dtb";

      miniBDtb =
        if      builtins.pathExists "${luckfoxKernel}/dtbs/rv1103-luckfox-pico-mini-b.dtb"
        then "rv1103-luckfox-pico-mini-b.dtb"
        else    "rv1103g-evb-v10.dtb";

    in lib.mkMerge [

      # ── Common RV1103 settings ────────────────────────────────────────────
      {
        rockchip.enable   = lib.mkDefault true;
        boot.uboot.enable = lib.mkDefault true;
        boot.uboot = {
          # idblock.img is the Rockchip idbloader: DDR init blob + SPL packed
          # together.  It is written at sector 64 of the SD card (and offset
          # 0x8000 of SPI NOR on Mini B).  This binary is board-specific — the
          # DDR timing parameters must match the exact DRAM chip on the board.
          #
          # We commit the verified-working binary from the Ubuntu Luckfox Mini A
          # demo image rather than building it from source, because the SDK's
          # project/image/ pre-builts vary by board and the mkimage -T rksd
          # approach has chip-name limitations in U-Boot 2017.09.
          spl     = lib.mkDefault ../../hardware/rv1103/idblock.img;
          package = lib.mkDefault "${uboot}/u-boot.img";
        };

        # Slot indicator byte lives at byte 512 (between MBR and SPL sector 64).
        system.abRootfs.slotOffset = lib.mkDefault 512;

        # USB OTG controller address is the same on all RV1103 boards.
        system.usb.roleSwitchPath = lib.mkDefault
          "/sys/class/usb_role/fcd00000.usb-role-switch/role";
      }

      # ── Pico Mini A (no SPI NOR flash) ────────────────────────────────────
      (lib.mkIf (m == "pico-mini-a") {
        device.name = lib.mkDefault "pico-mini-a";
        networking.hostname      = lib.mkDefault "luckfox-mini-a";
        device.kernel            = lib.mkDefault "${luckfoxKernel}/zImage";
        device.dtb               = lib.mkDefault "${luckfoxKernel}/dtbs/${miniADtb}";
        device.kernelModulesPath = lib.mkDefault "${luckfoxKernel}/lib/modules";
      })

      # ── Pico Mini B (8 MiB SPI NOR flash) ────────────────────────────────
      (lib.mkIf (m == "pico-mini-b") {
        device.name = lib.mkDefault "pico-mini-b";
        networking.hostname      = lib.mkDefault "luckfox";
        device.kernel            = lib.mkDefault "${luckfoxKernel}/zImage";
        device.dtb               = lib.mkDefault "${luckfoxKernel}/dtbs/${miniBDtb}";
        device.kernelModulesPath = lib.mkDefault "${luckfoxKernel}/lib/modules";
      })

    ]
  );
}
