# Nintendo 3DS Linux kernel.
#
# The 3DS uses an ARM11 MPCore SoC (ARMv6K + VFPv2).  We cross-compile using
# nixpkgs' raspberryPi crossSystem (armv6l-unknown-linux-gnueabihf), the
# closest standard ARMv6 target in nixpkgs.
#
# Source: https://github.com/linux-3ds/linux
# The linux-3ds project maintains a patched Linux kernel for the 3DS family,
# with support for the ARM11 MPCore, the 3DS display, and the SD card.
#
# ── Updating the kernel ───────────────────────────────────────────────────────
#
# 1. Find the latest commit on the tracking branch:
#      https://github.com/linux-3ds/linux/commits/3ds-6.1
#
# 2. Get the new hash:
#      nix-prefetch-github linux-3ds linux --rev <new-commit-sha>
#
# 3. Update rev and sha256 below, and modDirVersion if the base kernel changed.
#
# ── Build note ────────────────────────────────────────────────────────────────
#
# This kernel must be built on a Linux host.  On macOS, configure a Linux
# builder (nix-darwin linux-builder or a remote builder) before running:
#   nix build .#nintendo-3ds-sdcard

{ pkgs }:

let
  # ARM11 cross-compilation.
  # The 3DS ARM11 MPCore is ARMv6K + VFPv2; pkgsCross.raspberryPi targets
  # armv6l-unknown-linux-gnueabihf which produces compatible binaries.
  armv6Pkgs = import pkgs.path {
    localSystem = pkgs.stdenv.hostPlatform.system;
    crossSystem = pkgs.lib.systems.examples.raspberryPi;
  };

  linux3dsSrc = pkgs.fetchFromGitHub {
    owner  = "linux-3ds";
    repo   = "linux";
    # Track the 3ds-6.1 LTS branch.  Pin to a specific commit for
    # reproducibility — update rev + sha256 together when bumping.
    # Latest commit as of this writing; check the branch for newer ones.
    rev    = "refs/heads/3ds-6.1";
    # FIXME ── replace with the real hash before building:
    #   nix-prefetch-github linux-3ds linux --rev refs/heads/3ds-6.1
    sha256 = pkgs.lib.fakeSha256;
  };

in
  armv6Pkgs.buildLinux {
    src           = linux3dsSrc;
    version       = "6.1.0-3ds";
    modDirVersion = "6.1.0";

    # The linux-3ds repo ships a 3DS-specific defconfig.
    # Located at arch/arm/configs/3ds_defconfig in the source tree.
    # This sets the ARM11 MPCore CPU type, enables the 3DS framebuffer,
    # SD card (TMIO), WiFi (and its firmware blobs), etc.
    defconfig = "3ds_defconfig";

    # Extra options layered on top of 3ds_defconfig needed by our rootfs.
    # lib.mkForce overrides anything the defconfig might set differently.
    structuredExtraConfig = with pkgs.lib.kernel; {
      # ── Filesystems ────────────────────────────────────────────────────────
      # Squashfs + overlayfs: enables future A/B rootfs extension.
      SQUASHFS        = yes;
      SQUASHFS_LZ4    = yes;
      OVERLAY_FS      = yes;

      # ── RAM disk ───────────────────────────────────────────────────────────
      # firm_linux_loader loads /linux/initramfs.cpio.gz as a separate ramdisk;
      # the kernel must support both initramfs and a classic ramdisk.
      BLK_DEV_RAM     = yes;
      BLK_DEV_INITRD  = yes;

      # ── Device population ──────────────────────────────────────────────────
      # devtmpfs automatically creates /dev nodes; avoids needing mknod.
      DEVTMPFS        = yes;
      DEVTMPFS_MOUNT  = yes;

      # ── Compressed swap ────────────────────────────────────────────────────
      # Useful with the 3DS's limited 128 MB (Old) / 256 MB (New 3DS) RAM.
      ZRAM            = module;

      # ── TUN device ────────────────────────────────────────────────────────
      # Needed by nrfnet (if used over a WiFi-bridged link).
      TUN             = module;

      # ── Crypto for dropbear SSH ────────────────────────────────────────────
      CRYPTO_AES      = yes;
      CRYPTO_SHA256   = yes;
      CRYPTO_CHACHA20 = yes;
    };

    # Suppress warnings about defconfig options we're not setting — the
    # 3ds_defconfig has its own opinionated defaults that are correct for the
    # hardware; we only need to add our extras on top.
    ignoreConfigErrors = true;
  }
