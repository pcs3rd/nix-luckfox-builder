{ pkgs, config, lib, ... }:

let
  # All tools here must run on the BUILD machine, not the target.
  build = pkgs.buildPackages;

  # ── rootfs.img (ext4, macOS-compatible — no losetup required) ────────────
  rootfsImg = pkgs.runCommand "rootfs.img" {
    nativeBuildInputs = [ build.e2fsprogs ];
  } ''
    SIZE_BYTES=$(( ${toString config.system.imageSize} * 1024 * 1024 ))
    truncate -s $SIZE_BYTES $out
    mkfs.ext4 -d ${config.system.build.rootfs} -L rootfs $out
  '';

  # ── env.img (U-Boot environment, 32 KiB) ─────────────────────────────────
  envImg =
    if config.boot.uboot.env == {}
    then
      # No env vars — write a blank (0xFF-filled) env image so the flash
      # layout is complete even without a configured environment.
      pkgs.runCommand "env.img" {} ''
        # U-Boot env flash is typically 0xFF-erased; dd zero is fine for SD.
        dd if=/dev/zero bs=32768 count=1 > $out
      ''
    else
      pkgs.runCommand "env.img" {
        nativeBuildInputs = [ build.ubootTools ];
      } ''
        cat > env.txt << 'ENVEOF'
${lib.concatStringsSep "\n" (lib.mapAttrsToList (k: v: "${k}=${v}") config.boot.uboot.env)}
ENVEOF
        mkenvimage -s 32768 -o $out env.txt
      '';

  # ── empty ext4 partition helper ───────────────────────────────────────────
  emptyExt4 = label: sizeMB:
    pkgs.runCommand "${label}.img" {
      nativeBuildInputs = [ build.e2fsprogs ];
    } ''
      truncate -s ${toString sizeMB}M $out
      mkfs.ext4 -L ${label} $out
    '';

in {
  # ── Firmware package ───────────────────────────────────────────────────────
  #
  # Produces a directory containing every image needed to flash a Luckfox
  # Pico Mini B, mirroring the layout from the upstream SDK:
  #
  #   SPL           — Rockchip secondary program loader
  #   uboot.img     — U-Boot main binary
  #   env.img       — U-Boot environment (32 KiB)
  #   boot.img      — Kernel zImage (when device.kernel is set)
  #   rootfs.img    — ext4 root filesystem
  #   oem.img       — OEM partition (empty placeholder)
  #   userdata.img  — User-data partition (empty placeholder)
  #   parameter.txt — Rockchip partition layout descriptor
  #   sd_update.txt — SD card dd-flash script
  #   tftp_update.txt — U-Boot TFTP flash instructions
  #   manifest.txt  — Build metadata
  #
  config.system.build.firmware = pkgs.runCommand "firmware-package" {
    nativeBuildInputs = [ build.e2fsprogs ];
  } ''
    mkdir -p $out

    # ── rootfs.img ─────────────────────────────────────────────────────────
    cp ${rootfsImg} $out/rootfs.img

    # ── U-Boot binaries ────────────────────────────────────────────────────
    ${lib.optionalString config.boot.uboot.enable ''
      ${lib.optionalString (config.boot.uboot.spl != null) ''
        cp ${config.boot.uboot.spl} $out/SPL
      ''}
      ${lib.optionalString (config.boot.uboot.package != null) ''
        cp ${config.boot.uboot.package} $out/uboot.img
      ''}
    ''}

    # ── env.img ────────────────────────────────────────────────────────────
    cp ${envImg} $out/env.img

    # ── boot.img (kernel, when provided) ──────────────────────────────────
    ${lib.optionalString (config.device.kernel != null) ''
      cp ${config.device.kernel} $out/boot.img
    ''}

    # ── oem.img / userdata.img (empty placeholder partitions) ─────────────
    cp ${emptyExt4 "oem"      16} $out/oem.img
    cp ${emptyExt4 "userdata" 32} $out/userdata.img

    # ── parameter.txt (Rockchip partition layout) ──────────────────────────
    # Sector offsets (512-byte sectors):
    #   0x000040  (64)       32 KiB  — SPL / idblock
    #   0x004000  (16384)     8 MiB  — U-Boot        (size 0x2000  = 4 MiB)
    #   0x006000  (24576)    12 MiB  — env            (size 0x800   = 512 KiB)
    #   0x008000  (32768)    16 MiB  — boot / kernel  (size 0x10000 = 32 MiB)
    #   0x018000  (98304)    48 MiB  — rootfs         (size 0x100000 = 512 MiB)
    #   0x118000  (1146880) 560 MiB  — userdata (fills remainder)
    cat > $out/parameter.txt << 'EOF'
FIRMWARE_VER: 1.0
MACHINE_MODEL: ${config.device.name}
MACHINE_ID: 0x000000
MANUFACTURER: NixOS
MAGIC: 0x5041524B
ATAG: 0x00200800
MACHINE: 0
CHECK_MASK: 0x80
PWR_HLD: 0,0,A,0,1
TYPE: GPT
CMDLINE: mtdparts=rk29xxnand:0x00002000@0x00004000(uboot),0x00000800@0x00006000(env),0x00010000@0x00008000(boot),0x00100000@0x00018000(rootfs),-@0x00118000(userdata:grow)
EOF

    # ── sd_update.txt ──────────────────────────────────────────────────────
    cat > $out/sd_update.txt << 'EOF'
#!/bin/sh
# SD card flash script for Luckfox Pico Mini B
# Usage:  sudo sh sd_update.txt /dev/sdX
#
# WARNING: This will OVERWRITE the target device. Double-check DISK below.
#
# Sector layout (512-byte sectors, matches parameter.txt CMDLINE):
#   Hex        Decimal    Offset    — Partition
#   0x00000040      64     32  KiB  — SPL / idbloader
#   0x00004000   16384      8  MiB  — U-Boot
#   0x00006000   24576     12  MiB  — env
#   0x00008000   32768     16  MiB  — boot (kernel)
#   0x00018000   98304     48  MiB  — rootfs
#   0x00118000 1146880    560  MiB  — userdata

DISK=''${1:?Usage: $0 /dev/sdX}

echo "Flashing to $DISK ..."

[ -f SPL          ] && dd if=SPL          of=$DISK bs=512 seek=64      conv=notrunc,sync
[ -f uboot.img    ] && dd if=uboot.img    of=$DISK bs=512 seek=16384   conv=notrunc,sync
[ -f env.img      ] && dd if=env.img      of=$DISK bs=512 seek=24576   conv=notrunc,sync
[ -f boot.img     ] && dd if=boot.img     of=$DISK bs=512 seek=32768   conv=notrunc,sync
[ -f rootfs.img   ] && dd if=rootfs.img   of=$DISK bs=512 seek=98304   conv=notrunc,sync
[ -f userdata.img ] && dd if=userdata.img of=$DISK bs=512 seek=1146880 conv=notrunc,sync

sync
echo "Done."
EOF
    chmod +x $out/sd_update.txt

    # ── tftp_update.txt ────────────────────────────────────────────────────
    cat > $out/tftp_update.txt << 'EOF'
# TFTP flash instructions — run these commands at the U-Boot prompt.
#
# 1. Connect the device to your network and start a TFTP server
#    serving the firmware-package directory.
#
# 2. At the U-Boot prompt:

setenv serverip  192.168.1.1     # your TFTP server IP
setenv ipaddr    192.168.1.100   # device IP

# Flash U-Boot itself (adjust mmc write offsets to match parameter.txt)
tftpboot 0x60800000 uboot.img
mmc write 0x60800000 0x4000 0x2000

# Flash env
tftpboot 0x60800000 env.img
mmc write 0x60800000 0x6000 0x0800

# Flash kernel
tftpboot 0x60800000 boot.img
mmc write 0x60800000 0x8000 0x10000

# Flash rootfs
tftpboot 0x60800000 rootfs.img
mmc write 0x60800000 0x18000 0x100000

saveenv
reset
EOF

    # ── manifest.txt ───────────────────────────────────────────────────────
    cat > $out/manifest.txt << EOF
device:     ${config.device.name}
hostname:   ${config.networking.hostname}
imageSize:  ${toString config.system.imageSize} MiB
built:      $(date -u +"%Y-%m-%dT%H:%M:%SZ")

files:
$(ls -lh $out | tail -n +2)
EOF
  '';
}
