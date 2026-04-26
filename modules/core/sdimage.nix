# Flashable SD image for Luckfox Pico Mini B (Rockchip RV1103) and
# Pine64 Ox64 (BL808 RISC-V).
#
# Produces a raw disk image that can be written directly to an SD card:
#
#   dd if=result/sd-flashable.img of=/dev/sdX bs=4M status=progress
#
# ── Single-partition layout (A/B disabled) ───────────────────────────────────
#
#   Offset 0x000 (sector     0) : MBR + partition table
#   Offset 0x020 (sector    64) : Rockchip SPL / idbloader  ← if provided
#   Offset 0x800 00 (sec 16384) : U-Boot proper              ← if provided
#   Offset 0x100 000  (2 MiB)  : ext4 rootfs (partition 1)
#
# ── A/B dual-partition layout (A/B enabled) ──────────────────────────────────
#
#   Offset 0x000 (sector     0) : MBR + partition table
#   Offset 0x200 (byte      512): slot indicator byte ('a')  ← written here
#   Offset 0x020 (sector    64) : Rockchip SPL / idbloader  ← if provided
#   Offset 0x800 00 (sec 16384) : U-Boot proper              ← if provided
#   Offset 0x100 000  (2 MiB)  : ext4 rootfs A (partition 1) ← kernel + boot.scr + rootfs
#   Following p1               : ext4 rootfs B (partition 2) ← rootfs only
#
#   boot.scr (U-Boot distro boot, primary path): reads raw sector 1, sets
#   root=LABEL=rootfs-{a,b}, loads kernel — device-agnostic (mmc or virtio).
#   extlinux.conf (fallback): references the slot-select initramfs, which
#   mounts the active partition and switch_root's into it.
#
# macOS-compatible: uses mkfs.ext4 -d to populate the filesystem from a
# directory — no losetup or mount required.

{ pkgs, config, lib, ... }:

let
  rootfs = config.system.build.rootfs;
  # Gate bootloader blobs on enable so QEMU builds (boot.uboot.enable = false)
  # do not write SPL/U-Boot into the disk image.  Both offsets (sector 64 and
  # sector 16384) fall inside partition 1 when it starts at sector 4096, so
  # writing them for a QEMU image would corrupt the ext4 filesystem.
  spl    = if config.boot.uboot.enable then config.boot.uboot.spl    else null;
  uboot  = if config.boot.uboot.enable then config.boot.uboot.package else null;
  abCfg  = config.system.abRootfs;

  # Sector at which partition 1 starts (2 MiB = 4096 × 512 B sectors).
  partStartSector = 4096;

  # ── U-Boot A/B slot-select boot script ───────────────────────────────────
  # Compiled with mkimage and placed at /boot.scr in partition 1.
  # U-Boot's distro_bootcmd finds it before extlinux.conf and runs it directly.
  #
  # Uses distro_bootcmd environment variables for portability:
  #   ${devtype}          — "mmc"    (real hardware)  or "virtio" (QEMU)
  #   ${devnum}           — device index (0 for the first device)
  #   ${distro_bootpart}  — partition where boot.scr was found (1)
  #
  # The slot indicator byte at raw sector 1 ('a' or 'b') is read directly
  # by U-Boot before the kernel starts — no initramfs needed for slot select.
  abBootScript = pkgs.writeText "ab-boot-script.txt" ''
    ''${devtype} read ''${loadaddr} 1 1
    if itest.b *''${loadaddr} == 0x62; then
        echo "A/B: slot B active  (${abCfg.slotLabelB})"
        setenv rootlabel ${abCfg.slotLabelB}
    else
        echo "A/B: slot A active  (${abCfg.slotLabelA})"
        setenv rootlabel ${abCfg.slotLabelA}
    fi
    setenv bootargs "${config.boot.cmdline} root=LABEL=''${rootlabel} rootwait rw"
    echo "bootargs: ''${bootargs}"
    ext4load ''${devtype} ''${devnum}:''${distro_bootpart} ''${kernel_addr_r} /zImage
    ${lib.optionalString (config.device.dtb != null) ''
      ext4load ''${devtype} ''${devnum}:''${distro_bootpart} ''${fdt_addr_r} /${config.device.name}.dtb
    ''}bootz ''${kernel_addr_r} - ''${fdt_addr_r}
  '';
in

{
  config.system.build.sdImage = pkgs.runCommand "sd-flashable" {
    nativeBuildInputs = with pkgs.buildPackages; [
      e2fsprogs   # mkfs.ext4 with -d flag
      python3     # MBR partition-table writer
      ubootTools  # mkimage — compiles the A/B boot script
    ];
  } ''
    mkdir -p $out
    IMAGE_MB=${toString config.system.imageSize}
    SECTOR=${toString partStartSector}
    IMAGE_BYTES=$(( IMAGE_MB * 1024 * 1024 ))
    TOTAL_SECTORS=$(( IMAGE_BYTES / 512 ))
    AVAILABLE_SECTORS=$(( TOTAL_SECTORS - SECTOR ))

    echo "Building flashable SD image (''${IMAGE_MB} MiB)..."

    # ── Blank image ─────────────────────────────────────────────────────────
    dd if=/dev/zero of=$out/sd-flashable.img bs=1M count=$IMAGE_MB 2>/dev/null

    ${if abCfg.enable then ''
    # ── A/B: two equal-size rootfs partitions ───────────────────────────────
    PART_SIZE_SECTORS=$(( AVAILABLE_SECTORS / 2 ))
    PART_SIZE_BYTES=$(( PART_SIZE_SECTORS * 512 ))
    PART2_START=$(( SECTOR + PART_SIZE_SECTORS ))

    echo "A/B mode: each partition = ''${PART_SIZE_SECTORS} sectors ($(( PART_SIZE_BYTES / 1024 / 1024 )) MiB)"

    # Write slot indicator byte 'a' at sector 1 (byte offset 512)
    printf 'a' | dd of=$out/sd-flashable.img bs=1 seek=${toString abCfg.slotOffset} conv=notrunc 2>/dev/null

    # MBR with two partition entries
    python3 - $SECTOR $PART_SIZE_SECTORS $PART2_START << 'PYEOF'
import struct, sys

start1 = int(sys.argv[1])
size   = int(sys.argv[2])
start2 = int(sys.argv[3])

def chs(lba):
    c = min(lba // (255 * 63), 1023)
    h = (lba // 63) % 255
    s = (lba %  63) + 1
    return bytes([h & 0xFF, (s & 0x3F) | ((c >> 2) & 0xC0), c & 0xFF])

def part_entry(start, size):
    return struct.pack('<B3sB3sII',
        0x00,
        chs(start),
        0x83,  # Linux filesystem
        chs(start + size - 1),
        start,
        size,
    )

mbr = (b'\x00' * 446
       + part_entry(start1, size)
       + part_entry(start2, size)
       + b'\x00' * 32
       + b'\x55\xAA')

import os
fd = os.open('mbr.bin', os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
os.write(fd, mbr)
os.close(fd)
PYEOF

    '' else ''
    # ── Single partition ─────────────────────────────────────────────────────
    PART_SIZE_SECTORS=$AVAILABLE_SECTORS
    PART_SIZE_BYTES=$(( PART_SIZE_SECTORS * 512 ))

    # MBR with one partition entry
    python3 - $SECTOR $PART_SIZE_SECTORS << 'PYEOF'
import struct, sys

start = int(sys.argv[1])
size  = int(sys.argv[2])

def chs(lba):
    c = min(lba // (255 * 63), 1023)
    h = (lba // 63) % 255
    s = (lba %  63) + 1
    return bytes([h & 0xFF, (s & 0x3F) | ((c >> 2) & 0xC0), c & 0xFF])

entry = struct.pack('<B3sB3sII',
    0x00,
    chs(start),
    0x83,
    chs(start + size - 1),
    start,
    size,
)
mbr = b'\x00' * 446 + entry + b'\x00' * 48 + b'\x55\xAA'

import os
fd = os.open('mbr.bin', os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
os.write(fd, mbr)
os.close(fd)
PYEOF

    ''}
    dd if=mbr.bin of=$out/sd-flashable.img bs=1 conv=notrunc 2>/dev/null

    # ── Stage rootfs + kernel + DTB + extlinux.conf ─────────────────────────
    cp -r ${rootfs} staging
    chmod -R u+w staging

    ${lib.optionalString (config.device.kernel != null) ''
      cp ${config.device.kernel} staging/zImage
    ''}

    ${lib.optionalString (config.device.dtb != null) ''
      cp ${config.device.dtb} staging/${config.device.name}.dtb
    ''}

    ${lib.optionalString abCfg.enable ''
      # Copy slot-select initramfs (extlinux.conf fallback path).
      cp ${config.system.build.slotSelectInitramfs}/initramfs-slotselect.cpio.gz \
         staging/initramfs-slotselect.cpio.gz

      # Compile U-Boot boot script (primary A/B boot path).
      # U-Boot distro_bootcmd finds boot.scr before extlinux.conf, reads the
      # raw slot indicator byte from sector 1, and boots the active partition
      # without needing an initramfs — works on both MMC and virtio (QEMU).
      mkimage -A arm -O linux -T script -C none -a 0 -e 0 \
        -n "A/B slot select" -d ${abBootScript} staging/boot.scr
    ''}

    mkdir -p staging/extlinux
    cat > staging/extlinux/extlinux.conf << EXTEOF
LABEL linux
  KERNEL /zImage
${lib.optionalString (config.device.dtb != null)
  "  FDT /${config.device.name}.dtb"}
${lib.optionalString abCfg.enable
  "  INITRD /initramfs-slotselect.cpio.gz"}
  APPEND ${config.boot.cmdline}
EXTEOF

    # ── Build ext4 partition 1 image from staging directory ─────────────────
    # mkfs.ext4 -d populates the filesystem in-place from a directory tree,
    # without needing to mount anything — safe on macOS and in the Nix sandbox.
    #
    # Use truncate to create a sparse file of exactly PART_SIZE_BYTES.
    # "dd bs=1 count=0 seek=N" is NOT equivalent — on Linux, GNU dd with
    # count=0 transfers nothing and does NOT extend the output file to the
    # seek position, leaving a 0-byte file.  truncate is unambiguous.
    truncate -s $PART_SIZE_BYTES part1.img
    mkfs.ext4 \
      -d staging \
      -L rootfs-a \
      -E lazy_itable_init=0,lazy_journal_init=0 \
      part1.img

    # ── Embed partition 1 into disk image ────────────────────────────────────
    dd if=part1.img of=$out/sd-flashable.img bs=512 seek=$SECTOR conv=notrunc 2>/dev/null

    ${if abCfg.enable then ''
    # ── Build ext4 partition 2 (slot B — rootfs only, no kernel) ────────────
    # Slot B only needs the rootfs; the bootloader always loads the kernel
    # from slot A (partition 1).  Staged without kernel/DTB/extlinux/initramfs.
    cp -r ${rootfs} staging-b
    chmod -R u+w staging-b

    truncate -s $PART_SIZE_BYTES part2.img
    mkfs.ext4 \
      -d staging-b \
      -L rootfs-b \
      -E lazy_itable_init=0,lazy_journal_init=0 \
      part2.img

    dd if=part2.img of=$out/sd-flashable.img bs=512 seek=$PART2_START conv=notrunc 2>/dev/null
    '' else ""}

    # ── Write Rockchip bootloader blobs ─────────────────────────────────────
    # SPL / idbloader at sector 64 (Rockchip boot ROM requirement)
    ${lib.optionalString (spl != null) ''
      echo "Writing SPL at sector 64..."
      dd if=${spl} of=$out/sd-flashable.img bs=512 seek=64 conv=notrunc 2>/dev/null
    ''}

    # U-Boot proper at sector 16384 (8 MiB)
    ${lib.optionalString (uboot != null) ''
      echo "Writing U-Boot at sector 16384..."
      dd if=${uboot} of=$out/sd-flashable.img bs=512 seek=16384 conv=notrunc 2>/dev/null
    ''}

    echo "SD image ready: $out/sd-flashable.img"
    ${if abCfg.enable then ''
    echo "A/B layout: slot A = partition 1, slot B = partition 2"
    echo "Slot indicator byte 'a' written at byte offset ${toString abCfg.slotOffset}"
    '' else ""}
    echo "Flash with: dd if=$out/sd-flashable.img of=/dev/sdX bs=4M status=progress"
  '';
}
