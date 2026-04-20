# U-Boot derivation for the Luckfox Pico Mini B (Rockchip RV1103 / Cortex-A7)
#
# Note: the chip is marketed as RV1103 but Rockchip's own SDK sets RK_CHIP=rv1106
# throughout — they are the same silicon. Defconfigs and DDR blobs are all rv1106.
#
# The DDR blob lives inside the luckfox-pico repo itself at:
#   sysdrv/source/uboot/rkbin/bin/rv11/rv1106_ddr_924MHz_v1.15.bin
#
# So no separate fetchurl is needed — it's copied from the already-fetched source.
#
# ── Before this builds you need to fill in the source hash ──────────────────
#
#   Run:  nix-prefetch-github LuckfoxTECH luckfox-pico
#   Then replace LUCKFOX_REV and LUCKFOX_SHA256 below.
#
# ────────────────────────────────────────────────────────────────────────────

{ pkgs }:

let
  LUCKFOX_REV    = "438d5270a38c59a74f142dfa31ffbf51b096ce72";
  LUCKFOX_SHA256 = "sha256-iPmQLKzgznBp3CJMvbbGrtLgd9P0jHgBrynqGnsAygI=";

  # ── Compiler paths ─────────────────────────────────────────────────────────
  #
  # In a Nix cross-compilation stdenv, the cross-compiler is not available as
  # "arm-linux-gnueabihf-gcc" on PATH.  Instead it lives at a store path with
  # the Nix target-triplet prefix (armv7l-unknown-linux-musleabihf-).
  # Pin both CROSS_COMPILE and HOSTCC to exact store paths so U-Boot's
  # Makefiles can always find them regardless of PATH.
  #
  # pkgs.stdenv.cc           — cross-compiler wrapper (target = armv7l musl)
  # pkgs.stdenv.cc.targetPrefix — "armv7l-unknown-linux-musleabihf-"
  # pkgs.buildPackages.stdenv.cc — native compiler wrapper (build machine)
  crossCompile = "${pkgs.stdenv.cc}/bin/${pkgs.stdenv.cc.targetPrefix}";
  hostCC       = "${pkgs.buildPackages.stdenv.cc}/bin/gcc";

in

pkgs.stdenv.mkDerivation {
  pname   = "u-boot-luckfox-pico-mini-b";
  version = "2024.01-luckfox";

  src = pkgs.fetchFromGitHub {
    owner  = "LuckfoxTECH";
    repo   = "luckfox-pico";
    rev    = LUCKFOX_REV;
    sha256 = LUCKFOX_SHA256;
  };

  # U-Boot lives inside the larger SDK repo at this path
  sourceRoot = "source/sysdrv/source/uboot/u-boot";

  nativeBuildInputs = with pkgs.buildPackages; [
    gnumake
    bison
    flex
    openssl
    python3
    swig
    pkg-config
  ];

  configurePhase = ''
    # The Luckfox-specific defconfig lives in the SDK overlay directory, not in
    # u-boot/configs/.  The SDK Makefile copies it there before building; we
    # do the same.
    # Path: sourceRoot = sysdrv/source/uboot/u-boot
    #       defconfig  = sysdrv/tools/board/uboot/luckfox_rv1106_uboot_defconfig
    #       relative   = ../../../tools/board/uboot/luckfox_rv1106_uboot_defconfig
    cp ../../../tools/board/uboot/luckfox_rv1106_uboot_defconfig configs/

    make \
      ARCH=arm \
      CROSS_COMPILE=${crossCompile} \
      HOSTCC=${hostCC} \
      luckfox_rv1106_uboot_defconfig

    # ── Trim SPL size for modern GCC ─────────────────────────────────────────
    # The SDK was built with Linaro GCC 6.3.1 which generates smaller code.
    # Modern GCC exceeds the 0x28000 (160 KB) SPL_MAX_SIZE limit.  Disable
    # SPL features that are only needed for SPI-NOR/NAND boot paths — the
    # Luckfox Pico Mini B uses SD card exclusively.
    disable_config() {
      sed -i "s/^$1=y/# $1 is not set/" .config
    }
    # SPI bus and flash drivers are not needed for SD-card-only boot.
    # SPL_MTD_SUPPORT must stay — spl_fit.c calls mtd_blk_map_fit().
    disable_config CONFIG_SPL_SPI_SUPPORT
    disable_config CONFIG_SPL_SPI_FLASH_SUPPORT
    # A/B partition switching adds code not needed for simple SD boot.
    disable_config CONFIG_SPL_AB

    # Recalculate Kconfig dependencies after the above changes.
    make \
      ARCH=arm \
      CROSS_COMPILE=${crossCompile} \
      HOSTCC=${hostCC} \
      olddefconfig

    # The DDR init blob is in the same repo under sysdrv/source/uboot/rkbin/.
    # From sourceRoot (sysdrv/source/uboot/u-boot) it's one level up at ../rkbin/.
    cp ../rkbin/bin/rv11/rv1106_ddr_924MHz_v1.15.bin ./rv1106_ddr.bin
  '';

  buildPhase = ''
    make -j$NIX_BUILD_CORES \
      ARCH=arm \
      CROSS_COMPILE=${crossCompile} \
      HOSTCC=${hostCC} \
      KCFLAGS="-Os -Wno-error=enum-int-mismatch -Wno-error=maybe-uninitialized -Wno-error=address"
  '';

  installPhase = ''
    mkdir -p $out
    cp SPL        $out/SPL
    cp u-boot.bin $out/u-boot.bin
  '';

  meta = {
    description = "U-Boot for Luckfox Pico Mini B (RV1103/RV1106)";
    # No platforms restriction — this is a cross-compiled firmware target and
    # can be built from any host that supports the ARM cross-toolchain.
  };
}
