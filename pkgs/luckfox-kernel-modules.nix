# Luckfox Pico Mini B — vendor kernel modules
#
# Builds the out-of-tree kernel modules from the LuckfoxTECH SDK source.
# The resulting derivation exposes lib/modules/<version>/ which can be
# wired into the rootfs via:
#
#   device.kernelModulesPath = "${localPkgs.luckfox-kernel-modules}/lib/modules";
#
# This enables modprobe to load modules like zram at runtime.
#
# ── Source hash ─────────────────────────────────────────────────────────────
# Must match the revision used in pkgs/uboot.nix so only one fetch is needed.
#
#   nix-prefetch-github LuckfoxTECH luckfox-pico
#
# ── Kernel defconfig ────────────────────────────────────────────────────────
# The SDK ships several board configs under:
#   sysdrv/source/kernel/arch/arm/configs/
# For the Pico Mini B the config is one of:
#   luckfox_pico_mini_b_defconfig    (if board-specific config exists)
#   rv1106_linux_defconfig           (generic RV1106 Linux config)
# Change KERNEL_DEFCONFIG below if the build fails with "can't find defconfig".
#
# ────────────────────────────────────────────────────────────────────────────

{ pkgs }:

let
  LUCKFOX_REV    = "824b817f889c2cbff1d48fcdb18ab494a68f69d1";
  LUCKFOX_SHA256 = "sha256-t0kiuP76j/D9i8l+o6JsYrDwUJjD/3cE3WBC+5TN2Lk=";

  KERNEL_DEFCONFIG = "luckfox_pico_mini_b_defconfig";

  # The cross-compiler prefix in the Nix cross stdenv.
  crossCompile = "${pkgs.stdenv.cc}/bin/${pkgs.stdenv.cc.targetPrefix}";
  hostCC       = "${pkgs.buildPackages.stdenv.cc}/bin/gcc";

in

pkgs.stdenv.mkDerivation {
  pname   = "luckfox-kernel-modules";
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
  ];

  # The kernel build system does not honour NIX_BUILD_CORES via -j by default.
  enableParallelBuilding = true;

  configurePhase = ''
    echo "=== available ARM defconfigs ==="
    ls arch/arm/configs/ | grep -i 'luckfox\|rv110\|rv106' || true

    make \
      ARCH=arm \
      CROSS_COMPILE=${crossCompile} \
      HOSTCC=${hostCC} \
      ${KERNEL_DEFCONFIG}
  '';

  buildPhase = ''
    # Build only the kernel modules — no need to compile the full vmlinux.
    make -j$NIX_BUILD_CORES \
      ARCH=arm \
      CROSS_COMPILE=${crossCompile} \
      HOSTCC=${hostCC} \
      modules
  '';

  installPhase = ''
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

    echo "=== installed kernel version(s) ==="
    ls "$out/lib/modules/"
  '';

  meta = {
    description = "Kernel modules for the Luckfox Pico Mini B (RV1103/RV1106, Linux 5.10)";
  };
}
