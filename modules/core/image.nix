# Rootfs disk image — single ext4 partition containing the rootfs, kernel, DTB,
# and extlinux.conf.  Works on macOS and Linux without root or losetup.
#
# ── How it works ──────────────────────────────────────────────────────────────
#
# Uses mkfs.ext4 -d to populate the filesystem from a staging directory without
# needing to mount anything.  The MBR partition table is written in Python.
# No losetup, no mount, no parted — all sandbox-safe.
#
# ── When to use this vs sdimage.nix ───────────────────────────────────────────
#
# image.nix (this file) — system.build.image
#   Single ext4 partition with kernel+rootfs inside.
#   Used for the Ox64 (rootfs partition to dd onto the SD card alongside the
#   OpenBouffalo FAT boot partition) and for the Luckfox rootfs-only output.
#
# sdimage.nix — system.build.sdImage
#   Full flashable SD card image with MBR + Rockchip bootloader blobs.
#   Used for the Luckfox Pico Mini B SD image builds.
#   Supports A/B when system.abRootfs.enable = true.

{ pkgs, config, lib, ... }:

let
  # Kernel filename varies by architecture.
  # ARM uses compressed zImage; RISC-V and AArch64 use uncompressed Image.
  kernelFile =
    if pkgs.stdenv.hostPlatform.isAarch32 then "zImage"
    else "Image";
in

{
  config.system.build.image = pkgs.runCommand "sd.img" {
    # nativeBuildInputs = tools that run on the BUILD machine.
    # In a cross-compilation package set (e.g. riscv64-musl), buildInputs
    # would give us riscv64 binaries that can't execute on the build host.
    nativeBuildInputs = with pkgs.buildPackages; [
      e2fsprogs   # mkfs.ext4 with -d flag (no mount needed)
      python3     # MBR partition-table writer
    ];
  } ''
    IMG=$out
    IMAGE_MB=${toString config.system.imageSize}
    IMAGE_BYTES=$(( IMAGE_MB * 1024 * 1024 ))
    PART_START_SECTOR=2048          # 1 MiB gap (standard for SD cards)
    PART_START_BYTES=$(( PART_START_SECTOR * 512 ))
    PART_SIZE_BYTES=$(( IMAGE_BYTES - PART_START_BYTES ))
    PART_SIZE_SECTORS=$(( PART_SIZE_BYTES / 512 ))

    # ── Blank image ───────────────────────────────────────────────────────────
    dd if=/dev/zero of=$IMG bs=1M count=$IMAGE_MB 2>/dev/null

    # ── MBR partition table ───────────────────────────────────────────────────
    python3 - $PART_START_SECTOR $PART_SIZE_SECTORS << 'PYEOF'
import struct, sys, os

start = int(sys.argv[1])
size  = int(sys.argv[2])

def chs(lba):
    c = min(lba // (255 * 63), 1023)
    h = (lba // 63) % 255
    s = (lba %  63) + 1
    return bytes([h & 0xFF, (s & 0x3F) | ((c >> 2) & 0xC0), c & 0xFF])

entry = struct.pack('<B3sB3sII',
    0x00, chs(start), 0x83, chs(start + size - 1), start, size)
mbr = b'\x00' * 446 + entry + b'\x00' * 48 + b'\x55\xAA'

fd = os.open('mbr.bin', os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
os.write(fd, mbr)
os.close(fd)
PYEOF
    dd if=mbr.bin of=$IMG bs=1 conv=notrunc 2>/dev/null

    # ── Stage rootfs + kernel + DTB + extlinux.conf ───────────────────────────
    cp -r ${config.system.build.rootfs} staging
    chmod -R u+w staging

    ${lib.optionalString (config.device.kernel != null) ''
      cp ${config.device.kernel} staging/${kernelFile}
    ''}

    ${lib.optionalString (config.device.dtb != null) ''
      cp ${config.device.dtb} staging/${config.device.name}.dtb
    ''}

    mkdir -p staging/extlinux
    cat > staging/extlinux/extlinux.conf << EXTEOF
LABEL linux
  KERNEL /${kernelFile}
${lib.optionalString (config.device.dtb != null)
  "  FDT /${config.device.name}.dtb"}
  APPEND ${config.boot.cmdline}
EXTEOF

    # ── Build ext4 partition from staging directory ───────────────────────────
    # mkfs.ext4 -d populates the filesystem without mounting — sandbox-safe.
    dd if=/dev/zero of=part.img bs=1 count=0 seek=$PART_SIZE_BYTES 2>/dev/null
    mkfs.ext4 \
      -d staging \
      -L rootfs \
      -E lazy_itable_init=0,lazy_journal_init=0 \
      part.img

    # ── Embed partition into disk image ───────────────────────────────────────
    dd if=part.img of=$IMG bs=512 seek=$PART_START_SECTOR conv=notrunc 2>/dev/null
  '';
}
