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
    bc          # scripts/Makefile.spl uses bc to compute SPL pad size
    patchelf    # needed to fix the ELF interpreter on rkbin proprietary tools
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
    # Modern GCC exceeds the 0x28000 (160 KB) SPL_MAX_SIZE limit.
    #
    # Dependency note:
    #   CONFIG_MTD_SPI_NAND → spi_mem_exec_op → CONFIG_SPL_SPI_SUPPORT
    # Disabling CONFIG_SPL_SPI_SUPPORT causes a link failure in the SPL
    # because MTD_SPI_NAND drivers (still compiled in via SPL_MTD_SUPPORT)
    # call spi_mem_exec_op.  Keep the SPI bus layer; only disable the SPI
    # NOR flash driver (not needed for SD-card-only boot).
    disable_config() {
      sed -i "s/^$1=y/# $1 is not set/" .config
    }

    # SPI NOR flash: not needed for SD-card-only boot.
    disable_config CONFIG_SPL_SPI_FLASH_SUPPORT

    # A/B partition switching: not needed for single SD-card boot.
    disable_config CONFIG_SPL_AB

    # LZMA decompressor in the SPL adds ~20 KB; GZIP is sufficient.
    # The Rockchip DDR init FIT image uses GZIP compression.
    disable_config CONFIG_SPL_LZMA

    # Rockchip secure-boot and crypto helpers are not needed for plain SD boot.
    disable_config CONFIG_SPL_DM_CRYPTO
    disable_config CONFIG_SPL_ROCKCHIP_CRYPTO_V2
    disable_config CONFIG_SPL_ROCKCHIP_SECURE_OTP

    # EFI partition scanning is only needed for EFI boot paths.
    disable_config CONFIG_SPL_EFI_PARTITION

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

    # ── Diagnostics ───────────────────────────────────────────────────────────
    echo "=== U-Boot build artifacts ==="
    find . -maxdepth 3 \
      \( -name "*.img" -o -name "*.bin" -o -name "SPL" -o -name "uboot.img" \) \
      -not -path "*/arch/*" -not -path "*/board/*" | sort

    # ── SPL / idbloader ───────────────────────────────────────────────────────
    # mkimage -T rksd rejects spl/u-boot-spl.bin because the rv1126 SRAM limit
    # is 0xf000 (60 KB) but the built SPL is ~166 KB.  The SDK make.sh uses
    # rkbin/tools/loaderimage which handles the two-stage load: the DDR init
    # blob runs from SRAM, then the SPL is loaded into DDR and executed.
    # loaderimage is an x86_64 ELF binary in the fetched source tree.
    if [ -f SPL ]; then
      cp SPL $out/SPL
    else
      # loaderimage is a proprietary x86_64 ELF in the rkbin tree.  It has a
      # hardcoded /lib64/ld-linux-x86-64.so.2 interpreter that doesn't exist
      # in the Nix build sandbox.  Patch it to use the actual Nix store linker.
      # The Nix store is read-only; copy loaderimage to the build dir before patching.
      cp ../rkbin/tools/loaderimage ./loaderimage
      chmod +x ./loaderimage
      # Extract the ELF interpreter from a known-working binary (patchelf itself)
      # using its Nix store path directly — 'which' is not available in the sandbox.
      interp=$(patchelf --print-interpreter "${pkgs.buildPackages.patchelf}/bin/patchelf")
      patchelf --set-interpreter "$interp" ./loaderimage

      echo "=== loaderimage usage ==="
      ./loaderimage --help 2>&1 || true

      echo "=== packing SPL ==="
      # loaderimage creates a Rockchip miniloader image where the DDR init code
      # runs from SRAM then loads the SPL into DDR.  0x400000 is the DDR
      # load/run address for the RV1106 SPL (matches CONFIG_SPL_TEXT_BASE).
      ./loaderimage --pack --uboot spl/u-boot-spl.bin $out/SPL 0x400000
    fi

    # ── Main U-Boot binary ────────────────────────────────────────────────────
    if [ -f u-boot.img ]; then
      cp u-boot.img $out/u-boot.img
    else
      cp u-boot.bin $out/u-boot.bin
    fi
  '';

  meta = {
    description = "U-Boot for Luckfox Pico Mini B (RV1103/RV1106)";
    # No platforms restriction — this is a cross-compiled firmware target and
    # can be built from any host that supports the ARM cross-toolchain.
  };
}
