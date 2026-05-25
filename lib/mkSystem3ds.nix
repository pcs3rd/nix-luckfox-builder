# Module evaluator for Nintendo 3DS targets.
#
# Analogous to lib/mkSystem.nix but replaces the Rockchip/Luckfox-specific
# modules with the 3DS equivalents:
#
#   luckfox-board.nix  → 3ds-board.nix   (sets kernel, console, disables Rockchip)
#   sdimage.nix        → 3ds-sdcard.nix  (builds SD card filesystem directory)
#
# Intentionally excluded (not relevant to 3DS):
#   uboot.nix     — U-Boot is not used; firm_linux_loader handles kernel loading
#   image.nix     — Rockchip ext4 disk image; not applicable
#   rockchip.nix  — Rockchip SPL/idbloader; not applicable
#   firmware.nix  — Rockchip firmware bundle; not applicable
#   ab-rootfs.nix — A/B squashfs slots via bootloader; not supported by
#                   firm_linux_loader (see modules/core/3ds-board.nix notes)
#
# Usage in flake.nix:
#
#   mkSystem3ds = import ./lib/mkSystem3ds.nix {
#     pkgs     = pkgs3ds;   # cross-compiled for ARMv6 musl
#     lib      = pkgs3ds.lib;
#     buildDate = "...";
#   };
#
#   threeDS = mkSystem3ds { configuration = ./configurations/nintendo-3ds.nix; };
#
#   # Access the SD card output:
#   threeDS.config.system.build.sdcardFilesystem

{ pkgs, lib, buildDate ? "unknown" }:

{ configuration }:

lib.evalModules {
  specialArgs = { inherit pkgs lib buildDate; };

  modules = lib.toList configuration ++ [
    # ── 3DS hardware board (replaces luckfox-board.nix) ─────────────────────
    ../modules/core/3ds-board.nix

    # ── Shared option declarations ────────────────────────────────────────────
    ../modules/core/options.nix

    # ── Shared rootfs builder ─────────────────────────────────────────────────
    # Builds system.build.rootfs (busybox + services + packages) and
    # system.build.initramfs (cpio.gz of the rootfs).
    # Both are cross-compiled for the pkgs target (ARMv6 musl).
    ../modules/core/rootfs.nix

    # ── Service implementations ───────────────────────────────────────────────
    ../modules/core/services.nix
    ../modules/services/default.nix

    # ── Networking ────────────────────────────────────────────────────────────
    ../modules/core/networking.nix
    ../modules/networking/dhcp.nix

    # ── Optional hardware features (disabled by 3ds-board.nix via mkForce) ───
    # These modules are included so their options are declared (options.nix
    # references them), but 3ds-board.nix sets their enable flags to false.
    ../modules/core/mcu.nix
    ../modules/core/usb.nix
    ../modules/core/usb-gadget.nix

    # ── 3DS SD card filesystem builder ───────────────────────────────────────
    # Produces system.build.sdcardFilesystem: a directory containing
    # /luma/payloads/firm_linux_loader.firm and /linux/{zImage,initramfs.cpio.gz,cmdline.txt}.
    ../modules/core/3ds-sdcard.nix
  ];
}
