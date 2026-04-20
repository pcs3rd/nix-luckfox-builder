{ pkgs, config, lib, ... }:

{
  # ── Root filesystem directory ───────────────────────────────────────────────
  config.system.build.rootfs = pkgs.runCommand "rootfs" {} ''
    mkdir -p $out/{bin,sbin,etc,proc,sys,dev,root}

    # ── busybox ────────────────────────────────────────────────────────────
    cp ${pkgs.pkgsStatic.busybox}/bin/busybox $out/bin/
    chmod +x $out/bin/busybox

    for cmd in sh ls cat echo mount umount; do
      ln -s /bin/busybox $out/bin/$cmd
    done

    # busybox init lives at sbin/init
    ln -s /bin/busybox $out/sbin/init

    # ── SSH (dropbear) ─────────────────────────────────────────────────────
    ${lib.optionalString config.services.ssh.enable ''
      mkdir -p $out/etc/dropbear
      cp ${pkgs.dropbear}/bin/dropbear $out/bin/
      chmod +x $out/bin/dropbear
    ''}

    # ── Self-expanding rootfs tools ────────────────────────────────────────
    # resize2fs and sfdisk are needed by /sbin/expand-rootfs on first boot.
    ${lib.optionalString config.system.sdExpand.enable ''
      # resize2fs (from e2fsprogs)
      cp $(find ${pkgs.e2fsprogs} -name resize2fs -type f | head -1) $out/sbin/
      chmod +x $out/sbin/resize2fs

      # sfdisk (from util-linux, cross-compiled for target)
      cp $(find ${pkgs.util-linux} -name sfdisk -type f | head -1) $out/sbin/
      chmod +x $out/sbin/sfdisk

      # Two-phase expand script:
      #
      #   Phase 1 (first boot):
      #     Detect that the partition is smaller than the card, write the
      #     new partition size to disk with sfdisk --no-reread, then reboot
      #     so the kernel re-reads the partition table cleanly.
      #
      #   Phase 2 (second boot):
      #     The kernel now sees the full partition size; run resize2fs to
      #     grow the ext4 filesystem to fill it.  Mark done so this never
      #     runs again.

      cat > $out/sbin/expand-rootfs << 'EXPAND_EOF'
#!/bin/sh
DISK=/dev/mmcblk0
PART=/dev/mmcblk0p1
PHASE1_FLAG=/etc/.expand-p1-done
DONE_FLAG=/etc/.expanded

# Already fully expanded — nothing to do.
[ -f "$DONE_FLAG" ] && exit 0

if [ ! -f "$PHASE1_FLAG" ]; then
  # ── Phase 1: resize the partition on-disk ─────────────────────────────
  DISK_SECTORS=$(cat /sys/block/mmcblk0/size 2>/dev/null || echo 0)
  PART_START=$(cat /sys/block/mmcblk0/mmcblk0p1/start 2>/dev/null || echo 0)
  PART_SIZE=$(cat /sys/block/mmcblk0/mmcblk0p1/size 2>/dev/null || echo 0)
  PART_END=$(( PART_START + PART_SIZE ))

  if [ "$DISK_SECTORS" -le 0 ] || [ "$PART_START" -le 0 ]; then
    echo "expand-rootfs: cannot read disk geometry, skipping." >&2
    exit 1
  fi

  # Only expand if there is meaningful free space (>= 128 MiB)
  FREE_SECTORS=$(( DISK_SECTORS - PART_END ))
  if [ "$FREE_SECTORS" -lt 262144 ]; then
    echo "expand-rootfs: partition already at full size, nothing to do."
    touch "$PHASE1_FLAG" "$DONE_FLAG"
    exit 0
  fi

  echo "expand-rootfs: phase 1 — resizing partition $PART ..."
  # Rewrite partition 1 to fill the rest of the disk.
  # --no-reread: skip BLKRRPART ioctl (device is busy as rootfs).
  printf '%s,\n' "$PART_START" | sfdisk --force --no-reread -N 1 "$DISK"
  sync
  touch "$PHASE1_FLAG"
  echo "expand-rootfs: rebooting to reload partition table ..."
  reboot -f

else
  # ── Phase 2: grow the filesystem ──────────────────────────────────────
  echo "expand-rootfs: phase 2 — resizing filesystem on $PART ..."
  resize2fs "$PART"
  sync
  touch "$DONE_FLAG"
  echo "expand-rootfs: done — root filesystem now spans the full SD card."
fi
EXPAND_EOF
      chmod +x $out/sbin/expand-rootfs
    ''}

    # ── inittab ────────────────────────────────────────────────────────────
    cat > $out/etc/inittab << 'EOF'
${lib.optionalString config.system.sdExpand.enable
  "::sysinit:/sbin/expand-rootfs"}
::sysinit:/bin/mount -t proc proc /proc
::sysinit:/bin/mount -t sysfs sysfs /sys
${lib.optionalString config.services.getty.enable
  "${config.services.getty.tty}::respawn:/bin/busybox getty -L ${config.services.getty.tty} ${toString config.services.getty.baud} vt100"}
${lib.optionalString config.services.ssh.enable
  "::respawn:/bin/dropbear -R -F"}
${lib.optionalString config.networking.dhcp.enable
  "::sysinit:/bin/busybox udhcpc -i ${config.networking.interface} -f &"}
::ctrlaltdel:/bin/busybox reboot
EOF

    # ── hostname ───────────────────────────────────────────────────────────
    echo "${config.networking.hostname}" > $out/etc/hostname
  '';

  # ── Initramfs (cpio.gz) — used for QEMU boot ───────────────────────────────
  config.system.build.initramfs = pkgs.runCommand "rootfs.cpio.gz" {
    nativeBuildInputs = [ pkgs.buildPackages.cpio pkgs.buildPackages.gzip ];
  } ''
    cd ${config.system.build.rootfs}
    find . | cpio -o -H newc | gzip -9 > $out
  '';
}
