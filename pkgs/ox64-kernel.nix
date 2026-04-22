# Linux kernel for the Pine64 Ox64 (Bouffalo Lab BL808 / RV64GCV C906).
#
# Cross-compiled from the OpenBouffalo Linux fork, which carries BL808-specific
# patches on top of mainline Linux.  The C906 core (D0) runs the kernel;
# the M0 and LP cores run their own firmware (handled separately by the
# pre-loader blobs in the FAT boot partition).
#
# ── First-time setup ──────────────────────────────────────────────────────────
#
# 1. Find the commit you want to pin from:
#      https://github.com/openbouffalo/linux/commits
#    Use the default branch (typically "bl808/all" or "main").
#
# 2. Get the Nix hash:
#      nix-prefetch-url --unpack \
#        https://github.com/openbouffalo/linux/archive/44c026a73be8038f03dbdeef028b642880cf1511.tar.gz
#
# 3. Paste commit and hash into KERNEL_REV / KERNEL_HASH below.
#
# 4. Check the exact kernel version:
#      head -5 <linux-source>/Makefile
#    Update KERNEL_VERSION to match.
#
# 5. Verify the DTB path — it should be at:
#      arch/riscv/boot/dts/thead/bl808-pine64-ox64.dts
#    or similar.  Update DTB_PATH_IN_BUILD if it differs.
#
# ── Building ──────────────────────────────────────────────────────────────────
#
#   nix build .#ox64-kernel
#
# Output:
#   result/Image                           — uncompressed RISC-V kernel image
#   result/bl808-pine64-ox64.dtb           — device tree for the Ox64
#   result/lib/modules/<ver>/              — loadable kernel modules
#
# Pass { pkgs } = riscv64KernelPkgs from flake.nix (riscv64-linux-gnu cross set).

{ pkgs }:

let
  # ── Pin these ─────────────────────────────────────────────────────────────
  KERNEL_REV  = "44c026a73be8038f03dbdeef028b642880cf1511";  # git commit hash from openbouffalo/linux
  KERNEL_HASH = "02bm1vk60jdqxn7hhid472p6kdsv9z5yxqb1fgpw8dz2sdr6mgl3";  # sha256 from nix-prefetch-url --unpack

  # ── Update these if the upstream kernel version changes ───────────────
  KERNEL_VERSION      = "6.1.0";  # match Makefile in the kernel source
  DEFCONFIG           = "bl808_defconfig";
  # DTB built at this path inside the kernel source tree:
  DTB_PATH_IN_BUILD   = "arch/riscv/boot/dts/thead/bl808-pine64-ox64.dtb";
  DTB_NAME            = "bl808-pine64-ox64.dtb";

in

if KERNEL_REV == "" || KERNEL_HASH == ""
then builtins.trace
  "ox64-kernel: KERNEL_REV/KERNEL_HASH not set in pkgs/ox64-kernel.nix — kernel build skipped"
  null
else

let
  src = pkgs.fetchFromGitHub {
    owner = "openbouffalo";
    repo  = "linux";
    rev   = KERNEL_REV;
    hash  = KERNEL_HASH;
  };

in pkgs.stdenv.mkDerivation {
  pname   = "ox64-kernel";
  version = KERNEL_VERSION;

  inherit src;

  # Build-machine tools required by Kconfig and the kernel build system.
  nativeBuildInputs = with pkgs.buildPackages; [
    flex bison bc perl python3 openssl kmod
  ];

  postPatch = ''
    echo "" > .scmversion
  '';

  buildPhase = ''
    # 1. Generate .config from the BL808 defconfig
    make ARCH=riscv \
         CROSS_COMPILE=${pkgs.stdenv.cc.targetPrefix} \
         ${DEFCONFIG}

    # 2. Build kernel image, modules, and device trees
    make ARCH=riscv \
         CROSS_COMPILE=${pkgs.stdenv.cc.targetPrefix} \
         -j$NIX_BUILD_CORES \
         Image modules dtbs
  '';

  installPhase = ''
    mkdir -p $out

    # ── Kernel image (uncompressed — OpenBouffalo pre-loader expects Image) ──
    cp arch/riscv/boot/Image $out/

    # ── Device tree blob ────────────────────────────────────────────────────
    if [ -f "${DTB_PATH_IN_BUILD}" ]; then
      cp "${DTB_PATH_IN_BUILD}" $out/
    else
      echo ""
      echo "ERROR: ${DTB_PATH_IN_BUILD} not found."
      echo "Available RISC-V DTBs (update DTB_PATH_IN_BUILD in pkgs/ox64-kernel.nix):"
      find arch/riscv/boot/dts -name "*.dtb" | sort
      exit 1
    fi

    # ── Kernel modules ───────────────────────────────────────────────────────
    make ARCH=riscv \
         CROSS_COMPILE=${pkgs.stdenv.cc.targetPrefix} \
         INSTALL_MOD_PATH=$out \
         modules_install
    find $out/lib/modules -maxdepth 2 \( -name build -o -name source \) \
      -type l -delete
  '';

  meta.description = "Linux ${KERNEL_VERSION} with BL808 patches for Pine64 Ox64";
}
