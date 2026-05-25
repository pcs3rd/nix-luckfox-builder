# Nintendo 3DS Linux kernel.
#
# The 3DS uses an ARM11 MPCore SoC (ARMv6K + VFPv2).  We cross-compile using
# nixpkgs' raspberryPi crossSystem (armv6l-unknown-linux-gnueabihf), the
# closest standard ARMv6 target in nixpkgs.
#
# Source: https://github.com/linux-3ds/linux
# The linux-3ds project maintains a patched Linux kernel for the 3DS family,
# based on Linux 5.11.0-rc1, with support for the ARM11 MPCore, the 3DS
# framebuffer display, TMIO SD card controller, and BCM WiFi.
#
# ── Updating the kernel ───────────────────────────────────────────────────────
#
# 1. Find the latest commit on master:
#      https://github.com/linux-3ds/linux/commits/master
#
# 2. Get the new hash:
#      nix-prefetch-github linux-3ds linux --rev <new-commit-sha>
#
# 3. Update rev and sha256 below.  modDirVersion should stay "5.11.0-rc1"
#    until the linux-3ds project rebases onto a newer kernel version.
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
    # The linux-3ds/linux repository has only one branch: master.
    # Pin to a specific commit for reproducibility — update rev + sha256
    # together when bumping (see "Updating the kernel" above).
    # FIXME ── replace with a pinned commit SHA for reproducibility:
    #   nix-prefetch-github linux-3ds linux --rev master
    rev    = "7071ec29fd3ebd55d00a70cb6482e98d4702c5f2";
    sha256 = "sha256-mNbs3uxt19MUg6kmnI/KLwFzFvfF5e9PQHp3rX16zmI=";
  };

in
  armv6Pkgs.buildLinux {
    src           = linux3dsSrc;
    # Must match the kernel Makefile on master:
    #   VERSION = 5, PATCHLEVEL = 11, SUBLEVEL = 0, EXTRAVERSION = -rc1
    version       = "5.11.0-rc1-3ds";
    modDirVersion = "5.11.0-rc1";

    # The linux-3ds master branch ships a 3DS-specific defconfig at
    # arch/arm/configs/3ds_defconfig in the source tree.
    # It sets the ARM11 MPCore CPU type, enables the 3DS framebuffer,
    # SD card (TMIO), WiFi (BCM43362/BCM4334), etc.
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
