# Linux kernel for the Luckfox Pico Mini B (Rockchip RV1103 / Cortex-A7).
#
# Cross-compiled from the Luckfox SDK kernel source (Linux 5.10.x with
# Rockchip out-of-tree patches for RV1103/RV1106).
#
# ── First-time setup ──────────────────────────────────────────────────────────
#
# 1. Find the commit you want to pin from:
#      https://github.com/LuckfoxTECH/luckfox-pico/commits/main
#
# 2. Get the Nix hash for that commit's tarball:
#      nix-prefetch-url --unpack \
#        https://github.com/LuckfoxTECH/luckfox-pico/archive/824b817f889c2cbff1d48fcdb18ab494a68f69d1.tar.gz
#
# 3. Paste the commit and hash into SDK_REV / SDK_HASH below.
#
# 4. Check the kernel version in the SDK's Makefile:
#      sysdrv/source/kernel/Makefile  (look for VERSION / PATCHLEVEL / SUBLEVEL)
#    Update KERNEL_VERSION to match (used for the module directory name).
#
# 5. Verify the DTB name for your board:
#      ls sysdrv/source/kernel/arch/arm/boot/dts/ | grep pico
#    Update DTB_NAME if it differs.
#
# ── Building ──────────────────────────────────────────────────────────────────
#
#   nix build .#luckfox-kernel
#
# Output:
#   result/zImage                         — kernel image for U-Boot
#   result/<dtb-name>.dtb                 — device tree for Pico Mini B
#   result/lib/modules/<ver>/             — loadable kernel modules
#
# Pass { pkgs } = linuxPkgs from flake.nix (armv7l-hf-multiplatform cross set).

{ pkgs }:

let
  # ── Pin these ─────────────────────────────────────────────────────────────
  SDK_REV  = "824b817f889c2cbff1d48fcdb18ab494a68f69d1";   # git commit hash, e.g. "a1b2c3d4e5f6..."
  SDK_HASH = "1i8swfjrp9047hi0hw6zfy3v8k8c5fsk5ssl07gjpibdk01kzvrk";   # sha256 from nix-prefetch-url --unpack, e.g. "sha256-..."

  # ── Update these if the SDK kernel version changes ─────────────────────
  KERNEL_VERSION = "5.10.110";  # match VERSION.PATCHLEVEL.SUBLEVEL in kernel/Makefile
  DEFCONFIG      = "luckfox_rv1106_linux_defconfig";
  # DTB for the Pico Mini B — verify in arch/arm/boot/dts/
  DTB_NAME       = "rv1103-luckfox-pico-mini-b.dtb";

in

# Return null when hashes aren't filled in so callers can degrade gracefully
# (device.kernel = null → SD image step is skipped without a hard error).
if SDK_REV == "" || SDK_HASH == ""
then builtins.trace
  "luckfox-kernel: SDK_REV/SDK_HASH not set in pkgs/luckfox-kernel.nix — kernel build skipped"
  null
else

let
  sdk = pkgs.fetchFromGitHub {
    owner = "LuckfoxTECH";
    repo  = "luckfox-pico";
    rev   = SDK_REV;
    hash  = SDK_HASH;
    # If the kernel source is a git submodule inside the SDK, set:
    #   fetchSubmodules = true;
    # and re-run nix-prefetch-url to update the hash.
  };

in pkgs.stdenv.mkDerivation {
  pname   = "luckfox-kernel";
  version = KERNEL_VERSION;

  src = "${sdk}/sysdrv/source/kernel";

  # Build-machine tools required by Kconfig scripts and kernel build system.
  nativeBuildInputs = with pkgs.buildPackages; [
    flex bison bc perl python3 openssl kmod
  ];

  # Kernel build scripts query git for a version suffix — short-circuit that.
  postPatch = ''
    echo "" > .scmversion
  '';

  buildPhase = ''
    # 1. Generate .config from the board defconfig
    make ARCH=arm \
         CROSS_COMPILE=${pkgs.stdenv.cc.targetPrefix} \
         ${DEFCONFIG}

    # 2. Build kernel image, modules, and device trees
    make ARCH=arm \
         CROSS_COMPILE=${pkgs.stdenv.cc.targetPrefix} \
         -j$NIX_BUILD_CORES \
         zImage modules dtbs
  '';

  installPhase = ''
    mkdir -p $out

    # ── Kernel image ────────────────────────────────────────────────────────
    cp arch/arm/boot/zImage $out/

    # ── Device tree blob ────────────────────────────────────────────────────
    DTB_PATH=$(find arch/arm/boot/dts -name "${DTB_NAME}" 2>/dev/null | head -1)
    if [ -z "$DTB_PATH" ]; then
      echo ""
      echo "ERROR: ${DTB_NAME} not found in arch/arm/boot/dts/"
      echo "Available DTBs (update DTB_NAME in pkgs/luckfox-kernel.nix):"
      find arch/arm/boot/dts -name "*pico*" -o -name "*rv1103*" | sort
      exit 1
    fi
    cp "$DTB_PATH" $out/

    # ── Kernel modules ───────────────────────────────────────────────────────
    make ARCH=arm \
         CROSS_COMPILE=${pkgs.stdenv.cc.targetPrefix} \
         INSTALL_MOD_PATH=$out \
         modules_install
    # Remove build/source symlinks that point into the temporary build tree.
    find $out/lib/modules -maxdepth 2 \( -name build -o -name source \) \
      -type l -delete
  '';

  meta.description = "Linux ${KERNEL_VERSION} with Rockchip RV1103 patches for Luckfox Pico Mini B";
}
