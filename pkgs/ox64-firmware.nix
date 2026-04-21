# Pre-built kernel + firmware blobs for the Pine64 Ox64 (BL808).
#
# Fetched from the OpenBouffalo buildroot release and pinned by content hash.
#
# ── Release tarball layout (v1.0.1) ──────────────────────────────────────────
#
# The v1.0.1 tarball ships a different layout than early releases:
#
#   firmware/
#     bl808-firmware.bin                      — combined SPI flash image
#     d0_lowload_bl808_d0.bin                 — D0 (Linux core) pre-loader
#     m0_lowload_bl808_m0.bin                 — M0 (RTOS/WiFi) pre-loader
#     sdcard-pine64_ox64_full_defconfig.img.xz — full SD card image
#
# The kernel (Image) and DTB live inside the FAT boot partition of the SD
# card image.  This derivation decompresses the image, finds the FAT
# partition using sfdisk, and extracts the files via mtools (no root/mount).
#
# ── Updating ─────────────────────────────────────────────────────────────────
#
# 1. Find the new release at:
#      https://github.com/openbouffalo/buildroot_bouffalo/releases
#
# 2. Update BUILDROOT_REV and get the new hash:
#      nix-prefetch-url --unpack \
#        https://github.com/openbouffalo/buildroot_bouffalo/releases/download/\
#        <rev>/bl808-linux-pine64_ox64_full_defconfig.tar.gz
#
#    Or using the flake CLI:
#      nix store prefetch-file --hash-type sha256 --unpack <url>
#
# 3. Paste the sri hash (sha256-...) into BUILDROOT_SHA256 below.

{ pkgs }:

let
  lib = pkgs.lib;

  BUILDROOT_REV    = "v1.0.1";
  BUILDROOT_SHA256 = "sha256-/jlQc2OF/4Hpn3KnClHhmvvtZ18AvgWsupr7yihLpwY=";

  src = pkgs.fetchurl {
    url    = "https://github.com/openbouffalo/buildroot_bouffalo/releases/download/${BUILDROOT_REV}/bl808-linux-pine64_ox64_full_defconfig.tar.gz";
    sha256 = BUILDROOT_SHA256;
  };

in

pkgs.runCommand "ox64-firmware-${BUILDROOT_REV}" {
  nativeBuildInputs = with pkgs.buildPackages; [
    gnutar gzip xz
    mtools       # mcopy / mdir — FAT image access without mounting
    util-linux   # sfdisk — partition table parsing
  ];
} ''
  mkdir -p src $out
  tar -xzf ${src} -C src

  FIRMWARE=$(find src -type d -name firmware | head -1)
  if [ -z "$FIRMWARE" ]; then
    echo "ERROR: firmware/ directory not found in tarball" >&2
    find src -maxdepth 4 >&2
    exit 1
  fi

  # ── Pre-loader blobs ───────────────────────────────────────────────────────
  # The naming convention flipped between releases; handle both.
  if [ -f "$FIRMWARE/d0_lowload_bl808_d0.bin" ]; then
    cp "$FIRMWARE/d0_lowload_bl808_d0.bin" "$out/low_load_bl808_d0.bin"
  elif [ -f "$FIRMWARE/low_load_bl808_d0.bin" ]; then
    cp "$FIRMWARE/low_load_bl808_d0.bin"   "$out/low_load_bl808_d0.bin"
  else
    echo "ERROR: D0 pre-loader not found in $FIRMWARE" >&2; ls "$FIRMWARE" >&2; exit 1
  fi

  if [ -f "$FIRMWARE/m0_lowload_bl808_m0.bin" ]; then
    cp "$FIRMWARE/m0_lowload_bl808_m0.bin" "$out/low_load_bl808_m0.bin"
  elif [ -f "$FIRMWARE/low_load_bl808_m0.bin" ]; then
    cp "$FIRMWARE/low_load_bl808_m0.bin"   "$out/low_load_bl808_m0.bin"
  else
    echo "ERROR: M0 pre-loader not found in $FIRMWARE" >&2; ls "$FIRMWARE" >&2; exit 1
  fi

  # ── Kernel and DTB from inside the SD card image ───────────────────────────
  SDIMG_XZ=$(find "$FIRMWARE" -name '*.img.xz' | head -1)
  if [ -z "$SDIMG_XZ" ]; then
    echo "ERROR: no .img.xz found in $FIRMWARE" >&2; ls "$FIRMWARE" >&2; exit 1
  fi

  echo "ox64-firmware: decompressing ''${SDIMG_XZ##*/} ..."
  xz -dk "$SDIMG_XZ"
  SDIMG="''${SDIMG_XZ%.xz}"

  # Find the FAT boot partition's start sector.
  # sfdisk --dump prints lines like: "  start=2048, size=..., type=c"
  FAT_SECTOR=$(sfdisk -d "$SDIMG" 2>/dev/null \
    | awk '/start=/{
        # extract start= value
        for (i=1; i<=NF; i++) {
          if ($i ~ /^start=/) {
            v = substr($i, 7) + 0
            if (v > 0) { print v; exit }
          }
        }
      }')

  if [ -z "$FAT_SECTOR" ] || [ "$FAT_SECTOR" -eq 0 ]; then
    echo "WARNING: sfdisk could not find partition; assuming 2048-sector offset" >&2
    FAT_SECTOR=2048
  fi

  FAT_OFFSET=$(( FAT_SECTOR * 512 ))
  echo "ox64-firmware: FAT partition at sector $FAT_SECTOR (byte offset $FAT_OFFSET)"

  export MTOOLS_SKIP_CHECK=1

  # List FAT contents for diagnostics
  echo "ox64-firmware: FAT partition contents:"
  mdir -i "$SDIMG@@$FAT_OFFSET" -/ 2>/dev/null || true

  # Extract kernel image
  if ! mcopy -i "$SDIMG@@$FAT_OFFSET" ::Image "$out/Image" 2>/dev/null; then
    echo "ERROR: Image not found in FAT partition" >&2; exit 1
  fi

  # Extract DTB — find any .dtb file in the FAT partition
  DTB_PATH=$(mdir -b -i "$SDIMG@@$FAT_OFFSET" 2>/dev/null \
    | grep -i '\.dtb$' | head -1 | sed 's|^::||')
  if [ -z "$DTB_PATH" ]; then
    echo "ERROR: no .dtb found in FAT partition" >&2; exit 1
  fi
  echo "ox64-firmware: extracting DTB: $DTB_PATH"
  mcopy -i "$SDIMG@@$FAT_OFFSET" "::$DTB_PATH" "$out/bl808-pine64-ox64.dtb"

  # ── Final verification ────────────────────────────────────────────────────
  for f in Image bl808-pine64-ox64.dtb low_load_bl808_d0.bin low_load_bl808_m0.bin; do
    if [ ! -f "$out/$f" ]; then
      echo "ERROR: $out/$f was not produced" >&2; exit 1
    fi
  done

  echo "ox64-firmware ${BUILDROOT_REV} unpacked:"
  ls -lh "$out/"
''
