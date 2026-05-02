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
  LUCKFOX_REV    = "824b817f889c2cbff1d48fcdb18ab494a68f69d1";
  LUCKFOX_SHA256 = "sha256-t0kiuP76j/D9i8l+o6JsYrDwUJjD/3cE3WBC+5TN2Lk=";

  # The SDK for this revision ships rv1106_defconfig as the base config.
  # (luckfox_pico_mini_b_defconfig does not exist in this tree — confirmed by
  # inspecting arch/arm/configs/ during the first build attempt.)
  KERNEL_DEFCONFIG = "rv1106_defconfig";

  # In a Nix cross stdenv, pkgs.stdenv.cc is the cross-compiler wrapper
  # (target = armv7l musl).  pkgs.buildPackages.stdenv.cc is the native
  # compiler wrapper for the build machine — may be GCC or clang.
  #
  # Use '/bin/cc' rather than '/bin/gcc': every Nixpkgs compiler wrapper
  # (both GCC and clang variants) provides a 'cc' entry point, while clang
  # wrappers don't expose 'gcc' and cross-compiler GCC wrappers only expose
  # the prefixed form (e.g. armv7l-...-gcc, not bare gcc).
  crossCompile = "${pkgs.stdenv.cc}/bin/${pkgs.stdenv.cc.targetPrefix}";
  hostCC       = "${pkgs.buildPackages.stdenv.cc}/bin/cc";

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
  # Note: $compiler, $LD, etc. are shell variables in the generated files —
  # they use plain $ (no braces) so Nix does not interpolate them.
  #
  # The Luckfox SDK Makefile sets:
  #   CC = scripts/gcc-wrapper.py $(CROSS_COMPILE)gcc
  # so gcc-version.sh is called as:
  #   gcc-version.sh scripts/gcc-wrapper.py /nix/store/.../armv7l-...-gcc
  # The real compiler is always the LAST positional argument.
  # We loop over all args so "last arg wins" regardless of how many wrappers
  # are prepended.  This also handles the plain single-arg form.
  gccVersionSh = builtins.toFile "gcc-version.sh" ''
    #!/bin/sh
    # gcc-version.sh — queries the compiler directly.
    # Handles both: gcc-version.sh <compiler>
    # and SDK form:  gcc-version.sh scripts/gcc-wrapper.py <compiler>
    # The real compiler is always the last positional argument.
    if [ $# -eq 0 ]; then echo "Usage: gcc-version.sh [wrapper] <compiler>" >&2; exit 1; fi
    for arg in "$@"; do compiler="$arg"; done
    MAJOR=$(echo __GNUC__            | "$compiler" -E -x c - | tail -1)
    MINOR=$(echo __GNUC_MINOR__      | "$compiler" -E -x c - | tail -1)
    PATCH=$(echo __GNUC_PATCHLEVEL__ | "$compiler" -E -x c - | tail -1)
    printf "%02d%02d%02d\n" "$MAJOR" "$MINOR" "$PATCH"
  '';

  ldVersionSh = builtins.toFile "ld-version.sh" ''
    #!/bin/sh
    # ld-version.sh — compatible with binutils ld.
    # Called as: ld-version.sh $(LD)  — LD may be empty on some SDK configs.
    # If called with no args, return a safe minimum version.
    if [ $# -eq 0 ]; then printf "0000\n"; exit 0; fi
    for arg in "$@"; do LD="$arg"; done
    LD_V=$($LD --version | head -1 | sed 's/.*\b\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/')
    MAJOR=$(echo "$LD_V" | cut -d. -f1)
    MINOR=$(echo "$LD_V" | cut -d. -f2)
    printf "%02d%02d\n" "$MAJOR" "$MINOR"
  '';

  # clang-version.sh — the SDK version also routes through gcc-wrapper.py.
  # Since we build with GCC (not clang), return 0 so Kconfig skips clang paths.
  clangVersionSh = builtins.toFile "clang-version.sh" ''
    #!/bin/sh
    # clang-version.sh — return 0 (not building with clang).
    printf "000000\n"
  '';

  # gcc-wrapper.py passthrough — the SDK ships a Python shim that locates the
  # bundled Rockchip cross-toolchain.  In a Nix sandbox the toolchain is on
  # PATH already, so we just exec the real compiler transparently.
  #
  # Called as:  scripts/gcc-wrapper.py <compiler> [args...]
  # Effect:     exec <compiler> [args...]   (first arg becomes argv[0])
  #
  # This is safer than patching every Makefile/Kconfig call site because the
  # wrapper is invoked from multiple places (Makefile CC=, init/Kconfig shell
  # expansions, scripts/Makefile.compiler, etc.).
  # Shell passthrough — avoids needing /usr/bin/env or Python in the sandbox.
  # /bin/sh is always available; Python is not guaranteed in early build phases.
  #
  # Called as:  scripts/gcc-wrapper.py <compiler> [flags...]
  # Effect:     exec <compiler> [flags...]
  gccWrapperPy = builtins.toFile "gcc-wrapper.py" ''
    #!/bin/sh
    # Passthrough wrapper — exec the real compiler with all remaining flags.
    # The Luckfox SDK calls this as:
    #   scripts/gcc-wrapper.py $(CROSS_COMPILE)gcc [flags...]
    if [ $# -eq 0 ]; then exit 0; fi
    compiler="$1"
    shift
    exec "$compiler" "$@"
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
    # Install a passthrough gcc-wrapper.py so every SDK call site works.
    # The SDK calls this from Makefile CC=, init/Kconfig shell expansions,
    # and possibly scripts/Makefile.compiler — patching all those is fragile.
    # A working passthrough is simpler: it just execs the real compiler.
    cp ${gccWrapperPy} scripts/gcc-wrapper.py
    chmod +x scripts/gcc-wrapper.py

    # Replace the other SDK build scripts that also break in the Nix sandbox.
    cp ${gccVersionSh} scripts/gcc-version.sh
    chmod +x scripts/gcc-version.sh

    cp ${ldVersionSh} scripts/ld-version.sh
    chmod +x scripts/ld-version.sh

    cp ${clangVersionSh} scripts/clang-version.sh
    chmod +x scripts/clang-version.sh

    echo "patched: gcc-wrapper.py gcc-version.sh ld-version.sh clang-version.sh"

    # ── Drop sorttable from the host-tools build ──────────────────────────────
    #
    # scripts/sorttable.c includes <elf.h>, a glibc-specific header that doesn't
    # exist on macOS (where pkgs.buildPackages is aarch64-darwin).  sorttable is
    # an optional build-time optimisation that pre-sorts the kernel exception
    # table; without it, the kernel sorts it at boot time in sort_main_extable().
    # Both paths produce identical runtime behaviour; boot overhead is negligible.
    #
    # Two places reference it:
    #   scripts/Makefile        — declares it as a host program to build
    #   scripts/link-vmlinux.sh — calls ./scripts/sorttable vmlinux after link
    #
    # Approach: remove it from the Makefile so sorttable.c is never compiled
    # (avoiding the elf.h dependency), then plant a do-nothing stub so that
    # link-vmlinux.sh finds the binary and exits cleanly — no shell surgery
    # needed, which avoids breaking the brace/function structure of the script.
    sed -i '/sorttable/d' scripts/Makefile
    printf '#!/bin/sh\nexit 0\n' > scripts/sorttable
    chmod +x scripts/sorttable

    # ── Force-add Luckfox Pico board DTS files to the build ───────────────────
    #
    # rv1106_defconfig compiles only its own board list; Pico Mini B DTS files
    # exist in some SDK revisions but aren't referenced by that defconfig.
    # If the source is present we add them to arch/arm/boot/dts/Makefile so
    # they're compiled alongside the rest of the DTBs.
    for dts in \
        arch/arm/boot/dts/rv1103-luckfox-pico-mini-a.dts \
        arch/arm/boot/dts/rv1103-luckfox-pico-mini-b.dts \
        arch/arm/boot/dts/rv1103-luckfox-pico.dts \
        arch/arm/boot/dts/rv1106-luckfox-pico-mini-b.dts \
        arch/arm/boot/dts/luckfox-pico-mini-b.dts; do
      if [ -f "$dts" ]; then
        dtb="$(basename "$dts" .dts).dtb"
        grep -qF "$dtb" arch/arm/boot/dts/Makefile \
          || echo "dtb-y += $dtb" >> arch/arm/boot/dts/Makefile
        echo "Added $dtb to DTS Makefile"
      fi
    done
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
    # CONFIG_WERROR: added in Linux 5.15; silently ignored by olddefconfig on 5.10.
    # Disabling it here is belt-and-suspenders alongside the KCFLAGS fix below.
    CONFIG_WERROR=n
    # A/B boot: ensure ext4 + squashfs + overlayfs are built-in (not modules)
    # so the initramfs can mount them without needing insmod at boot.
    # Without CONFIG_EXT4_FS=y, olddefconfig may silently leave it as =m,
    # causing the persist partition mount to fail (no module loaded) and the
    # slot-select init to fall back to tmpfs — writes become ephemeral.
    CONFIG_EXT4_FS=y
    CONFIG_SQUASHFS=y
    CONFIG_SQUASHFS_LZ4=y
    CONFIG_OVERLAY_FS=y
    # initramfs/initrd support — REQUIRED for the slot-select initramfs to work.
    # Without CONFIG_BLK_DEV_INITRD the kernel compiles out early_init_dt_check_for_initrd()
    # and completely ignores linux,initrd-start/end in /chosen.  The result is that
    # the kernel never reserves the initrd region, CMA claims 0x02000000 unchallenged,
    # and boot falls through to "Waiting for root device" as if no initramfs exists.
    CONFIG_BLK_DEV_INITRD=y
    # Decompressor for gzip-compressed cpio initramfs (what we produce with mkimage -C gzip).
    CONFIG_RD_GZIP=y
    # MMC/SD driver stack — pin to built-in (=y) so the SD card is visible
    # before any root filesystem is mounted.  olddefconfig has silently changed
    # some of these from =y to =m in recent rebuilds, causing /proc/partitions
    # to be empty in the initramfs and the slot-select init to time out.
    #
    #   CONFIG_MMC        — core MMC/SD subsystem
    #   CONFIG_MMC_BLOCK  — mmcblk block device driver (creates /dev/mmcblk*)
    #   CONFIG_MMC_DW     — DesignWare Mobile Storage Host Controller core
    #   CONFIG_MMC_DW_ROCKCHIP — Rockchip-specific DW-MMC glue (RV1103/RV1106)
    CONFIG_MMC=y
    CONFIG_MMC_BLOCK=y
    CONFIG_MMC_DW=y
    CONFIG_MMC_DW_ROCKCHIP=y
    # Partition table scanning — required for the kernel to see mmcblkNp1..p4.
    # CONFIG_PARTITION_ADVANCED gates the per-type selectors; without it the
    # kernel only scans MSDOS (MBR) partitions by default.  If PARTITION_ADVANCED
    # is enabled in the vendor defconfig (common on Rockchip for GUID/Rockchip
    # partition support) then CONFIG_MSDOS_PARTITION must be explicit or the
    # kernel silently produces no partition devices from a valid MBR disk.
    CONFIG_PARTITION_ADVANCED=y
    CONFIG_MSDOS_PARTITION=y
    # USB gadget stack — dual approach: legacy g_serial + configfs.
    #
    # RV1103 USB hardware (from live device tree):
    #   usbdrd/usb@ffb00000  — Synopsys DWC3 OTG core (snps,* quirk properties confirm DWC3)
    #   usb2-phy@ff3e0000    — Rockchip Inno USB2 PHY (rockchip,usbgrf property)
    #
    # Approach A — legacy gadget (CONFIG_USB_G_SERIAL):
    #   Simpler path that does not require configfs.  When USB_G_SERIAL=y the
    #   kernel registers a CDC-ACM gadget automatically and creates /dev/ttyGS0
    #   as soon as the DWC3 UDC probes.  Host sees /dev/ttyACMx.  No userspace
    #   setup script is needed; the usb-gadget service detects this and exits
    #   early if /dev/ttyGS0 already exists.
    #
    # Approach B — configfs gadget (CONFIG_USB_CONFIGFS):
    #   Flexible userspace-configurable path.  Requires CONFIG_USB_CONFIGFS=y
    #   surviving olddefconfig (previous builds showed it being silently dropped
    #   — likely a vendor Kconfig dependency we haven't yet identified).  Kept
    #   here alongside g_serial so both paths are available.
    #
    # CONFIG_USB_DWC3              — DWC3 core driver; registers the UDC
    # CONFIG_USB_DWC3_OF_SIMPLE    — DT glue for the "usbdrd" wrapper node
    # CONFIG_PHY_ROCKCHIP_INNO_USB2 — Inno USB2 PHY (rv1106-usb2phy)
    # CONFIG_USB_LIBCOMPOSITE      — required by both g_serial and configfs
    # CONFIG_USB_U_SERIAL          — serial line discipline (selected by g_serial)
    # CONFIG_USB_F_ACM             — CDC-ACM function (selected by g_serial)
    # CONFIG_USB_G_SERIAL          — legacy serial gadget (Approach A)
    # CONFIG_CONFIGFS_FS           — kernel configfs filesystem
    # CONFIG_USB_CONFIGFS          — configfs-based gadget (Approach B)
    # CONFIG_USB_CONFIGFS_SERIAL   — generic serial via configfs
    # CONFIG_USB_CONFIGFS_ACM      — CDC-ACM via configfs (vendor kernel symbol)
    # CONFIG_USB_ROLE_SWITCH       — lets Inno PHY expose /sys/class/usb_role/
    # Enable /proc/config.gz so the running kernel can be introspected.
    CONFIG_IKCONFIG=y
    CONFIG_IKCONFIG_PROC=y
    # USB host core and support — DWC3 Kconfig in some vendor trees has
    # "depends on USB" (not "USB || USB_GADGET"), so enabling host ensures
    # DWC3 can compile even if the gadget-only path is broken.
    CONFIG_USB_SUPPORT=y
    CONFIG_USB=y
    CONFIG_USB_ANNOUNCE_NEW_DEVICES=n
    # EXTCON — required by PHY_ROCKCHIP_INNO_USB2 (via 'select EXTCON').
    # Adding it explicitly ensures olddefconfig doesn't drop the PHY because
    # EXTCON wasn't yet selected when it evaluated PHY_ROCKCHIP_INNO_USB2.
    CONFIG_EXTCON=y
    CONFIG_USB_DWC3=y
    CONFIG_USB_DWC3_OF_SIMPLE=y
    CONFIG_PHY_ROCKCHIP_INNO_USB2=y
    # Low-level USB serial building blocks (both paths need these).
    CONFIG_USB_GADGET=y
    CONFIG_USB_LIBCOMPOSITE=y
    CONFIG_USB_U_SERIAL=y
    CONFIG_USB_F_ACM=y
    # Approach A: legacy g_serial gadget (does not need configfs).
    # USB_G_SERIAL selects USB_LIBCOMPOSITE + USB_F_ACM + USB_U_SERIAL + USB_F_OBEX.
    CONFIG_USB_G_SERIAL=y
    # Approach B: configfs gadget (more flexible; vendor kernel may or may not
    # support this — USB_CONFIGFS has been observed to be stripped by
    # olddefconfig in this vendor tree; root cause under investigation).
    CONFIG_CONFIGFS_FS=y
    CONFIG_USB_CONFIGFS=y
    CONFIG_USB_CONFIGFS_SERIAL=y
    CONFIG_USB_CONFIGFS_ACM=y
    # USB_ROLE_SWITCH — lets the Inno USB2 PHY register a role-switch device in
    # /sys/class/usb_role/.  Without it, the usb-mode service cannot force device
    # mode at boot and the board must rely on VBUS detection when a cable is plugged
    # in.  With it, device mode is active immediately at boot regardless of cable.
    CONFIG_USB_ROLE_SWITCH=y
    # Swap subsystem — without CONFIG_SWAP=y the swapon(2) syscall returns
    # ENOSYS ("Function not implemented") and neither disk swapfiles nor
    # zram swap can be activated, regardless of mkswap succeeding.
    CONFIG_SWAP=y
    # zram compressed RAM swap.
    # CONFIG_ZSMALLOC — memory allocator optimised for compressed pages (zram dependency)
    # CONFIG_CRYPTO_LZ4 — lz4 compression algorithm (fast; 3:1 ratio on typical data)
    # CONFIG_ZRAM — zram block device backed by compressed RAM (swap source)
    CONFIG_ZSMALLOC=y
    CONFIG_CRYPTO_LZ4=y
    CONFIG_ZRAM=y
SIZECFG

    make \
      ARCH=arm \
      CROSS_COMPILE=${crossCompile} \
      HOSTCC=${hostCC} \
      olddefconfig

    # ── Diagnostic: show final USB/PHY/EXTCON/GADGET config values ──────────
    # These lines appear in the Nix build log.  If any critical option shows
    # as "# CONFIG_FOO is not set" instead of "CONFIG_FOO=y", olddefconfig
    # stripped it due to an unmet dependency — that's the root cause to fix.
    #
    # Key options to watch:
    #   CONFIG_USB_G_SERIAL=y      — legacy serial gadget (Approach A, no configfs)
    #   CONFIG_USB_CONFIGFS=y      — configfs gadget (Approach B)
    #   CONFIG_USB_CONFIGFS_ACM=y  — CDC-ACM via configfs
    #   CONFIG_PHY_ROCKCHIP_INNO_USB2=y — PHY driver (DWC3 won't probe without it)
    #   CONFIG_USB_ROLE_SWITCH=y   — USB role-switch /sys/class/usb_role/
    echo "=== USB / PHY / GADGET config after olddefconfig ==="
    grep -E "^(CONFIG_USB|CONFIG_PHY_ROCKCHIP|CONFIG_EXTCON|CONFIG_CONFIGFS|CONFIG_SWAP|CONFIG_ZRAM|# CONFIG_USB|# CONFIG_PHY_ROCKCHIP|# CONFIG_CONFIGFS)" .config | sort || true
    echo "=== end USB config ==="
  '';

  buildPhase = ''
    # KCFLAGS: suppress GCC 12+ warnings that Linux 5.10 was never written to
    # handle.  The kernel treats these as errors via -Werror, so without the
    # suppression the build fails even though the code is correct.
    #
    #   -Wno-dangling-pointer  — false positive in drivers/dma-buf/dma-fence.c:
    #                            storing the address of a local inside a fence
    #                            callback struct that is fully in scope
    #   -Wno-array-parameter   — GCC 12 stricter about array pointer decay in
    #                            function signatures; harmless in kernel context
    #   -Wno-use-after-free    — GCC 12 heuristic false positives in linked-list
    #                            manipulation macros
    make -j$NIX_BUILD_CORES \
      ARCH=arm \
      CROSS_COMPILE=${crossCompile} \
      HOSTCC=${hostCC} \
      KCFLAGS="-Wno-dangling-pointer -Wno-array-parameter -Wno-use-after-free" \
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
