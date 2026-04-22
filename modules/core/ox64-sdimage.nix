# Full 2-partition SD card image for the Pine64 Ox64 (BL808).
#
# Produces a raw disk image that can be written directly to an SD card and
# booted without any additional manual steps — no OpenBouffalo sdcard.img
# base needed.
#
# ── Partition layout ─────────────────────────────────────────────────────────
#
#   p1  FAT32  ~64 MiB   boot partition
#         low_load_bl808_d0.bin   D0 (Linux core) pre-loader
#         low_load_bl808_m0.bin   M0 (RTOS/WiFi)  pre-loader
#         Image                   Linux kernel
#         bl808-pine64-ox64.dtb   device tree
#         extlinux/extlinux.conf  U-Boot boot script
#         [initramfs-slotselect.cpio.gz]  ← only with A/B enabled
#
#   p2  ext4   remainder           rootfs A  (active on first boot)
#   [p3  ext4  same size as p2]    rootfs B  ← only with A/B enabled
#
# ── How it works ─────────────────────────────────────────────────────────────
#
# FAT32 images can't use mkfs.fat -d (that flag doesn't exist) so we use
# mtools entirely — mformat creates the filesystem, mcopy populates it.
# mtools works without mounting, making this sandbox-safe on macOS and Linux.
#
# The MBR partition table is written in Python (no parted/sfdisk needed).
#
# ── When this module produces output ─────────────────────────────────────────
#
# system.build.ox64SdImage is null unless device.ox64Firmware is set.
# hardware/ox64.nix sets it automatically so:
#   nix build .#ox64-sd-image
# works after you fill in BUILDROOT_SHA256 in pkgs/ox64-firmware.nix.

{ pkgs, config, lib, ... }:

let
  cfg    = config.system.abRootfs;
  fw     = config.device.ox64Firmware;

  # FAT boot partition size: 64 MiB (pre-loaders + kernel + DTB + extlinux).
  fatMiB = 64;
  # Sector at which p1 starts (1 MiB gap, same convention as sdimage.nix).
  p1StartSector = 2048;
  fatSectors    = fatMiB * 1024 * 1024 / 512;  # = 131072

  # p2 starts right after p1.
  p2StartSector = p1StartSector + fatSectors;

  ox64SdImage = pkgs.runCommand "ox64-sdcard" {
    nativeBuildInputs = with pkgs.buildPackages; [
      mtools    # mformat + mcopy — FAT image creation without mounting
      python3   # MBR partition table writer
      e2fsprogs # mkfs.ext4 -d — ext4 image creation without mounting
    ];
  } ''
    mkdir -p $out

    IMAGE_MB=${toString config.system.imageSize}
    IMAGE_BYTES=$(( IMAGE_MB * 1024 * 1024 ))
    TOTAL_SECTORS=$(( IMAGE_BYTES / 512 ))

    P1_START=${toString p1StartSector}
    P1_SIZE=${toString fatSectors}
    P2_START=${toString p2StartSector}
    AVAILABLE=$(( TOTAL_SECTORS - P2_START ))

    ${if cfg.enable then ''
    # A/B: two equal ext4 partitions for rootfs A and B
    P2_SIZE=$(( AVAILABLE / 2 ))
    P3_START=$(( P2_START + P2_SIZE ))
    P3_SIZE=$P2_SIZE
    '' else ''
    P2_SIZE=$AVAILABLE
    ''}

    P2_BYTES=$(( P2_SIZE * 512 ))

    echo "Ox64 SD image: ''${IMAGE_MB} MiB total"
    echo "  p1 FAT32 : sector $P1_START, $P1_SIZE sectors (${toString fatMiB} MiB)"
    echo "  p2 ext4  : sector $P2_START, ''${P2_SIZE} sectors ($(( P2_BYTES / 1024 / 1024 )) MiB)"
    ${lib.optionalString cfg.enable ''
    echo "  p3 ext4  : sector $P3_START, ''${P3_SIZE} sectors (A/B slot B)"
    ''}

    # ── Blank image ────────────────────────────────────────────────────────────
    dd if=/dev/zero of=$out/ox64-sdcard.img bs=1M count=$IMAGE_MB 2>/dev/null

    # ── MBR partition table ────────────────────────────────────────────────────
    # Always pass 7 positional args; p3 fields are 0 when A/B is disabled.
    python3 - $P1_START ${toString fatSectors} $P2_START $P2_SIZE \
              ${if cfg.enable then "1" else "0"} \
              ${if cfg.enable then "$P3_START $P3_SIZE" else "0 0"} << 'PYEOF'
import struct, sys, os

p1_start = int(sys.argv[1])
p1_size  = int(sys.argv[2])
p2_start = int(sys.argv[3])
p2_size  = int(sys.argv[4])
ab_mode  = sys.argv[5] == "1"
p3_start = int(sys.argv[6])
p3_size  = int(sys.argv[7])

def chs(lba):
    c = min(lba // (255 * 63), 1023)
    h = (lba // 63) % 255
    s = (lba %  63) + 1
    return bytes([h & 0xFF, (s & 0x3F) | ((c >> 2) & 0xC0), c & 0xFF])

def entry(start, size, ptype=0x83):
    return struct.pack('<B3sB3sII',
        0x00, chs(start), ptype, chs(start + size - 1), start, size)

mbr = (b'\x00' * 446
       + entry(p1_start, p1_size, 0x0c)   # FAT32 with LBA
       + entry(p2_start, p2_size, 0x83)   # Linux ext4
       + (entry(p3_start, p3_size, 0x83) if ab_mode else b'\x00' * 16)
       + b'\x00' * (16 if ab_mode else 32)
       + b'\x55\xAA')

fd = os.open('mbr.bin', os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
os.write(fd, mbr)
os.close(fd)
PYEOF
    dd if=mbr.bin of=$out/ox64-sdcard.img bs=1 conv=notrunc 2>/dev/null

    ${lib.optionalString cfg.enable ''
    # Write A/B slot indicator byte 'a' at byte 512 (sector 1).
    printf 'a' | dd of=$out/ox64-sdcard.img bs=1 seek=${toString cfg.slotOffset} conv=notrunc 2>/dev/null
    ''}

    # ── Build FAT32 boot partition ─────────────────────────────────────────────
    # mformat creates a FAT32 filesystem in a raw file — no mount needed.
    # Use -T (total sectors) so mtools doesn't need a cylinder-aligned size.
    dd if=/dev/zero of=fat.img bs=512 count=${toString fatSectors} 2>/dev/null
    export MTOOLS_SKIP_CHECK=1
    mformat -i fat.img -F -T ${toString fatSectors} ::

    # Copy pre-loaders
    mcopy -i fat.img ${fw}/low_load_bl808_d0.bin ::low_load_bl808_d0.bin
    mcopy -i fat.img ${fw}/low_load_bl808_m0.bin ::low_load_bl808_m0.bin

    # Copy kernel and DTB
    mcopy -i fat.img ${fw}/Image ::Image
    mcopy -i fat.img ${fw}/bl808-pine64-ox64.dtb ::bl808-pine64-ox64.dtb

    # extlinux.conf
    mkdir -p extlinux
    cat > extlinux/extlinux.conf << EXTEOF
LABEL linux
  KERNEL /Image
  FDT /bl808-pine64-ox64.dtb
${lib.optionalString cfg.enable "  INITRD /initramfs-slotselect.cpio.gz"}
  APPEND ${config.boot.cmdline}
EXTEOF
    mmd -i fat.img ::extlinux
    mcopy -i fat.img extlinux/extlinux.conf ::extlinux/extlinux.conf

    ${lib.optionalString cfg.enable ''
    # Copy slot-select initramfs into the FAT boot partition.
    mcopy -i fat.img \
      ${config.system.build.slotSelectInitramfs}/initramfs-slotselect.cpio.gz \
      ::initramfs-slotselect.cpio.gz
    ''}

    echo "FAT boot partition contents:"
    mdir -i fat.img -/ 2>&1 || true

    # ── Embed FAT partition into image ─────────────────────────────────────────
    dd if=fat.img of=$out/ox64-sdcard.img bs=512 seek=$P1_START conv=notrunc 2>/dev/null

    # ── Build ext4 rootfs partition (slot A / only slot) ──────────────────────
    cp -r ${config.system.build.rootfs} staging-a
    chmod -R u+w staging-a

    dd if=/dev/zero of=part-a.img bs=1 count=0 seek=$P2_BYTES 2>/dev/null
    mkfs.ext4 \
      -d staging-a \
      -L rootfs${lib.optionalString cfg.enable "-a"} \
      -E lazy_itable_init=0,lazy_journal_init=0 \
      part-a.img

    dd if=part-a.img of=$out/ox64-sdcard.img bs=512 seek=$P2_START conv=notrunc 2>/dev/null

    ${lib.optionalString cfg.enable ''
    # ── Build ext4 rootfs partition (slot B) ──────────────────────────────────
    cp -r ${config.system.build.rootfs} staging-b
    chmod -R u+w staging-b

    dd if=/dev/zero of=part-b.img bs=1 count=0 seek=$P2_BYTES 2>/dev/null
    mkfs.ext4 \
      -d staging-b \
      -L rootfs-b \
      -E lazy_itable_init=0,lazy_journal_init=0 \
      part-b.img

    dd if=part-b.img of=$out/ox64-sdcard.img bs=512 seek=$P3_START conv=notrunc 2>/dev/null
    ''}

    echo "Ox64 SD image ready: $out/ox64-sdcard.img"
    echo "Flash with: dd if=$out/ox64-sdcard.img of=/dev/sdX bs=4M status=progress"
  '';

in

{
  # Only expose the output when firmware is wired up.
  config.system.build.ox64SdImage =
    if fw != null then ox64SdImage else null;
}
