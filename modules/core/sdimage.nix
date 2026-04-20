# Flashable SD image for the Luckfox Pico Mini B (Rockchip RV1103)
#
# Produces a raw disk image that can be written directly to an SD card:
#
#   dd if=result/sd-flashable.img of=/dev/sdX bs=4M status=progress
#
# Layout:
#   Offset 0x0000 (sector     0) : MBR + partition table
#   Offset 0x8000 (sector    64) : Rockchip SPL / idbloader  ← if provided
#   Offset 0x8000 00 (sector 16384) : U-Boot proper          ← if provided
#   Offset 0x10 0000 (2 MiB)    : ext4 rootfs partition (partition 1)
#
# The 2 MiB gap before the first partition gives plenty of room for both
# the MBR and the Rockchip bootloader blobs without overlapping the data
# partition.
#
# macOS-compatible: uses mkfs.ext4 -d to populate the filesystem from a
# directory — no losetup or mount required.

{ pkgs, config, lib, ... }:

let
  rootfs = config.system.build.rootfs;
  spl    = config.boot.uboot.spl;
  uboot  = config.boot.uboot.package;

  # Sector at which partition 1 starts (2 MiB = 4096 × 512 B sectors).
  partStartSector = 4096;
in

{
  config.system.build.sdImage = pkgs.runCommand "sd-flashable.img" {
    nativeBuildInputs = with pkgs.buildPackages; [
      e2fsprogs   # mkfs.ext4 with -d flag
      python3     # MBR partition-table writer
    ];
  } ''
    IMAGE_MB=${toString config.system.imageSize}
    SECTOR=${toString partStartSector}
    IMAGE_BYTES=$(( IMAGE_MB * 1024 * 1024 ))
    PART_SIZE_SECTORS=$(( (IMAGE_BYTES / 512) - SECTOR ))
    PART_SIZE_BYTES=$(( PART_SIZE_SECTORS * 512 ))

    echo "Building flashable SD image (''${IMAGE_MB} MiB)..."

    # ── Blank image ─────────────────────────────────────────────────────────
    dd if=/dev/zero of=$out bs=1M count=$IMAGE_MB 2>/dev/null

    # ── MBR partition table ─────────────────────────────────────────────────
    # Written with Python so this step works on macOS and Linux alike.
    python3 - $SECTOR $PART_SIZE_SECTORS << 'PYEOF'
import struct, sys

start = int(sys.argv[1])
size  = int(sys.argv[2])

def chs(lba):
    """Pack LBA address as a 3-byte CHS tuple (best-effort, capped at 1023)."""
    c = min(lba // (255 * 63), 1023)
    h = (lba // 63) % 255
    s = (lba %  63) + 1
    return bytes([h & 0xFF, (s & 0x3F) | ((c >> 2) & 0xC0), c & 0xFF])

entry = struct.pack('<B3sB3sII',
    0x00,              # status: not bootable
    chs(start),        # CHS of first sector
    0x83,              # partition type: Linux filesystem
    chs(start + size - 1),
    start,             # LBA start
    size,              # LBA size
)
mbr = b'\x00' * 446 + entry + b'\x00' * 48 + b'\x55\xAA'

import os
fd = os.open('mbr.bin', os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
os.write(fd, mbr)
os.close(fd)
PYEOF
    dd if=mbr.bin of=$out bs=1 conv=notrunc 2>/dev/null

    # ── Stage rootfs + kernel + DTB + extlinux.conf ─────────────────────────
    cp -r ${rootfs} staging
    chmod -R u+w staging

    ${lib.optionalString (config.device.kernel != null) ''
      cp ${config.device.kernel} staging/zImage
    ''}

    ${lib.optionalString (config.device.dtb != null) ''
      cp ${config.device.dtb} staging/${config.device.name}.dtb
    ''}

    mkdir -p staging/extlinux
    cat > staging/extlinux/extlinux.conf << EXTEOF
LABEL linux
  KERNEL /zImage
${lib.optionalString (config.device.dtb != null)
  "  FDT /${config.device.name}.dtb"}
  APPEND ${config.boot.cmdline}
EXTEOF

    # ── Build ext4 partition image from staging directory ───────────────────
    # mkfs.ext4 -d populates the filesystem in-place from a directory tree,
    # without needing to mount anything — safe on macOS and in the Nix sandbox.
    dd if=/dev/zero of=part.img bs=1 count=0 seek=$PART_SIZE_BYTES 2>/dev/null
    mkfs.ext4 \
      -d staging \
      -L rootfs \
      -E lazy_itable_init=0,lazy_journal_init=0 \
      part.img

    # ── Embed partition into disk image ─────────────────────────────────────
    dd if=part.img of=$out bs=512 seek=$SECTOR conv=notrunc 2>/dev/null

    # ── Write Rockchip bootloader blobs ─────────────────────────────────────
    # SPL / idbloader at sector 64 (Rockchip boot ROM requirement)
    ${lib.optionalString (spl != null) ''
      echo "Writing SPL at sector 64..."
      dd if=${spl} of=$out bs=512 seek=64 conv=notrunc 2>/dev/null
    ''}

    # U-Boot proper at sector 16384 (8 MiB)
    ${lib.optionalString (uboot != null) ''
      echo "Writing U-Boot at sector 16384..."
      dd if=${uboot} of=$out bs=512 seek=16384 conv=notrunc 2>/dev/null
    ''}

    echo "SD image ready: $out"
    echo "Flash with: dd if=$out of=/dev/sdX bs=4M status=progress"
  '';
}
