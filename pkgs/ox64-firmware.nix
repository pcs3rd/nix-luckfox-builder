# Pre-built kernel + firmware blobs for the Pine64 Ox64 (BL808).
#
# These are fetched from the OpenBouffalo buildroot release and pinned by
# content hash — the same way nixpkgs handles any other pre-built binary.
# The Nix sandbox validates the hash before allowing the build to proceed,
# so reproducibility is fully maintained.
#
# ── Updating the hashes ──────────────────────────────────────────────────────
#
# 1. Browse https://github.com/openbouffalo/buildroot_bouffalo/releases
#    and find the latest release.
#
# 2. Copy the URL for the defconfig tarball (the file whose name ends in
#    _full_defconfig.tar.gz) and run:
#
#      nix-prefetch-url --unpack \
#        https://github.com/openbouffalo/buildroot_bouffalo/releases/download/\
#    v1.0.1/bl808-linux-pine64_ox64_full_defconfig.tar.gz
#
#    Paste the printed hash into BUILDROOT_SHA256 below.
#
# 3. Update BUILDROOT_REV to the release tag (e.g. "v1.0.1").
#
# ── Alternative: mainline Linux ──────────────────────────────────────────────
#
# BL808 support landed in Linux 6.6 (CONFIG_ARCH_BOUFFALOLAB=y).
# A Nix derivation that cross-compiles the kernel from source would look like:
#
#   pkgsRv64.linux.override {
#     defconfig = "ox64_defconfig";   # or a custom config file
#   }
#
# That gives you a fully source-built, reproducible kernel but requires
# the BL808 device tree to be upstream (it is, since 6.6) and adds
# significant build time.  The pre-built blob approach below is simpler
# for getting started.
#
# ── What's in the release tarball ────────────────────────────────────────────
#
# The buildroot release tarball contains (inside output/images/):
#   Image                   — compressed RV64 Linux kernel
#   bl808-pine64-ox64.dtb   — compiled device tree blob
#   low_load_bl808_d0.bin   — D0 (Linux) pre-loader
#   low_load_bl808_m0.bin   — M0 (RTOS/WiFi) pre-loader
#   rootfs.ext2             — buildroot rootfs (not used; we build our own)
#
# This derivation extracts just the kernel, DTB, and the two pre-loader blobs.

{ pkgs }:

let
  lib = pkgs.lib;

  BUILDROOT_REV    = "v1.0.1";
  BUILDROOT_SHA256 = "sha256-/jlQc2OF/4Hpn3KnClHhmvvtZ18AvgWsupr7yihLpwY=";
  # ↑ SRI hash — update with:
  #   nix-prefetch-url --unpack https://github.com/openbouffalo/buildroot_bouffalo/releases/download/v1.0.1/bl808-linux-pine64_ox64_full_defconfig.tar.gz
  #   then convert: nix hash convert --hash-algo sha256 --to sri <base32>

  # The release tarball URL — adjust filename if a newer release changes it.
  src = pkgs.fetchurl {
    url    = "https://github.com/openbouffalo/buildroot_bouffalo/releases/download/${BUILDROOT_REV}/bl808-linux-pine64_ox64_full_defconfig.tar.gz";
    sha256 = BUILDROOT_SHA256;
  };

in

pkgs.runCommand "ox64-firmware-${BUILDROOT_REV}" {
  nativeBuildInputs = [ pkgs.buildPackages.gnutar pkgs.buildPackages.gzip ];
} ''
  # Unpack the release tarball
  mkdir -p src
  tar -xzf ${src} -C src

  # Images land in output/images/ relative to the tarball root.
  IMAGES=$(find src -type d -name images | head -1)
  if [ -z "$IMAGES" ]; then
    echo "ERROR: could not find images/ directory in tarball" >&2
    echo "Contents:" >&2; find src -maxdepth 4 >&2
    exit 1
  fi

  mkdir -p $out
  cp "$IMAGES/Image"                 $out/Image
  cp "$IMAGES/bl808-pine64-ox64.dtb" $out/bl808-pine64-ox64.dtb
  cp "$IMAGES/low_load_bl808_d0.bin" $out/low_load_bl808_d0.bin
  cp "$IMAGES/low_load_bl808_m0.bin" $out/low_load_bl808_m0.bin

  echo "ox64-firmware ${BUILDROOT_REV} unpacked:"
  ls -lh $out/
''
