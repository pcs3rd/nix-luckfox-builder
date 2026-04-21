# Pre-built kernel + firmware blobs for the Pine64 Ox64 (BL808).
#
# Fetched from the OpenBouffalo buildroot release and pinned by content hash.
#
# ── Release tarball layout (v1.0.1) ──────────────────────────────────────────
#
#   firmware/
#     bl808-firmware.bin                       — combined SPI flash image
#     d0_lowload_bl808_d0.bin                  — D0 (Linux core) pre-loader
#     m0_lowload_bl808_m0.bin                  — M0 (RTOS/WiFi) pre-loader
#     sdcard-pine64_ox64_full_defconfig.img.xz — full SD card image
#
# The kernel (Image) and DTB live inside the FAT boot partition of the SD card
# image.  This derivation decompresses the image, uses Python to locate the FAT
# partition (works on both macOS and Linux build hosts — no sfdisk/fdisk), then
# extracts files via mtools without needing root or a loop device.
#
# ── Updating ─────────────────────────────────────────────────────────────────
#
# 1. Find the new release at:
#      https://github.com/openbouffalo/buildroot_bouffalo/releases
#
# 2. Update BUILDROOT_REV and get the new SRI hash:
#      nix store prefetch-file --hash-type sha256 --unpack \
#        https://github.com/openbouffalo/buildroot_bouffalo/releases/download/<rev>/bl808-linux-pine64_ox64_full_defconfig.tar.gz
#
# 3. Paste the sha256-... hash into BUILDROOT_SHA256 below.

{ pkgs }:

let
  BUILDROOT_REV    = "v1.0.1";
  BUILDROOT_SHA256 = "sha256-/jlQc2OF/4Hpn3KnClHhmvvtZ18AvgWsupr7yihLpwY=";

  src = pkgs.fetchurl {
    url    = "https://github.com/openbouffalo/buildroot_bouffalo/releases/download/${BUILDROOT_REV}/bl808-linux-pine64_ox64_full_defconfig.tar.gz";
    sha256 = BUILDROOT_SHA256;
  };

  # Python script that locates the first FAT partition in an MBR or GPT disk
  # image.  Portable: works on macOS and Linux without sfdisk/fdisk.
  findFatSector = pkgs.writeText "find-fat-sector.py" ''
    #!/usr/bin/env python3
    """
    Print the start sector (LBA) of the first FAT partition in a disk image.
    Checks GPT and MBR partition tables, verifying each candidate with a FAT
    boot-sector signature check.  Falls back to brute-force scanning.
    """
    import struct, sys, os

    SECTOR = 512
    img = sys.argv[1]

    def is_fat(f, lba):
        """Return True if the 512-byte sector at lba is a FAT boot sector."""
        try:
            f.seek(lba * SECTOR)
            s = f.read(SECTOR)
            if len(s) < 512 or s[510:512] != b'\x55\xAA':
                return False
            # FAT12/FAT16: OEM name area at 54; FAT32: at 82
            return s[54:57] == b'FAT' or s[82:87] == b'FAT32'
        except Exception:
            return False

    with open(img, 'rb') as f:
        mbr = f.read(SECTOR)
        if len(mbr) < SECTOR:
            sys.exit(1)

        # ── GPT ───────────────────────────────────────────────────────────────
        # Protective MBR has partition type 0xEE at the first entry.
        if mbr[446 + 4] == 0xEE:
            f.seek(SECTOR)
            gpt = f.read(92)
            if gpt[:8] == b'EFI PART':
                pe_lba = struct.unpack_from('<Q', gpt, 72)[0]
                pe_num = min(struct.unpack_from('<I', gpt, 80)[0], 128)
                pe_sz  = max(struct.unpack_from('<I', gpt, 84)[0], 128)

                f.seek(pe_lba * SECTOR)
                raw = f.read(pe_num * pe_sz)

                starts = []
                for i in range(pe_num):
                    e = raw[i*pe_sz:(i+1)*pe_sz]
                    if len(e) < 48:
                        break
                    start = struct.unpack_from('<Q', e, 32)[0]
                    end   = struct.unpack_from('<Q', e, 40)[0]
                    if start > 0 and end > start:
                        starts.append(start)

                print(f"DEBUG GPT partitions: {starts}", file=sys.stderr)

                # Prefer whichever partition has a FAT filesystem
                for s in starts:
                    if is_fat(f, s):
                        print(f"DEBUG FAT found at sector {s}", file=sys.stderr)
                        print(s)
                        sys.exit(0)

                # No FAT found — the Ox64 first partition is a raw BL808 boot
                # partition; the kernel is typically on the second partition.
                if len(starts) >= 2:
                    print(f"DEBUG no FAT found, using partition 2 at {starts[1]}", file=sys.stderr)
                    print(starts[1])
                    sys.exit(0)
                elif starts:
                    print(starts[0])
                    sys.exit(0)

        # ── MBR ───────────────────────────────────────────────────────────────
        if mbr[510:512] == b'\x55\xAA':
            FAT_TYPES = {0x01, 0x04, 0x06, 0x0b, 0x0c, 0x0e, 0x1b, 0x1c, 0x1e}
            parts = []
            for i in range(4):
                e = mbr[446 + i*16 : 446 + i*16 + 16]
                ptype = e[4]
                start = struct.unpack_from('<I', e, 8)[0]
                size  = struct.unpack_from('<I', e, 12)[0]
                if start > 0 and size > 0 and ptype != 0:
                    parts.append((ptype, start))

            print(f"DEBUG MBR partitions: {parts}", file=sys.stderr)

            for ptype, start in parts:
                if ptype in FAT_TYPES:
                    print(start); sys.exit(0)
            for ptype, start in parts:
                if is_fat(f, start):
                    print(start); sys.exit(0)
            if parts:
                print(parts[0][1]); sys.exit(0)

        # ── Brute-force: scan common sector offsets for FAT signature ─────────
        img_size = os.path.getsize(img)
        for candidate in [2048, 4096, 8192, 16384, 32768, 65536, 131072, 1, 63]:
            if candidate * SECTOR + SECTOR > img_size:
                continue
            if is_fat(f, candidate):
                print(f"DEBUG brute-force FAT at sector {candidate}", file=sys.stderr)
                print(candidate)
                sys.exit(0)

    print("ERROR: no FAT partition found", file=sys.stderr)
    sys.exit(1)
  '';

in

pkgs.runCommand "ox64-firmware-${BUILDROOT_REV}" {
  nativeBuildInputs = with pkgs.buildPackages; [
    gnutar gzip xz
    mtools         # mcopy / mdir — portable FAT image access
    python3        # partition table parsing (works on macOS and Linux)
  ];
} ''
  mkdir -p src $out
  tar -xzf ${src} -C src

  FIRMWARE=$(find src -type d -name firmware | head -1)
  if [ -z "$FIRMWARE" ]; then
    echo "ERROR: firmware/ directory not found in tarball" >&2
    find src -maxdepth 4 >&2; exit 1
  fi

  # ── Pre-loader blobs ───────────────────────────────────────────────────────
  # Handle both old naming (low_load_*) and new naming (d0_lowload_* / m0_lowload_*)
  if [ -f "$FIRMWARE/d0_lowload_bl808_d0.bin" ]; then
    cp "$FIRMWARE/d0_lowload_bl808_d0.bin" "$out/low_load_bl808_d0.bin"
  elif [ -f "$FIRMWARE/low_load_bl808_d0.bin" ]; then
    cp "$FIRMWARE/low_load_bl808_d0.bin"   "$out/low_load_bl808_d0.bin"
  else
    echo "ERROR: D0 pre-loader not found" >&2; ls "$FIRMWARE" >&2; exit 1
  fi

  if [ -f "$FIRMWARE/m0_lowload_bl808_m0.bin" ]; then
    cp "$FIRMWARE/m0_lowload_bl808_m0.bin" "$out/low_load_bl808_m0.bin"
  elif [ -f "$FIRMWARE/low_load_bl808_m0.bin" ]; then
    cp "$FIRMWARE/low_load_bl808_m0.bin"   "$out/low_load_bl808_m0.bin"
  else
    echo "ERROR: M0 pre-loader not found" >&2; ls "$FIRMWARE" >&2; exit 1
  fi

  # ── Decompress the SD card image ──────────────────────────────────────────
  SDIMG_XZ=$(find "$FIRMWARE" -name '*.img.xz' | head -1)
  if [ -z "$SDIMG_XZ" ]; then
    echo "ERROR: no .img.xz found in $FIRMWARE" >&2; ls "$FIRMWARE" >&2; exit 1
  fi
  echo "ox64-firmware: decompressing ''${SDIMG_XZ##*/} ..."
  xz -dk "$SDIMG_XZ"
  SDIMG="''${SDIMG_XZ%.xz}"

  # ── Locate FAT boot partition using portable Python parser ────────────────
  FAT_SECTOR=$(python3 ${findFatSector} "$SDIMG") || {
    echo "ERROR: could not locate FAT partition in $SDIMG" >&2; exit 1
  }
  FAT_OFFSET=$(( FAT_SECTOR * 512 ))
  echo "ox64-firmware: FAT partition at sector $FAT_SECTOR (byte offset $FAT_OFFSET)"

  export MTOOLS_SKIP_CHECK=1

  # Diagnostic: list FAT contents
  echo "ox64-firmware: FAT partition contents:"
  mdir -i "$SDIMG@@$FAT_OFFSET" -/ 2>&1 || true

  # ── Extract kernel image ──────────────────────────────────────────────────
  if ! mcopy -i "$SDIMG@@$FAT_OFFSET" ::Image "$out/Image" 2>/dev/null; then
    # Some images place it in /boot/
    mcopy -i "$SDIMG@@$FAT_OFFSET" ::/boot/Image "$out/Image" 2>/dev/null || {
      echo "ERROR: Image not found in FAT partition" >&2; exit 1
    }
  fi

  # ── Extract DTB ───────────────────────────────────────────────────────────
  DTB_PATH=$(mdir -b -i "$SDIMG@@$FAT_OFFSET" 2>/dev/null \
    | grep -i '\.dtb$' | head -1 | sed 's|^::||')
  if [ -z "$DTB_PATH" ]; then
    echo "ERROR: no .dtb found in FAT partition" >&2
    mdir -i "$SDIMG@@$FAT_OFFSET" >&2; exit 1
  fi
  echo "ox64-firmware: extracting DTB: $DTB_PATH"
  mcopy -i "$SDIMG@@$FAT_OFFSET" "::$DTB_PATH" "$out/bl808-pine64-ox64.dtb"

  # ── Verify ────────────────────────────────────────────────────────────────
  for f in Image bl808-pine64-ox64.dtb low_load_bl808_d0.bin low_load_bl808_m0.bin; do
    [ -f "$out/$f" ] || { echo "ERROR: $out/$f was not produced" >&2; exit 1; }
  done

  echo "ox64-firmware ${BUILDROOT_REV} unpacked:"
  ls -lh "$out/"
''
