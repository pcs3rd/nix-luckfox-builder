# Flashable SD image for Luckfox Pico Mini B (Rockchip RV1103).
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
# ── A/B layout with squashfs + overlayfs (A/B enabled) ───────────────────────
#
#   Offset 0x000 (sector     0) : MBR + partition table (4 entries)
#   Offset 0x200 (byte      512): slot indicator byte ('a')
#   Offset 0x020 (sector    64) : Rockchip SPL / idbloader  ← if provided
#   Offset 0x800 00 (sec 16384) : U-Boot proper              ← if provided
#
#   Partition 1  (ext4,     label: "boot")    — kernel + initramfs + boot.scr
#   Partition 2  (squashfs, no label)         — slot A rootfs  (read-only)
#   Partition 3  (squashfs, no label)         — slot B rootfs  (read-only)
#   Partition 4  (ext4,     label: "persist") — overlayfs upper/work dirs
#
#   boot.scr (U-Boot script bootmeth, sole boot path): loads kernel + initramfs
#   from p1 with explicit 64 MB-safe load addresses; no extlinux.conf is written
#   so U-Boot falls through from extlinux (seq 1) to script (seq 2) every time.
#   The initramfs reads the slot indicator byte, mounts the active squashfs slot,
#   overlays the persist partition, and switch_root's into the result.
#
# macOS-compatible: uses mkfs.ext4 -d to populate filesystems from a directory
# tree — no losetup or mount required.

{ pkgs, config, lib, ... }:

let
  rootfs = config.system.build.rootfs;
  # Gate bootloader blobs on enable so QEMU builds (boot.uboot.enable = false)
  # do not write SPL/U-Boot into the disk image.  Both offsets (sector 64 and
  # sector 16384) fall inside partition 1 when it starts at sector 4096, so
  # writing them for a QEMU image would corrupt the filesystem.
  spl    = if config.boot.uboot.enable then config.boot.uboot.spl    else null;
  uboot  = if config.boot.uboot.enable then config.boot.uboot.package else null;
  abCfg  = config.system.abRootfs;

  # Sector at which partition 1 starts (2 MiB = 4096 × 512 B sectors).
  partStartSector = 4096;

  # ── U-Boot boot script (A/B mode) ────────────────────────────────────────
  # Written to the ext4 boot partition (p1) as boot.scr (a compiled U-Boot
  # script image).  U-Boot's distro_bootcmd finds and executes it.
  #
  # Load addresses for 64 MB DRAM (base 0x40000000):
  #
  #   0x40200000  kernel_addr_r    (2 MB above base — avoids SPL/U-Boot area)
  #   0x41E00000  fdt_addr_r       (30 MB above base — a few KB, between K+R)
  #   0x42000000  ramdisk_addr_r   (32 MB above base — 32 MB for initramfs)
  #
  # Robustness: we try two load strategies so the script works with any
  # Rockchip U-Boot (ours or the Ubuntu demo's), regardless of whether
  # distro_bootcmd sets devtype/devnum/distro_bootpart:
  #
  #   Strategy A — distro_bootcmd variables (set when called via script bootmeth)
  #   Strategy B — hardcoded mmc 0:1 (SD card, partition 1; always correct on Mini A)
  #
  # The 'if' command tests whether devtype is already set.  If not, we fall
  # through to the hardcoded mmc 0:1 path.  Either way, the same files are
  # loaded at the same addresses and bootz is called identically.
  abBootScript = pkgs.writeText "ab-boot-script.txt" ''
    echo "=== nix-luckfox A/B boot ==="
    setenv kernel_addr_r  0x40200000
    setenv fdt_addr_r     0x41E00000
    setenv ramdisk_addr_r 0x42000000
    setenv bootargs "${config.boot.cmdline}"

    ${if config.device.dtb != null then ''
      # Strategy A: distro_bootcmd variables (script bootmeth path)
      if test -n "''${devtype}"; then
        echo "Loading via distro vars: ''${devtype} ''${devnum}:''${distro_bootpart}"
        ext4load ''${devtype} ''${devnum}:''${distro_bootpart} ''${kernel_addr_r}  /zImage
        ext4load ''${devtype} ''${devnum}:''${distro_bootpart} ''${fdt_addr_r}     /${config.device.name}.dtb
        ext4load ''${devtype} ''${devnum}:''${distro_bootpart} ''${ramdisk_addr_r} /initramfs-slotselect.cpio.gz
      else
        # Strategy B: hardcoded mmc 1:1
        # On RV1103/Luckfox Mini A: mmc@ffa90000 = slot 0 (empty internal),
        # mmc@ffaa0000 = slot 1 (SD card).  The SD card is ALWAYS mmc 1.
        echo "Loading via mmc 1:1 (no distro vars set)"
        ext4load mmc 1:1 ''${kernel_addr_r}  /zImage
        ext4load mmc 1:1 ''${fdt_addr_r}     /${config.device.name}.dtb
        ext4load mmc 1:1 ''${ramdisk_addr_r} /initramfs-slotselect.cpio.gz
      fi
      echo "bootargs: ''${bootargs}"
      bootz ''${kernel_addr_r} ''${ramdisk_addr_r}:''${filesize} ''${fdt_addr_r}
    '' else ''
      # QEMU path (no board DTB): use the FDT passed by QEMU to U-Boot.
      # Copy it to fdt_addr_r first — fdtcontroladdr is inside U-Boot's
      # relocated region which the LMB allocator already owns, and bootz
      # would fail trying to reserve it a second time.
      if test -n "''${devtype}"; then
        echo "Loading via distro vars: ''${devtype} ''${devnum}:''${distro_bootpart}"
        ext4load ''${devtype} ''${devnum}:''${distro_bootpart} ''${kernel_addr_r}  /zImage
        ext4load ''${devtype} ''${devnum}:''${distro_bootpart} ''${ramdisk_addr_r} /initramfs-slotselect.cpio.gz
      else
        echo "Loading via mmc 1:1"
        ext4load mmc 1:1 ''${kernel_addr_r}  /zImage
        ext4load mmc 1:1 ''${ramdisk_addr_r} /initramfs-slotselect.cpio.gz
      fi
      echo "bootargs: ''${bootargs}"
      fdt move ''${fdtcontroladdr} ''${fdt_addr_r} 0x100000
      bootz ''${kernel_addr_r} ''${ramdisk_addr_r}:''${filesize} ''${fdt_addr_r}
    ''}
  '';
in

{
  config.system.build.sdImage = pkgs.runCommand "sd-flashable" {
    nativeBuildInputs = with pkgs.buildPackages; [
      e2fsprogs   # mkfs.ext4 with -d flag
      python3     # MBR partition-table writer
      ubootTools  # mkimage — compiles the A/B boot script
    ] ++ lib.optionals abCfg.enable [
      squashfsTools  # mksquashfs for slot images (via rootfsPartition)
    ];
  } ''
    mkdir -p $out
    IMAGE_MB=${toString config.system.imageSize}
    SECTOR=${toString partStartSector}
    IMAGE_BYTES=$(( IMAGE_MB * 1024 * 1024 ))
    TOTAL_SECTORS=$(( IMAGE_BYTES / 512 ))

    echo "Building flashable SD image (''${IMAGE_MB} MiB)..."

    # ── Blank image ─────────────────────────────────────────────────────────
    dd if=/dev/zero of=$out/sd-flashable.img bs=1M count=$IMAGE_MB 2>/dev/null

    ${if abCfg.enable then ''
    # ── A/B: squashfs slots + separate boot and persist partitions ───────────
    #
    # Fixed partition layout (sizes in sectors, 1 sector = 512 bytes):
    #   p1 = boot (ext4):    kernel + initramfs + boot.scr
    #   p2 = slot A (squashfs, raw)
    #   p3 = slot B (squashfs, raw)
    #   p4 = persist (ext4): overlayfs upper/work dirs

    BOOT_SIZE_SECTORS=$(( ${toString abCfg.bootPartSize} * 2048 ))
    PERSIST_SIZE_SECTORS=$(( ${toString abCfg.persistSize} * 2048 ))
    AVAILABLE_SECTORS=$(( TOTAL_SECTORS - SECTOR ))
    SLOT_SIZE_SECTORS=$(( (AVAILABLE_SECTORS - BOOT_SIZE_SECTORS - PERSIST_SIZE_SECTORS) / 2 ))

    BOOT_START=$SECTOR
    SLOT_A_START=$(( BOOT_START  + BOOT_SIZE_SECTORS   ))
    SLOT_B_START=$(( SLOT_A_START + SLOT_SIZE_SECTORS   ))
    PERSIST_START=$(( SLOT_B_START + SLOT_SIZE_SECTORS  ))

    echo "boot:    sectors $BOOT_START–$(( SLOT_A_START - 1 ))  ($(( BOOT_SIZE_SECTORS / 2048 )) MiB)"
    echo "slot A:  sectors $SLOT_A_START–$(( SLOT_B_START - 1 ))  ($(( SLOT_SIZE_SECTORS / 2048 )) MiB)"
    echo "slot B:  sectors $SLOT_B_START–$(( PERSIST_START - 1 ))  ($(( SLOT_SIZE_SECTORS / 2048 )) MiB)"
    echo "persist: sectors $PERSIST_START–$(( PERSIST_START + PERSIST_SIZE_SECTORS - 1 ))  ($(( PERSIST_SIZE_SECTORS / 2048 )) MiB)"

    # Write slot indicator byte 'a' at the reserved raw disk offset
    printf 'a' | dd of=$out/sd-flashable.img bs=1 seek=${toString abCfg.slotOffset} conv=notrunc 2>/dev/null

    # MBR with four partition entries
    python3 - $BOOT_START $BOOT_SIZE_SECTORS $SLOT_SIZE_SECTORS $PERSIST_SIZE_SECTORS << 'PYEOF'
import struct, sys

boot_start   = int(sys.argv[1])
boot_size    = int(sys.argv[2])
slot_size    = int(sys.argv[3])
persist_size = int(sys.argv[4])

slot_a_start  = boot_start + boot_size
slot_b_start  = slot_a_start + slot_size
persist_start = slot_b_start + slot_size

def chs(lba):
    c = min(lba // (255 * 63), 1023)
    h = (lba // 63) % 255
    s = (lba %  63) + 1
    return bytes([h & 0xFF, (s & 0x3F) | ((c >> 2) & 0xC0), c & 0xFF])

def part_entry(start, size, ptype=0x83):
    return struct.pack('<B3sB3sII',
        0x00,
        chs(start),
        ptype,
        chs(start + size - 1),
        start,
        size,
    )

mbr = (b'\x00' * 446
       + part_entry(boot_start,   boot_size)    # p1: ext4 boot
       + part_entry(slot_a_start, slot_size)    # p2: squashfs slot A
       + part_entry(slot_b_start, slot_size)    # p3: squashfs slot B
       + part_entry(persist_start, persist_size) # p4: ext4 persist
       + b'\x55\xAA')

import os
fd = os.open('mbr.bin', os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
os.write(fd, mbr)
os.close(fd)
PYEOF

    dd if=mbr.bin of=$out/sd-flashable.img bs=1 conv=notrunc 2>/dev/null

    # ── Build boot partition (p1): kernel + initramfs + boot.scr ────────────
    #
    # No extlinux/extlinux.conf is created here.  U-Boot 2026.01 scans boot
    # methods in priority order: extlinux (seq 1) beats script/boot.scr (seq 2).
    # If extlinux.conf is present, U-Boot uses it and applies its default
    # ramdisk_addr_r (0x44000000 on QEMU ARM) — exactly at the 64 MB boundary —
    # causing a virtio DMA fault before the kernel even starts.
    #
    # boot.scr (script bootmeth) explicitly sets 64 MB-safe load addresses:
    #   kernel_addr_r  0x40200000
    #   fdt_addr_r     0x41E00000
    #   ramdisk_addr_r 0x42000000
    # Keeping extlinux.conf absent forces U-Boot to fall through to boot.scr.
    mkdir -p boot-staging

    ${lib.optionalString (config.device.kernel != null) ''
      cp ${config.device.kernel} boot-staging/zImage
    ''}
    ${lib.optionalString (config.device.dtb != null) ''
      cp ${config.device.dtb} boot-staging/${config.device.name}.dtb
    ''}

    # Slot-select initramfs handles squashfs mount + overlay setup.
    cp ${config.system.build.slotSelectInitramfs}/initramfs-slotselect.cpio.gz \
       boot-staging/initramfs-slotselect.cpio.gz

    # Compiled U-Boot boot script — the sole boot path for A/B images.
    mkimage -A arm -O linux -T script -C none -a 0 -e 0 \
      -n "A/B squashfs boot" -d ${abBootScript} boot-staging/boot.scr

    BOOT_SIZE_BYTES=$(( BOOT_SIZE_SECTORS * 512 ))
    truncate -s $BOOT_SIZE_BYTES boot.img
    mkfs.ext4 \
      -d boot-staging \
      -L ${abCfg.bootPartLabel} \
      -E lazy_itable_init=0,lazy_journal_init=0 \
      boot.img

    dd if=boot.img of=$out/sd-flashable.img bs=512 seek=$BOOT_START conv=notrunc 2>/dev/null
    echo "boot partition written ($(du -sh boot.img | cut -f1))"

    # ── Write squashfs slot A (p2) and slot B (p3) ───────────────────────────
    # The squashfs image is written directly to the raw partition.
    # mount -t squashfs /dev/vda2 /mnt works because squashfs is a block-level
    # filesystem — no loop device or filesystem label needed.
    SQUASHFS=${config.system.build.rootfsPartition}/rootfs.squashfs
    SQUASHFS_BYTES=$(wc -c < "$SQUASHFS")
    SLOT_SIZE_BYTES=$(( SLOT_SIZE_SECTORS * 512 ))

    if [ "$SQUASHFS_BYTES" -gt "$SLOT_SIZE_BYTES" ]; then
      echo "ERROR: squashfs ($SQUASHFS_BYTES bytes) exceeds slot size ($SLOT_SIZE_BYTES bytes)" >&2
      echo "Increase system.imageSize in your configuration." >&2
      exit 1
    fi

    echo "slot A squashfs: $(du -sh $SQUASHFS | cut -f1)  →  partition 2 ($(( SLOT_SIZE_BYTES / 1024 / 1024 )) MiB)"
    dd if=$SQUASHFS of=$out/sd-flashable.img bs=512 seek=$SLOT_A_START conv=notrunc 2>/dev/null

    echo "slot B squashfs: copying same image → partition 3"
    dd if=$SQUASHFS of=$out/sd-flashable.img bs=512 seek=$SLOT_B_START conv=notrunc 2>/dev/null

    # ── Format persist partition (p4) as ext4 ────────────────────────────────
    PERSIST_SIZE_BYTES=$(( PERSIST_SIZE_SECTORS * 512 ))
    truncate -s $PERSIST_SIZE_BYTES persist.img
    mkfs.ext4 \
      -L ${abCfg.persistLabel} \
      -E lazy_itable_init=0,lazy_journal_init=0 \
      persist.img

    dd if=persist.img of=$out/sd-flashable.img bs=512 seek=$PERSIST_START conv=notrunc 2>/dev/null
    echo "persist partition written ($(( PERSIST_SIZE_BYTES / 1024 / 1024 )) MiB ext4, label: ${abCfg.persistLabel})"

    '' else ''
    # ── Single partition ─────────────────────────────────────────────────────
    AVAILABLE_SECTORS=$(( TOTAL_SECTORS - SECTOR ))
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

    mkdir -p staging/extlinux
    cat > staging/extlinux/extlinux.conf << EXTEOF
LABEL linux
  KERNEL /zImage
${lib.optionalString (config.device.dtb != null)
  "  FDT /${config.device.name}.dtb"}
  APPEND ${config.boot.cmdline}
EXTEOF

    # mkfs.ext4 -d populates the filesystem without needing to mount anything —
    # safe on macOS and in the Nix sandbox.
    # Use truncate to create a sparse file of exactly PART_SIZE_BYTES.
    truncate -s $PART_SIZE_BYTES part1.img
    mkfs.ext4 \
      -d staging \
      -L rootfs \
      -E lazy_itable_init=0,lazy_journal_init=0 \
      part1.img

    dd if=part1.img of=$out/sd-flashable.img bs=512 seek=$SECTOR conv=notrunc 2>/dev/null

    ''}

    # ── Write Rockchip bootloader blobs ─────────────────────────────────────
    # SPL / idbloader at sector 64 (Rockchip boot ROM requirement).
    # Sector 64 = 32 KiB, well before partition 1 which starts at sector 4096 = 2 MiB.
    ${lib.optionalString (spl != null) ''
      echo "Writing SPL at sector 64..."
      dd if=${spl} of=$out/sd-flashable.img bs=512 seek=64 conv=notrunc 2>/dev/null
    ''}

    # U-Boot proper at sector 16384 (8 MiB).
    # NOTE: sector 16384 (8 MiB) is INSIDE partition 1 when it starts at sector 4096
    # and is larger than 6 MiB.  For QEMU builds boot.uboot.enable must be false.
    ${lib.optionalString (uboot != null) ''
      echo "Writing U-Boot at sector 16384..."
      dd if=${uboot} of=$out/sd-flashable.img bs=512 seek=16384 conv=notrunc 2>/dev/null
    ''}

    echo "SD image ready: $out/sd-flashable.img"
    echo "Flash with: dd if=$out/sd-flashable.img of=/dev/sdX bs=4M status=progress"
    ${lib.optionalString abCfg.enable ''
    echo "A/B layout: boot=p1(ext4)  slot-A=p2(squashfs)  slot-B=p3(squashfs)  persist=p4(ext4)"
    echo "Slot indicator byte 'a' written at byte offset ${toString abCfg.slotOffset}"
    ''}
  '';
}
