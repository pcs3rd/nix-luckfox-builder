# U-Boot derivation for the Luckfox Pico Mini B (Rockchip RV1103 / Cortex-A7)
#
# ── Before this builds you must fill in two things ──────────────────────────
#
# 1. luckfox-pico source rev + hash
#    Run:  nix-prefetch-github luckfox-eng33 luckfox-pico
#    Then replace LUCKFOX_REV and LUCKFOX_SHA256 below.
#
# 2. Rockchip DDR blob URL + hash
#    Browse: https://github.com/rockchip-linux/rkbin/tree/master/bin/rv11
#    Find the rv1103_ddr_*MHz_vX.XX.bin that matches what the Luckfox SDK pins
#    (check sysdrv/source/uboot/u-boot/make.sh or the SDK's RKBIN_DESC file).
#    Run:  nix-prefetch-url <raw-url>
#    Then replace RKBIN_URL and RKBIN_SHA256 below.
#
# ────────────────────────────────────────────────────────────────────────────

{ pkgs }:

let
  LUCKFOX_REV    = "438d5270a38c59a74f142dfa31ffbf51b096ce72";
  LUCKFOX_SHA256 = "sha256-7quO4isxA1ljnV6Iu0BI2B1VeguTYaqeBxO3FJLZe8A=";

  RKBIN_URL    = "https://github.com/rockchip-linux/rkbin/raw/FILL_IN_RKBIN_REV/bin/rv11/rv1103_ddr_924MHz_vFILL_IN.bin";
  RKBIN_SHA256 = "sha256-FILL_IN_HASH=";

  # ── Rockchip DDR init blob (closed-source, fetchurl only) ─────────────────
  rkbin-ddr = pkgs.fetchurl {
    url    = RKBIN_URL;
    sha256 = RKBIN_SHA256;
    name   = "rv1103_ddr.bin";
  };

in

pkgs.stdenv.mkDerivation {
  pname   = "u-boot-luckfox-pico-mini-b";
  version = "2024.01-luckfox";

  src = pkgs.fetchFromGitHub {
    owner  = "luckfox-eng";
    repo   = "luckfox-pico";
    rev    = LUCKFOX_REV;
    sha256 = LUCKFOX_SHA256;
  };

  # U-Boot lives inside the larger SDK repo at this path
  sourceRoot = "source/sysdrv/source/uboot/u-boot";

  nativeBuildInputs = with pkgs.buildPackages; [
    gnumake
    gcc
    bison
    flex
    openssl
    python3
    swig
    pkg-config
  ];

  # The RV1103 defconfig lives in configs/luckfox_rv1103_defconfig inside
  # the U-Boot tree. If the SDK uses a different name, adjust here.
  configurePhase = ''
    make \
      ARCH=arm \
      CROSS_COMPILE=arm-linux-gnueabihf- \
      luckfox_rv1103_defconfig

    # Rockchip's SPL Makefile looks for the DDR blob alongside the source
    cp ${rkbin-ddr} ./rv1103_ddr.bin
  '';

  buildPhase = ''
    make -j$NIX_BUILD_CORES \
      ARCH=arm \
      CROSS_COMPILE=arm-linux-gnueabihf-
  '';

  installPhase = ''
    mkdir -p $out
    cp SPL        $out/SPL
    cp u-boot.bin $out/u-boot.bin
  '';

  meta = {
    description = "U-Boot for Luckfox Pico Mini B (RV1103)";
    platforms   = [ "x86_64-linux" "aarch64-linux" ];
  };
}
