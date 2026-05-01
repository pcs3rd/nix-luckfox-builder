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

  # ── postPatch: make CMD51 (SEND_SCR) failure non-fatal ──────────────────────
  #
  # RV1103 DRAM sits at physical 0x00000000–0x03FFFFFF (64 MB).
  # All load addresses use 0x00xxxxxx values within this range; the IDMAC DMA
  # engine works correctly as long as the destination is inside DRAM.
  #
  # The original BOOTCOMMAND used 0x43000000 (outside DRAM), causing IDMAC
  # AXI bus errors reported as CMD17 timeout (-110).  Fixed — do not add any
  # 0x4xxxxxxx addresses back; always keep addresses below 0x04000000.
  #
  # FIFO mode (CONFIG_DW_MMC_USE_FIFO) was tried as a workaround but causes
  # byte-swapping within each 32-bit word: dw_mmc's 32-bit readl() returns
  # bytes in little-endian word order, but the FIFO stream is byte-sequential.
  # The mkimage header survives (U-Boot uses be32_to_cpu() on header fields)
  # but script/binary data comes out with every 4-byte chunk byte-reversed.
  # Do not re-enable FIFO mode; IDMAC works correctly with valid DRAM addresses.
  #
  # CMD51 (SEND_SCR) non-fatal patch — belt-and-suspenders:
  #   mmc rescan reinitialises the card protocol.  During mmc_startup(), CMD51
  #   is the first data transfer.  On some boards it times out on the first
  #   attempt (the card clock may not be fully stable immediately after set_ios).
  #   Making CMD51 non-fatal lets mmc_init() complete with a default SCR (1-bit,
  #   SD 1.0) so subsequent CMD17 to valid DRAM addresses works correctly.
  postPatch = ''
    echo "=== postPatch: patching drivers/mmc/mmc.c — make CMD51 non-fatal ==="
    python3 - << 'PYEOF'
import sys

with open('drivers/mmc/mmc.c', 'r') as f:
    content = f.read()

# Locate the mmc_app_scr function body (static int mmc_app_scr(...) { ... })
func_sig = 'mmc_app_scr('
idx = content.find(func_sig)
if idx < 0:
    print("  WARNING: mmc_app_scr not found in mmc.c — patch skipped")
    sys.exit(0)

brace = content.find('{', idx)
if brace < 0:
    print("  WARNING: function body brace not found — patch skipped")
    sys.exit(0)

# Walk braces to find the matching closing brace
depth, pos, func_end = 0, brace, -1
while pos < len(content):
    if content[pos] == '{':  depth += 1
    elif content[pos] == '}':
        depth -= 1
        if depth == 0:
            func_end = pos; break
    pos += 1

if func_end < 0:
    print("  WARNING: matching closing brace not found — patch skipped")
    sys.exit(0)

body = content[brace:func_end + 1]

# The LAST 'return err;' in mmc_app_scr is after the CMD51 data read.
# All earlier 'return err;' (after CMD13, CMD55) should remain fatal.
last_ret = body.rfind('return err;')
if last_ret < 0:
    print("  WARNING: no 'return err;' found in mmc_app_scr body — patch skipped")
    sys.exit(0)

# Find the 'if (err)' that guards this return
if_pos = body.rfind('if (err)', 0, last_ret)
if if_pos < 0:
    print("  WARNING: no 'if (err)' before last 'return err;' — patch skipped")
    sys.exit(0)

# Derive indentation from the 'if (err)' line
line_start = body.rfind('\n', 0, if_pos) + 1
indent = '''
p = line_start
while p < if_pos and body[p] in ' \t':
    indent += body[p]; p += 1

end_ret = last_ret + len('return err;')
replacement = (
    'if (err) {\n'
    + indent + '\t/* CMD51 SEND_SCR timed out: use default SCR (1-bit, SD 1.0) */\n'
    + indent + '\tscr_tmp[0] = 0;\n'
    + indent + '\tscr_tmp[1] = 0;\n'
    + indent + '\terr = 0;\n'
    + indent + '}'
)

new_body = body[:if_pos] + replacement + body[end_ret:]
new_content = content[:brace] + new_body + content[func_end + 1:]

with open('drivers/mmc/mmc.c', 'w') as f:
    f.write(new_content)

print("  CMD51 (SEND_SCR) failure in mmc_app_scr() is now non-fatal (default SCR used)")
PYEOF

  '';

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

    # ── Enable distro_bootcmd ─────────────────────────────────────────────────
    # The Luckfox SDK's default U-Boot uses Rockchip's proprietary boot path
    # which looks for GPT partitions named "boot"/"misc" and Android FIT images.
    # Our image uses a standard DOS MBR with an ext4 boot partition and boot.scr.
    #
    # CONFIG_DISTRO_DEFAULTS enables distro_bootcmd, which scans MMC/USB/... for
    # boot.scr (and extlinux.conf) — exactly what we need.
    #
    # Also set the default boot device to mmc 1 (SD card on RV1103):
    #   mmc@ffa90000 = slot 0 (no physical card on Mini A/B)
    #   mmc@ffaa0000 = slot 1 (SD card — always slot 1)
    enable_config() {
      if grep -q "^# $1 is not set" .config; then
        sed -i "s/^# $1 is not set/$1=y/" .config
      elif ! grep -q "^$1=" .config; then
        echo "$1=y" >> .config
      fi
    }
    set_config_str() {
      if grep -q "^$1=" .config; then
        sed -i "s|^$1=.*|$1=$2|" .config
      else
        echo "$1=$2" >> .config
      fi
    }

    # CONFIG_DISTRO_DEFAULTS is not a recognized Kconfig symbol in this SDK's
    # U-Boot 2017.09 — it gets silently stripped by olddefconfig, so
    # distro_bootcmd is never defined.  Instead, set BOOTCOMMAND to directly
    # load and execute boot.scr from the FAT boot partition (mmc 1:1).
    # The generic 'load' command (CONFIG_CMD_FS_GENERIC) auto-detects FAT and
    # is compiled into this SDK's U-Boot; no ext4load or distro_bootcmd needed.
    #
    # RV1103 DRAM layout: 64 MB at physical 0x00000000–0x03FFFFFF.
    # All 0x4xxxxxxx addresses are OUTSIDE DRAM and cause IDMAC AXI bus errors
    # (reported as CMD17 timeout -110).  Use low addresses within DRAM:
    #   0x00300000 = boot.scr staging (3 MB mark — tiny script, safe here)
    #   kernel/dtb/initramfs use 0x00800000/0x01E00000/0x02000000 in boot.scr
    #
    # 'fatload' is compiled into this SDK's U-Boot (confirmed: the pre-boot
    # sd_update check uses it).  'load' (CONFIG_CMD_FS_GENERIC) is not.
    # 'source' executes a mkimage-wrapped script; enable it explicitly.
    enable_config CONFIG_CMD_SOURCE

    # ── MMC multi-block read workaround ───────────────────────────────────────
    # On this board the MMC driver's multi-block path (CMD18) fails with
    # "Re-init mmc_read_blocks error" when called from the command-line fatload
    # code path.  Single-block reads (CMD17) succeed (FAT directory / metadata
    # reads work; only file data transfers fail).  Force single-block I/O by
    # setting the maximum transfer size to one block (512 B).
    # This is slower but correct; file loads will work even if large reads fail.
    disable_config CONFIG_MMC_IO_VOLTAGE
    disable_config CONFIG_MMC_UHS_SUPPORT
    disable_config CONFIG_MMC_HS400_SUPPORT
    disable_config CONFIG_MMC_HS200_SUPPORT

    # Use Python to write BOOTCOMMAND to .config — the value contains embedded
    # double quotes which break sed when used inside a double-quoted expression.
    # BOOTCOMMAND explanation:
    #   mmc dev 1      — sets curr_device=1 in cmd/mmc.c so that subsequent
    #                    'mmc rescan' targets the SD card (not device 0).
    #   mmc rescan     — clears has_init, calls mmc_init() → set_ios() →
    #                    clk_set_rate() to recalibrate the clock divider against
    #                    the new PLL frequencies set by "CLK: (sync kernel)".
    #                    After this CMD17 runs at the correct 52 MHz.
    #   fatload ...    — reads boot.scr from the FAT boot partition.
    #   && source ...  — executes boot.scr only if fatload succeeded, preventing
    #                    a data-abort when running on uninitialised memory.
    python3 - << 'PYEOF'
import re, sys
bootcmd = r'CONFIG_BOOTCOMMAND="mmc dev 1; mmc rescan; fatload mmc 1:1 0x00300000 boot.scr && source 0x00300000"'
with open('.config') as f:
    content = f.read()
if re.search(r'^CONFIG_BOOTCOMMAND=', content, re.MULTILINE):
    content = re.sub(r'^CONFIG_BOOTCOMMAND=.*', bootcmd, content, flags=re.MULTILINE)
else:
    content += bootcmd + '\n'
with open('.config', 'w') as f:
    f.write(content)
print('  set ' + bootcmd)
PYEOF

    # Boot delay: 2 seconds — enough time to interrupt over serial (any key at
    # the "Hit key to stop autoboot" prompt).  Set to 0 for production.
    set_config_str CONFIG_BOOTDELAY 2

    # ── Patch C board config headers ─────────────────────────────────────────
    # U-Boot 2017.09 has incomplete Kconfig migration: many Rockchip boards
    # still #define CONFIG_BOOTCOMMAND and CONFIG_BOOTDELAY in include/configs/
    # C headers.  A C-header #define wins over a .config Kconfig value, so
    # the Kconfig changes above would have no effect if headers also define them.
    # Find and patch any such definitions to ensure our values take effect.
    for header in $(grep -rl "CONFIG_BOOTCOMMAND\|CONFIG_BOOTDELAY" include/configs/ 2>/dev/null); do
      if grep -q '#define CONFIG_BOOTCOMMAND' "$header"; then
        sed -i 's|#define CONFIG_BOOTCOMMAND .*|#define CONFIG_BOOTCOMMAND "mmc dev 1; mmc rescan; fatload mmc 1:1 0x00300000 boot.scr \&\& source 0x00300000"|' "$header"
        echo "  patched CONFIG_BOOTCOMMAND in $header"
      fi
      if grep -q '#define CONFIG_BOOTDELAY' "$header"; then
        sed -i 's|#define CONFIG_BOOTDELAY .*|#define CONFIG_BOOTDELAY 2|' "$header"
        echo "  patched CONFIG_BOOTDELAY in $header"
      fi
      # Belt-and-suspenders: cap block count at 1 to prevent CMD18 multi-block
      # transfers.  CONFIG_DW_MMC_USE_FIFO (FIFO/polling mode to fix broken IDMAC)
      # is injected into drivers/mmc/dw_mmc.c via postPatch instead of here,
      # because bare CONFIG_ symbols in board headers fail the Kconfig ad-hoc check.
      echo "" >> "$header"
      echo "#undef  CONFIG_SYS_MMC_MAX_BLK_COUNT" >> "$header"
      echo "#define CONFIG_SYS_MMC_MAX_BLK_COUNT 1" >> "$header"
      echo "  added CONFIG_SYS_MMC_MAX_BLK_COUNT=1 to $header"
    done

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
    IDBLOCK=""

    # Strategy 1 — some Rockchip defconfigs emit idbloader.img during make.
    if [ -f idbloader.img ]; then
      echo "Strategy 1: using build-generated idbloader.img"
      IDBLOCK="idbloader.img"
    fi

    # Strategy 2 — SDK pre-built idblock.img from project/image/.
    # These are identical to the Luckfox Ubuntu demo image binaries and are
    # verified to boot on real RV1103 hardware.  Preferred over mkimage because
    # the chip name mapping in this SDK's mkimage may not include rv1106.
    # sourceRoot = source/sysdrv/source/uboot/u-boot; ../../../../ = source/
    if [ -z "$IDBLOCK" ]; then
      echo "Strategy 2: searching SDK project/image/ for pre-built idblock.img..."
      for d in ../../../../project/image/*/; do
        if [ -f "$d/idblock.img" ]; then
          IDBLOCK="$d/idblock.img"
          echo "  Found: $d/idblock.img"
          break
        fi
      done
    fi

    # Strategy 3 — build idbloader from DDR blob + SPL using tools/mkimage -T rksd.
    # RV1103/RV1106 is the same silicon as RV1126; try chip names from the SDK's
    # supported list in order.  mkimage exits non-zero on unsupported names.
    if [ -z "$IDBLOCK" ] && [ -f tools/mkimage ] && [ -f rv1106_ddr.bin ] && [ -f spl/u-boot-spl.bin ]; then
      echo "Strategy 3: building idbloader with mkimage -T rksd..."
      for chipname in rv1126 rv1108 rk3308; do
        echo "  Trying -n $chipname ..."
        if ./tools/mkimage -n "$chipname" -T rksd \
            -d ./rv1106_ddr.bin:spl/u-boot-spl.bin \
            /tmp/idbloader-candidate.img 2>/dev/null; then
          IDBLOCK="/tmp/idbloader-candidate.img"
          echo "  Success with -n $chipname"
          break
        fi
      done
    fi

    if [ -z "$IDBLOCK" ]; then
      echo "ERROR: Cannot produce an idbloader by any strategy:" >&2
      echo "  1. No idbloader.img emitted by U-Boot build" >&2
      echo "  2. No idblock.img under ../../../../project/image/*/" >&2
      echo "     (dirs present: $(ls ../../../../project/image/ 2>/dev/null | head -5))" >&2
      echo "  3. mkimage -T rksd failed for all tried chip names (rv1126 rv1108 rk3308)" >&2
      echo "" >&2
      echo "Build artifacts present:" >&2
      find . -maxdepth 3 \( -name "*.bin" -o -name "*.img" \) 2>/dev/null | head -30 >&2
      exit 1
    fi

    cp "$IDBLOCK" $out/SPL

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
