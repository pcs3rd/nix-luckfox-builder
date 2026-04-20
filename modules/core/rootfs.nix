{ pkgs, config, lib, ... }:

{
  # ── Root filesystem directory ───────────────────────────────────────────────
  config.system.build.rootfs = pkgs.runCommand "rootfs" {} ''
    mkdir -p $out/{bin,sbin,etc,proc,sys,dev,root,lib,var/log}

    # ── busybox ────────────────────────────────────────────────────────────
    cp ${pkgs.pkgsStatic.busybox}/bin/busybox $out/bin/
    chmod +x $out/bin/busybox

    for cmd in sh ls cat echo mount umount mdev; do
      ln -s /bin/busybox $out/bin/$cmd
    done

    # busybox init lives at sbin/init
    ln -s /bin/busybox $out/sbin/init

    # ── Minimal pre-populated /dev ─────────────────────────────────────────
    # The kernel mounts devtmpfs over this at boot, but a few static nodes
    # are needed during early init before devtmpfs is up (e.g. /dev/null
    # is opened by busybox sh as soon as it starts).
    mkdir -p $out/dev
    # We can't call mknod in the Nix sandbox, so create a small helper
    # script that the initramfs build step runs as root to stamp the nodes.
    # Instead, rely entirely on devtmpfs (mounted first in inittab) and
    # pre-create /dev/console as a placeholder file so the kernel can hand
    # off stdio before devtmpfs is mounted.
    #
    # Actually: the kernel populates /dev/console itself via devtmpfs when
    # CONFIG_DEVTMPFS_MOUNT=y. We just need to mount devtmpfs first thing.

    # ── udhcpc wrapper (redirects noisy lease output to a log file) ───────
    ${lib.optionalString config.networking.dhcp.enable ''
      cat > $out/sbin/start-dhcp << 'DHCP_EOF'
#!/bin/sh
exec /bin/busybox udhcpc -i ${config.networking.interface} -f >> /var/log/udhcpc.log 2>&1
DHCP_EOF
      chmod +x $out/sbin/start-dhcp
    ''}

    # ── SSH (dropbear — static build, no dynamic linker needed) ───────────
    ${lib.optionalString config.services.ssh.enable ''
      mkdir -p $out/etc/dropbear
      cp ${pkgs.pkgsStatic.dropbear}/bin/dropbear $out/bin/
      chmod +x $out/bin/dropbear
    ''}

    # ── Self-expanding rootfs tools ────────────────────────────────────────
    ${lib.optionalString config.system.sdExpand.enable ''
      cp $(find ${pkgs.e2fsprogs} -name resize2fs -type f | head -1) $out/sbin/
      chmod +x $out/sbin/resize2fs

      cp $(find ${pkgs.util-linux} -name sfdisk -type f | head -1) $out/sbin/
      chmod +x $out/sbin/sfdisk

      cat > $out/sbin/expand-rootfs << 'EXPAND_EOF'
#!/bin/sh
DISK=/dev/mmcblk0
PART=/dev/mmcblk0p1
PHASE1_FLAG=/etc/.expand-p1-done
DONE_FLAG=/etc/.expanded

[ -f "$DONE_FLAG" ] && exit 0

if [ ! -f "$PHASE1_FLAG" ]; then
  DISK_SECTORS=$(cat /sys/block/mmcblk0/size 2>/dev/null || echo 0)
  PART_START=$(cat /sys/block/mmcblk0/mmcblk0p1/start 2>/dev/null || echo 0)
  PART_SIZE=$(cat /sys/block/mmcblk0/mmcblk0p1/size 2>/dev/null || echo 0)
  PART_END=$(( PART_START + PART_SIZE ))

  if [ "$DISK_SECTORS" -le 0 ] || [ "$PART_START" -le 0 ]; then
    echo "expand-rootfs: cannot read disk geometry, skipping." >&2
    exit 1
  fi

  FREE_SECTORS=$(( DISK_SECTORS - PART_END ))
  if [ "$FREE_SECTORS" -lt 262144 ]; then
    echo "expand-rootfs: partition already at full size, nothing to do."
    touch "$PHASE1_FLAG" "$DONE_FLAG"
    exit 0
  fi

  echo "expand-rootfs: phase 1 — resizing partition $PART ..."
  printf '%s,\n' "$PART_START" | sfdisk --force --no-reread -N 1 "$DISK"
  sync
  touch "$PHASE1_FLAG"
  echo "expand-rootfs: rebooting to reload partition table ..."
  reboot -f
else
  echo "expand-rootfs: phase 2 — resizing filesystem on $PART ..."
  resize2fs "$PART"
  sync
  touch "$DONE_FLAG"
  echo "expand-rootfs: done."
fi
EXPAND_EOF
      chmod +x $out/sbin/expand-rootfs
    ''}

    # ── inittab ────────────────────────────────────────────────────────────
    cat > $out/etc/inittab << 'EOF'
# Mount devtmpfs first — this populates /dev/null, /dev/console,
# /dev/ttyAMA0, etc. before any other process tries to open them.
::sysinit:/bin/mount -t devtmpfs devtmpfs /dev
::sysinit:/bin/mount -t proc proc /proc
::sysinit:/bin/mount -t sysfs sysfs /sys
# Scan /sys and create any device nodes devtmpfs may have missed.
::sysinit:/bin/busybox mdev -s
${lib.optionalString config.system.sdExpand.enable
  "::sysinit:/sbin/expand-rootfs"}
${lib.optionalString config.services.getty.enable
  "${config.services.getty.tty}::respawn:/bin/busybox getty -L ${config.services.getty.tty} ${toString config.services.getty.baud} vt100"}
${lib.optionalString config.services.ssh.enable
  "::respawn:/bin/dropbear -R -F"}
${lib.optionalString config.networking.dhcp.enable
  "::sysinit:/sbin/start-dhcp"}
::ctrlaltdel:/bin/busybox reboot
EOF

    # ── hostname ───────────────────────────────────────────────────────────
    echo "${config.networking.hostname}" > $out/etc/hostname

    # ── user / password database ───────────────────────────────────────────
    # passwd: shadow-style (password field is 'x', real hash is in shadow)
    cat > $out/etc/passwd << 'PASSWD_EOF'
root:x:0:0:root:/root:/bin/sh
nobody:x:65534:65534:nobody:/:/bin/false
PASSWD_EOF

    # shadow: root hash set at build time via users.root.hashedPassword
    printf 'root:%s:1:0:99999:7:::\n' "${config.users.root.hashedPassword}" \
      > $out/etc/shadow
    chmod 640 $out/etc/shadow

    cat > $out/etc/group << 'GROUP_EOF'
root:x:0:
nogroup:x:65534:
GROUP_EOF
  '';

  # ── Initramfs (cpio.gz) — used for QEMU boot ───────────────────────────────
  config.system.build.initramfs = pkgs.runCommand "rootfs.cpio.gz" {
    nativeBuildInputs = [ pkgs.buildPackages.cpio pkgs.buildPackages.gzip ];
  } ''
    cd ${config.system.build.rootfs}
    find . | cpio -o -H newc | gzip -9 > $out
  '';
}
