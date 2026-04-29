# U-Boot for the Luckfox Nova (Rockchip RK3308B, Cortex-A35 / AArch64).
#
# RK3308 uses mainline U-Boot with in-tree TPL for DDR init (no external DDR
# blob required, unlike RV1103/RV1106).  Arm Trusted Firmware (BL31) IS needed
# to set up EL3 before handing off to U-Boot proper.
#
# Boot image layout on SD / eMMC (identical to other Rockchip chips):
#   Sector 64    (byte 0x8000)  : idbloader.img  (SPL + TPL / DDR init)
#   Sector 16384 (byte 0x2000000) : u-boot.itb    (FIT: U-Boot proper + BL31)
#
# These map to the existing boot.uboot.spl / boot.uboot.package options:
#   boot.uboot.spl     = "${nova-uboot}/idbloader.img"
#   boot.uboot.package = "${nova-uboot}/u-boot.itb"
#
# The sdimage builder copies spl → raw disk offset 0x8000 and package →
# raw offset 0x2000000, matching what U-Boot's own `make flash` would do.
#
# ── Hash placeholders ─────────────────────────────────────────────────────────
#
# Fill in sha256 values with:
#   nix-prefetch-url https://ftp.denx.de/pub/u-boot/u-boot-2024.07.tar.bz2
#   nix-prefetch-url https://github.com/rockchip-linux/rkbin/raw/master/bin/rk33/rk3308_bl31_v2.28.elf
#
# ── Defconfig note ────────────────────────────────────────────────────────────
#
# Mainline U-Boot 2024.07 ships evb-rk3308_defconfig for the generic RK3308 EVB.
# If Luckfox Nova has been upstreamed by the time you read this, switch to the
# board-specific defconfig (check `ls configs/ | grep -i luckfox` after extracting
# the tarball).
#
# ─────────────────────────────────────────────────────────────────────────────

{ pkgs }:

let
  lib = pkgs.lib;

  UBOOT_VERSION = "2024.07";

  crossCompile = "${pkgs.stdenv.cc}/bin/${pkgs.stdenv.cc.targetPrefix}";
  hostCC       = "${pkgs.buildPackages.stdenv.cc}/bin/cc";

  # Arm Trusted Firmware BL31 for RK3308 from the Rockchip rkbin repository.
  # This is required for EL3 initialisation; U-Boot embeds it into u-boot.itb.
  bl31 = pkgs.fetchurl {
    url    = "https://github.com/rockchip-linux/rkbin/raw/master/bin/rk33/rk3308_bl31_v2.28.elf";
    sha256 = lib.fakeHash;  # run: nix-prefetch-url <url>
  };

in pkgs.stdenv.mkDerivation {
  pname   = "u-boot-luckfox-nova";
  version = UBOOT_VERSION;

  src = pkgs.fetchurl {
    url    = "https://ftp.denx.de/pub/u-boot/u-boot-${UBOOT_VERSION}.tar.bz2";
    sha256 = lib.fakeHash;  # run: nix-prefetch-url <url>
  };

  nativeBuildInputs = with pkgs.buildPackages; [
    gnumake
    bison
    flex
    openssl
    python3
    swig
    bc
    pkg-config
    dtc
  ];

  configurePhase = ''
    echo "=== checking for board-specific defconfig ==="
    if ls configs/ | grep -qi 'luckfox.*nova\|nova.*rk3308'; then
      DEFCONFIG=$(ls configs/ | grep -i 'luckfox.*nova\|nova.*rk3308' | head -1)
      echo "Found Luckfox Nova defconfig: $DEFCONFIG"
    else
      DEFCONFIG="evb-rk3308_defconfig"
      echo "No Luckfox Nova defconfig found — using generic EVB: $DEFCONFIG"
    fi

    make \
      ARCH=arm64 \
      CROSS_COMPILE=${crossCompile} \
      HOSTCC=${hostCC} \
      "$DEFCONFIG"
  '';

  buildPhase = ''
    make -j$NIX_BUILD_CORES \
      ARCH=arm64 \
      CROSS_COMPILE=${crossCompile} \
      HOSTCC=${hostCC} \
      BL31=${bl31} \
      all
  '';

  installPhase = ''
    echo "=== U-Boot build artifacts ==="
    find . -maxdepth 2 \
      \( -name "idbloader.img" -o -name "u-boot.itb" -o -name "u-boot.img" \) \
      | sort

    mkdir -p $out

    # idbloader.img: SPL + DDR TPL combined by mkimage into Rockchip format.
    # Written to the raw disk at sector 64 (byte offset 0x8000).
    if [ -f idbloader.img ]; then
      cp idbloader.img $out/idbloader.img
    else
      echo "ERROR: idbloader.img not found; check U-Boot build output above." >&2
      exit 1
    fi

    # u-boot.itb: FIT image containing U-Boot proper + BL31 (+ optional OP-TEE).
    # Written to the raw disk at sector 16384 (byte offset 0x2000000).
    if [ -f u-boot.itb ]; then
      cp u-boot.itb $out/u-boot.itb
    elif [ -f u-boot.img ]; then
      # Some older U-Boot versions produce u-boot.img instead
      cp u-boot.img $out/u-boot.itb
    else
      echo "ERROR: u-boot.itb (or u-boot.img) not found." >&2
      exit 1
    fi
  '';

  meta = {
    description = "U-Boot for Luckfox Nova (RK3308B / AArch64)";
  };
}
