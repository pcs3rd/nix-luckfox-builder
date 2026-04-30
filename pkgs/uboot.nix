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
  LUCKFOX_REV    = "824b817f889c2cbff1d48fcdb18ab494a68f69d1";
  LUCKFOX_SHA256 = "sha256-t0kiuP76j/D9i8l+o6JsYrDwUJjD/3cE3WBC+5TN2Lk=";

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
  #
  # Use '/bin/cc' not '/bin/gcc': every Nixpkgs wrapper exposes 'cc', but
  # clang wrappers have no 'gcc' and cross-GCC wrappers only expose the
  # prefixed binary (armv7l-...-gcc), not bare 'gcc'.
  crossCompile = "${pkgs.stdenv.cc}/bin/${pkgs.stdenv.cc.targetPrefix}";
  hostCC       = "${pkgs.buildPackages.stdenv.cc}/bin/cc";

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
    # The Luckfox-specific defconfig may live in the SDK overlay directory or
    # already be present in u-boot/configs/ depending on the SDK revision.
    #
    # SDK revisions where it lives in the overlay:
    #   sysdrv/tools/board/uboot/luckfox_rv1106_uboot_defconfig
    #   (relative from sourceRoot: ../../../tools/board/uboot/...)
    #
    # Newer revisions ship it directly in u-boot/configs/ — no copy needed.
    echo "=== searching for luckfox_rv1106_uboot_defconfig ==="
    if [ -f ../../../tools/board/uboot/luckfox_rv1106_uboot_defconfig ]; then
      echo "Found in SDK overlay — copying to configs/"
      cp ../../../tools/board/uboot/luckfox_rv1106_uboot_defconfig configs/
    elif [ -f configs/luckfox_rv1106_uboot_defconfig ]; then
      echo "Already in configs/ — no copy needed"
    else
      echo "=== Available defconfigs ==="
      ls configs/ | grep -i 'luckfox\|rv110[36]' || true
      echo "=== SDK overlay board dir (if present) ==="
      ls ../../../tools/board/ 2>/dev/null || true
      echo "ERROR: luckfox_rv1106_uboot_defconfig not found in SDK overlay or u-boot/configs/"
      exit 1
    fi

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
      \( -name "*.img" -o -name "*.bin" -o -name "SPL" -o -name "idbloader.img" \) \
      -not -path "*/arch/*" -not -path "*/board/*" | sort

    # ── idbloader / SPL (SD card / SPI boot format) ───────────────────────────
    #
    # CRITICAL FORMAT DISTINCTION:
    #   idbloader format  = what the Rockchip boot ROM reads from SD card sector 64
    #                       (or from SPI NOR at offset 0x8000).  Written to $out/SPL.
    #   LOADER format     = what `rkdeveloptool db` uploads over USB.
    #                       Different binary layout — NEVER use for SD/SPI boot.
    #
    # loaderimage --pack --uboot produces LOADER format (USB download only).
    # For SD/SPI boot we need idbloader format, built with mkimage -T rksd.
    #
    # The idbloader bundles two blobs end-to-end:
    #   1. DDR init blob (runs from on-chip SRAM, initialises DRAM)
    #   2. SPL binary    (loaded into DRAM by DDR init, chains to U-Boot proper)
    #
    # Strategy 1 — some Rockchip defconfigs emit idbloader.img during make.
    if [ -f idbloader.img ]; then
      echo "Strategy 1: using build-generated idbloader.img"
      cp idbloader.img $out/SPL

    # Strategy 2 — build idbloader from DDR blob + SPL using tools/mkimage -T rksd.
    # tools/mkimage is compiled as a host binary during the main U-Boot build;
    # the -n rv1106 flag selects the correct header for this chip family.
    elif [ -f tools/mkimage ] && [ -f rv1106_ddr.bin ] && [ -f spl/u-boot-spl.bin ]; then
      echo "Strategy 2: building idbloader with mkimage -T rksd (DDR blob + built SPL)"
      ./tools/mkimage -n rv1106 -T rksd \
        -d ./rv1106_ddr.bin:spl/u-boot-spl.bin \
        $out/SPL
      echo "idbloader size: $(du -sh $out/SPL | cut -f1)"

    # Strategy 3 — fall back to the SDK's pre-built idblock.img from project/image/.
    # These are identical to the binaries in the Luckfox Ubuntu demo image and are
    # verified to boot on real RV1103 hardware.
    # sourceRoot is source/sysdrv/source/uboot/u-boot; go up 4 dirs to source/.
    else
      echo "Strategy 3: searching SDK project/image/ for pre-built idblock.img..."
      FOUND=""
      for d in ../../../../project/image/*/; do
        if [ -f "$d/idblock.img" ]; then
          FOUND="$d/idblock.img"
          echo "  Using: $d/idblock.img"
          break
        fi
      done
      if [ -z "$FOUND" ]; then
        echo "ERROR: Cannot produce an idbloader by any strategy:" >&2
        echo "  1. No idbloader.img emitted by U-Boot build" >&2
        echo "  2. tools/mkimage, rv1106_ddr.bin, or spl/u-boot-spl.bin missing" >&2
        echo "     (found: $(ls tools/mkimage rv1106_ddr.bin spl/u-boot-spl.bin 2>&1))" >&2
        echo "  3. No idblock.img under ../../../../project/image/*/" >&2
        echo "" >&2
        echo "Build artifacts present:" >&2
        find . -maxdepth 3 -name "*.bin" -o -name "*.img" 2>/dev/null | head -30 >&2
        exit 1
      fi
      cp "$FOUND" $out/SPL
    fi

    # idblock.img is the conventional SDK name for the idbloader.
    # Provide it as an alias so flash scripts can reference either name.
    ln -s SPL $out/idblock.img

    # ── Main U-Boot binary ────────────────────────────────────────────────────
    if [ -f u-boot.img ]; then
      cp u-boot.img $out/u-boot.img
    else
      cp u-boot.bin $out/u-boot.img
    fi

    # ── USB download loader (LOADER format for `rkdeveloptool db`) ────────────
    #
    # This is LOADER format — the binary rkdeveloptool db uploads over USB to
    # initialise DRAM and present the USB flash interface.  It is NOT written
    # to storage; it only lives in DRAM for the duration of the flash session.
    #
    # Try SDK's pre-built download.bin first (same binary in Ubuntu demo image),
    # then fall back to generating one with loaderimage (which correctly produces
    # LOADER format, despite that being wrong for SD boot).
    FOUND_DL=""
    for d in ../../../../project/image/*/; do
      if [ -f "$d/download.bin" ]; then
        FOUND_DL="$d/download.bin"
        break
      fi
    done

    if [ -n "$FOUND_DL" ]; then
      echo "USB download loader: using pre-built $FOUND_DL"
      cp "$FOUND_DL" $out/download.bin
    else
      echo "USB download loader: generating with loaderimage (LOADER format)..."
      cp ../rkbin/tools/loaderimage ./loaderimage
      chmod 755 ./loaderimage
      interp=$(patchelf --print-interpreter "${pkgs.buildPackages.patchelf}/bin/patchelf")
      patchelf --set-interpreter "$interp" ./loaderimage
      ./loaderimage --pack --uboot spl/u-boot-spl.bin $out/download.bin 0x400000
    fi
  '';

  meta = {
    description = "U-Boot for Luckfox Pico Mini B (RV1103/RV1106)";
    # No platforms restriction — this is a cross-compiled firmware target and
    # can be built from any host that supports the ARM cross-toolchain.
  };
}
