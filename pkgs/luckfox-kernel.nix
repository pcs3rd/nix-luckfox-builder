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
# ── Usage in hardware/pico-mini-b-kernel.nix ─────────────────────────────────
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

  # ── Replacement build scripts ────────────────────────────────────────────────
  #
  # The Luckfox/Rockchip SDK kernel ships a custom scripts/gcc-version.sh that
  # delegates to scripts/gcc-wrapper.py — a Python shim designed for the SDK's
  # bundled cross-toolchain (arm-rockchip820-linux-uclibcgnueabihf-gcc).
  # When building with Nix's cross-compiler the wrapper cannot locate the SDK
  # GCC, returns empty strings, and causes Kconfig to abort with
  # "init/Kconfig: syntax error".
  #
  # Fix: replace gcc-version.sh with the standard Linux kernel version that
  # queries the compiler directly via preprocessor macro expansion.
  #
  # builtins.toFile creates these as read-only Nix store objects at evaluation
  # time.  postPatch copies them into the (writable) build tree before any
  # make invocation, bypassing the SDK's gcc-wrapper.py entirely.
  #
  # Note: $compiler, $*, $LD, etc. are shell variables in the generated files —
  # they use plain $ (no braces) so Nix does not interpolate them.
  gccVersionSh = builtins.toFile "gcc-version.sh" ''
    #!/bin/sh
    # Standard gcc-version.sh — queries the compiler directly.
    # Called by the kernel Makefile as:  gcc-version.sh $(CC)
    if [ -z "$*" ]; then echo "Usage: gcc-version.sh <compiler>" >&2; exit 1; fi
    compiler="$*"
    MAJOR=$(echo __GNUC__            | $compiler -E -x c - | tail -1)
    MINOR=$(echo __GNUC_MINOR__      | $compiler -E -x c - | tail -1)
    PATCH=$(echo __GNUC_PATCHLEVEL__ | $compiler -E -x c - | tail -1)
    printf "%02d%02d%02d\n" "$MAJOR" "$MINOR" "$PATCH"
  '';

  ldVersionSh = builtins.toFile "ld-version.sh" ''
    #!/bin/sh
    # Standard ld-version.sh — compatible with binutils ld.
    # Called by the kernel Makefile as:  ld-version.sh $(LD)
    if [ -z "$*" ]; then echo "Usage: ld-version.sh <ld>" >&2; exit 1; fi
    LD="$*"
    LD_V=$($LD --version | head -1 | sed 's/.*\b\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/')
    MAJOR=$(echo "$LD_V" | cut -d. -f1)
    MINOR=$(echo "$LD_V" | cut -d. -f2)
    printf "%02d%02d\n" "$MAJOR" "$MINOR"
  '';

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

  # ── Patch phase: replace SDK build scripts before any make invocation ─────
  #
  # postPatch runs after the source is unpacked, in the sourceRoot directory
  # (source/sysdrv/source/kernel).  Copying from the Nix store here is
  # unconditional and cannot be skipped or mis-ordered the way a shell heredoc
  # inside configurePhase can be.
  postPatch = ''
    cp ${gccVersionSh} scripts/gcc-version.sh
    chmod +x scripts/gcc-version.sh

    cp ${ldVersionSh} scripts/ld-version.sh
    chmod +x scripts/ld-version.sh

    echo "patched scripts/gcc-version.sh and scripts/ld-version.sh"
  '';

  configurePhase = ''
    echo "=== available ARM defconfigs ==="
    ls arch/arm/configs/ | grep -iE 'luckfox|rv110[36]' || true

    make \
      ARCH=arm \
      CROSS_COMPILE=${crossCompile} \
      HOSTCC=${hostCC} \
      ${KERNEL_DEFCONFIG}

    # ── Size reduction: disable large unused subsystems ──────────────────────
    #
    # The vendor defconfig targets a full SDK build with camera, audio, display,
    # and Bluetooth.  This build targets meshing/IoT with no display, no camera,
    # no audio, and LoRa/nRF over SPI instead of Bluetooth.
    #
    # Append overrides then re-validate with olddefconfig so Kconfig resolves
    # any inter-option dependencies.  Options absent from this kernel version
    # are silently ignored by olddefconfig.
    #
    # The sed strips leading whitespace so Kconfig sees "CONFIG_FOO=y" with
    # no indentation (required format).
    sed 's/^[[:space:]]*//' >> .config << 'SIZECFG'
    # Camera / ISP / media — hardware ISP present on RV1103 but unused here.
    CONFIG_MEDIA_SUPPORT=n
    CONFIG_VIDEO_DEV=n
    CONFIG_DVB_CORE=n
    CONFIG_RC_CORE=n
    # Audio — no speaker or microphone in this use case.
    CONFIG_SOUND=n
    CONFIG_SND=n
    # Display — no LCD or HDMI attached; DRM/FB unneeded.
    CONFIG_DRM=n
    CONFIG_FB=n
    CONFIG_BACKLIGHT_LCD_SUPPORT=n
    # Bluetooth — LoRa uses SPI; BT subsystem adds significant size.
    CONFIG_BT=n
    # Unused filesystems — only ext4 + squashfs + overlayfs + tmpfs needed.
    CONFIG_BTRFS_FS=n
    CONFIG_XFS_FS=n
    CONFIG_JFS_FS=n
    CONFIG_REISERFS_FS=n
    CONFIG_F2FS_FS=n
    CONFIG_NFS_FS=n
    CONFIG_NFSD=n
    CONFIG_CIFS=n
    # Debug info inflates .ko module files; disable for production images.
    CONFIG_DEBUG_INFO=n
    # Staging drivers — experimental, not needed for production.
    CONFIG_STAGING=n
    # A/B boot: ensure squashfs + overlayfs are built-in (not modules) so
    # the initramfs can mount them without needing insmod at boot.
    CONFIG_SQUASHFS=y
    CONFIG_SQUASHFS_LZ4=y
    CONFIG_OVERLAY_FS=y
SIZECFG

    make \
      ARCH=arm \
      CROSS_COMPILE=${crossCompile} \
      HOSTCC=${hostCC} \
      olddefconfig
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
    find arch/arm/boot/dts -maxdepth 1 -name "*.dtb" | while read dtb; do
      name=$(basename "$dtb")
      case "$name" in
        *luckfox*|*rv1103*|*rv1106*)
          cp "$dtb" $out/dtbs/"$name"
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

    # ── Strip debug symbols from kernel modules ───────────────────────────────
    # Even with CONFIG_DEBUG_INFO=n some .ko files may retain DWARF sections
    # from the vendor build system.  Stripping cuts module size by 30–70 %.
    echo "Stripping debug symbols from kernel modules..."
    find "$out/lib/modules" -name '*.ko' | while read ko; do
      ${crossCompile}strip --strip-debug "$ko" 2>/dev/null || true
    done
    echo "Modules after stripping: $(du -sh $out/lib/modules | cut -f1)"

    echo "=== kernel module version ==="
    ls "$out/lib/modules/"
  '';

  meta = {
    description = "Linux 5.10 kernel (zImage + DTBs + modules) for Luckfox Pico Mini B (RV1103/RV1106)";
  };
}
