# Luckfox Pico Mini B — vendor kernel built from source
#
# Builds zImage, DTBs, and kernel modules from the LuckfoxTECH SDK source.
# This replaces the manual "drop zImage + dtb into hardware/kernel/" workflow.
#
# ── Output ────────────────────────────────────────────────────────────────────
#
#   $out/zImage              — compressed ARM kernel image
#   $out/dtbs/               — all board-relevant device tree blobs
#   $out/lib/modules/<ver>/  — kernel modules (for `modprobe`)
#
# ── Usage in hardware/pico-mini-b.nix ────────────────────────────────────────
#
#   { pkgs, ... }:
#   let kernel = import ../pkgs/luckfox-kernel.nix { inherit pkgs; };
#   in {
#     device.kernel = "${kernel}/zImage";
#     device.dtb    = "${kernel}/dtbs/rv1103-luckfox-pico-mini-b.dtb";
#     device.kernelModulesPath = "${kernel}/lib/modules";
#   }
#
# ── Finding the right DTB name ───────────────────────────────────────────────
#
# Run `nix build .#luckfox-kernel` and inspect `result/dtbs/` to see which
# DTBs the SDK generates for this board.  Then set device.dtb accordingly.
# Common names:
#   rv1103-luckfox-pico-mini-b.dtb
#   rv1106-luckfox-pico-mini-b.dtb
#   luckfox-pico-mini-b.dtb
#
# ── Source hash ──────────────────────────────────────────────────────────────
#
# Must match the revision used in pkgs/uboot.nix so only one fetch is needed.
# Update with:  nix-prefetch-github LuckfoxTECH luckfox-pico
#
# ────────────────────────────────────────────────────────────────────────────

{ pkgs }:

let
  LUCKFOX_REV    = "438d5270a38c59a74f142dfa31ffbf51b096ce72";
  LUCKFOX_SHA256 = "sha256-iPmQLKzgznBp3CJMvbbGrtLgd9P0jHgBrynqGnsAygI=";

  KERNEL_DEFCONFIG = "luckfox_pico_mini_b_defconfig";

  # In a Nix cross stdenv, pkgs.stdenv.cc is the cross-compiler wrapper
  # (target = armv7l musl).  pkgs.buildPackages.stdenv.cc is the native
  # (build-host) compiler used for host-side build tools.
  crossCompile = "${pkgs.stdenv.cc}/bin/${pkgs.stdenv.cc.targetPrefix}";
  hostCC       = "${pkgs.buildPackages.stdenv.cc}/bin/gcc";

in

pkgs.stdenv.mkDerivation {
  pname   = "luckfox-kernel";
  version = "5.10-luckfox";

  src = pkgs.fetchFromGitHub {
    owner  = "LuckfoxTECH";
    repo   = "luckfox-pico";
    rev    = LUCKFOX_REV;
    sha256 = LUCKFOX_SHA256;
  };

  # Kernel source lives here inside the larger SDK repo.
  sourceRoot = "source/sysdrv/source/kernel";

  nativeBuildInputs = with pkgs.buildPackages; [
    gnumake
    bison
    flex
    openssl
    bc
    perl
    python3
    pkg-config
    # dtc is required for `make dtbs`
    dtc
  ];

  enableParallelBuilding = true;

  configurePhase = ''
    # ── Patch SDK build scripts for Nix cross-compiler compatibility ──────────
    #
    # The Luckfox/Rockchip SDK kernel ships a custom scripts/gcc-version.sh
    # that delegates to scripts/gcc-wrapper.py — a Python shim designed for the
    # SDK's bundled cross-toolchain (arm-rockchip820-linux-uclibcgnueabihf-gcc).
    # When building with Nix's cross-compiler the wrapper can't locate the SDK
    # GCC, returns empty strings, and causes Kconfig to abort with
    # "init/Kconfig: syntax error".
    #
    # Fix: replace gcc-version.sh with the standard Linux kernel version that
    # queries the compiler directly via preprocessor macro expansion, and supply
    # ld-version.sh if it is missing from the SDK tree.

    cat > scripts/gcc-version.sh << 'GCCEOF'
#!/bin/sh
# Standard gcc-version.sh — compatible with any GCC cross-compiler.
if [ -z "$*" ]; then echo "Usage: gcc-version.sh <compiler>" >&2; exit 1; fi
compiler="$*"
MAJOR=$(echo __GNUC__            | $compiler -E -x c - | tail -1)
MINOR=$(echo __GNUC_MINOR__      | $compiler -E -x c - | tail -1)
PATCH=$(echo __GNUC_PATCHLEVEL__ | $compiler -E -x c - | tail -1)
printf "%02d%02d%02d\n" "$MAJOR" "$MINOR" "$PATCH"
GCCEOF
    chmod +x scripts/gcc-version.sh

    # ld-version.sh may be absent in older Rockchip SDK kernel trees.
    if [ ! -x scripts/ld-version.sh ]; then
      cat > scripts/ld-version.sh << 'LDEOF'
#!/bin/sh
# Standard ld-version.sh — compatible with binutils ld.
if [ -z "$*" ]; then echo "Usage: ld-version.sh <ld>" >&2; exit 1; fi
LD="$*"
LD_V=$($LD --version | head -1 | sed 's/.*\b\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/')
MAJOR=$(echo "$LD_V" | cut -d. -f1)
MINOR=$(echo "$LD_V" | cut -d. -f2)
printf "%02d%02d\n" "$MAJOR" "$MINOR"
LDEOF
      chmod +x scripts/ld-version.sh
    fi

    echo "=== available ARM defconfigs ==="
    ls arch/arm/configs/ | grep -iE 'luckfox|rv110[36]' || true

    make \
      ARCH=arm \
      CROSS_COMPILE=${crossCompile} \
      HOSTCC=${hostCC} \
      ${KERNEL_DEFCONFIG}
  '';

  buildPhase = ''
    make -j$NIX_BUILD_CORES \
      ARCH=arm \
      CROSS_COMPILE=${crossCompile} \
      HOSTCC=${hostCC} \
      zImage dtbs modules
  '';

  installPhase = ''
    mkdir -p $out/dtbs

    # ── Kernel image ──────────────────────────────────────────────────────────
    cp arch/arm/boot/zImage $out/zImage
    echo "zImage: $(du -sh $out/zImage | cut -f1)"

    # ── Device tree blobs ─────────────────────────────────────────────────────
    # Collect board-relevant DTBs; fall back to copying everything if the
    # pattern matches nothing (e.g. if the board DTS is named differently).
    FOUND=0
    find arch/arm/boot/dts -maxdepth 1 -name "*.dtb" | while read dtb; do
      name=$(basename "$dtb")
      case "$name" in
        *luckfox*|*rv1103*|*rv1106*)
          cp "$dtb" $out/dtbs/"$name"
          FOUND=1
          ;;
      esac
    done

    if [ -z "$(ls $out/dtbs/ 2>/dev/null)" ]; then
      echo "WARNING: no Luckfox/RV1103/RV1106 DTBs matched — copying all DTBs"
      find arch/arm/boot/dts -maxdepth 1 -name "*.dtb" \
        -exec cp {} $out/dtbs/ \;
    fi

    echo "=== DTBs installed ==="
    ls $out/dtbs/

    # ── Kernel modules ────────────────────────────────────────────────────────
    make \
      ARCH=arm \
      CROSS_COMPILE=${crossCompile} \
      HOSTCC=${hostCC} \
      INSTALL_MOD_PATH="$out" \
      modules_install

    # Remove build/source symlinks — they reference absolute Nix store paths
    # that do not exist on the target device.
    find "$out/lib/modules" -maxdepth 2 \
      \( -name build -o -name source \) -type l -delete || true

    echo "=== kernel module version ==="
    ls "$out/lib/modules/"
  '';

  meta = {
    description = "Linux 5.10 kernel (zImage + DTBs + modules) for Luckfox Pico Mini B (RV1103/RV1106)";
  };
}
