{ pkgs, config, lib, ... }:

{
  # ── Root filesystem directory ───────────────────────────────────────────────
  config.system.build.rootfs = pkgs.runCommand "rootfs" {} ''
    mkdir -p $out/{bin,sbin,etc,proc,sys,dev,root,lib,tmp,var/log,mnt,newroot}
    chmod 1777 $out/tmp

    # ── Kernel modules ─────────────────────────────────────────────────────
    # Copy /lib/modules/<ver>/ so that modprobe can load kernel modules
    # (e.g. zram) at runtime.  Set device.kernelModulesPath to a derivation
    # that provides a lib/modules/ tree (see pkgs/luckfox-kernel-modules.nix).
    ${lib.optionalString (config.device.kernelModulesPath != null) ''
      mkdir -p $out/lib/modules
      cp -rL ${config.device.kernelModulesPath}/. $out/lib/modules/
    ''}

    # ── busybox ────────────────────────────────────────────────────────────
    cp ${pkgs.pkgsStatic.busybox}/bin/busybox $out/bin/
    chmod +x $out/bin/busybox

    # Symlink every applet that this busybox build was compiled with.
    # nixpkgs' busybox package already creates one symlink per applet in its
    # own bin/, so iterating those is more reliable than a hardcoded list.
    for f in ${pkgs.pkgsStatic.busybox}/bin/*; do
      name=$(basename "$f")
      [ "$name" = "busybox" ] && continue
      ln -sf /bin/busybox "$out/bin/$name"
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


    # ── SSH (dropbear — static build, no dynamic linker needed) ───────────
    ${lib.optionalString config.services.ssh.enable ''
      mkdir -p $out/etc/dropbear
      cp ${pkgs.pkgsStatic.dropbear}/bin/dropbear $out/bin/
      chmod +x $out/bin/dropbear
    ''}

    # ── Service launcher wrappers (redirect output to /var/log) ───────────
    ${lib.optionalString config.networking.dhcp.enable ''
      cat > $out/sbin/start-dhcp << 'DHCP_EOF'
#!/bin/sh
exec /bin/busybox udhcpc -i ${config.networking.interface} -T 3 -t 3 -A 3 >> /var/log/udhcpc.log 2>&1
DHCP_EOF
      chmod +x $out/sbin/start-dhcp
    ''}

    ${lib.optionalString config.services.ssh.enable ''
      cat > $out/sbin/start-dropbear << 'SSH_EOF'
#!/bin/sh
exec /bin/dropbear -R -F >> /var/log/dropbear.log 2>&1
SSH_EOF
      chmod +x $out/sbin/start-dropbear
    ''}

    # ── SD overlay tools and init script ──────────────────────────────────
    ${lib.optionalString config.system.sdOverlay.enable ''
      # Tools needed by init-overlay.
      # Use '! -type d' so find matches both regular files AND symlinks
      # (nixpkgs installs mkfs.ext4 as a symlink to mke2fs; -type f misses it).
      # -L on cp dereferences the symlink so we install the real ELF.
      cp -L $(find ${pkgs.e2fsprogs}  -name mkfs.ext4  ! -type d | head -1) $out/sbin/mkfs.ext4
      cp -L $(find ${pkgs.util-linux} -name sfdisk     ! -type d | head -1) $out/sbin/sfdisk
      cp -L $(find ${pkgs.util-linux} -name blkid      ! -type d | head -1) $out/sbin/blkid
      cp -L $(find ${pkgs.util-linux} -name blockdev   ! -type d | head -1) $out/sbin/blockdev
      chmod +x $out/sbin/mkfs.ext4 $out/sbin/sfdisk $out/sbin/blkid $out/sbin/blockdev

      # pivot_root BusyBox applet
      ln -sf /bin/busybox $out/bin/pivot_root

      cat > $out/sbin/init-overlay << 'OVERLAY_EOF'
#!/bin/sh
#
# init-overlay — kernel init= entry point for sdimage overlay builds.
#
# First boot:  creates a partition from the unpartitioned space after the
#              rootfs, formats it ext4, and uses it as the overlay upper dir.
# Every boot:  mounts the overlay partition and overlays it on top of the
#              (read-only) rootfs, then execs the real init.
# Fallback:    if anything fails, boots normally without overlay.
#

DISK=/dev/mmcblk0
OVERLAY_PART=${config.system.sdOverlay.device}

# ── Basic filesystems ──────────────────────────────────────────────────────
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
/bin/busybox mdev -s 2>/dev/null || true

# ── Overlay setup (runs in a subshell so errors fall through to the exec) ──
setup_overlay() {
  # ── Create overlay partition if this is first boot ───────────────────────
  if ! [ -b "$OVERLAY_PART" ]; then
    echo "init-overlay: first boot — creating overlay partition..."

    P1_START=$(cat /sys/block/mmcblk0/mmcblk0p1/start)
    P1_SIZE=$( cat /sys/block/mmcblk0/mmcblk0p1/size)
    P2_START=$(( P1_START + P1_SIZE ))

    # Append partition 2 starting right after partition 1 and filling the card.
    # sfdisk without --no-reread will issue BLKRRPART to reload the table.
    printf '%d,+\n' "$P2_START" | \
      /sbin/sfdisk --force --append "$DISK" || return 1

    # Wait up to 5 s for the device node to materialise
    i=0
    while [ "$i" -lt 50 ] && ! [ -b "$OVERLAY_PART" ]; do
      sleep 0.1; i=$(( i + 1 ))
    done
    [ -b "$OVERLAY_PART" ] || return 1
  fi

  # ── Format on first use ──────────────────────────────────────────────────
  if ! /sbin/blkid -t TYPE=ext4 "$OVERLAY_PART" > /dev/null 2>&1; then
    echo "init-overlay: formatting $OVERLAY_PART as ext4..."
    /sbin/mkfs.ext4 -q -L overlay "$OVERLAY_PART" || return 1
  fi

  # ── Mount overlay storage ────────────────────────────────────────────────
  mount "$OVERLAY_PART" /mnt || return 1
  mkdir -p /mnt/upper /mnt/work

  # ── Mount overlayfs (lower = current ro rootfs) ──────────────────────────
  mount -t overlay overlay \
    -o lowerdir=/,upperdir=/mnt/upper,workdir=/mnt/work \
    /newroot || return 1

  # ── Move pseudo-filesystems into new root ────────────────────────────────
  mount --move /proc   /newroot/proc
  mount --move /sys    /newroot/sys
  mount --move /dev    /newroot/dev

  # ── Pivot into the overlay ────────────────────────────────────────────────
  # After pivot_root . mnt:
  #   /          = overlay (writes go to userdata partition)
  #   /mnt       = original read-only ext4 rootfs
  #   /mnt/mnt   = overlay partition (the upper/work dirs are here)
  cd /newroot
  pivot_root . mnt
}

if setup_overlay; then
  echo "init-overlay: overlay active."
else
  echo "init-overlay: overlay setup failed — booting without overlay." >&2
fi

exec /sbin/init
OVERLAY_EOF
      chmod +x $out/sbin/init-overlay
    ''}

    # ── Self-expanding rootfs tools ────────────────────────────────────────
    ${lib.optionalString config.system.sdExpand.enable ''
      cp -L $(find ${pkgs.e2fsprogs}  -name resize2fs ! -type d | head -1) $out/sbin/resize2fs
      chmod +x $out/sbin/resize2fs

      cp -L $(find ${pkgs.util-linux} -name sfdisk    ! -type d | head -1) $out/sbin/sfdisk
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

    # ── User-defined services ──────────────────────────────────────────────
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: svc:
      lib.optionalString svc.enable ''
        cp ${pkgs.writeScript "svc-${name}" ''
          #!/bin/sh
          ${svc.script}
        ''} $out/sbin/svc-${name}
        chmod +x $out/sbin/svc-${name}
      ''
    ) config.services.user)}

    # ── Extra packages ─────────────────────────────────────────────────────
    # Walk every top-level directory in the package output:
    #   bin / sbin — copy binaries, but skip names that already exist so we
    #                don't overwrite BusyBox applet symlinks.
    #   everything else (etc, lib, share, var, …) — merged verbatim into the
    #                rootfs so installPhase-created directories are preserved.
    ${lib.concatMapStrings (pkg: ''
      for entry in "${pkg}"/*/; do
        [ -d "$entry" ] || continue
        dirname=$(basename "$entry")
        case "$dirname" in
          bin|sbin)
            mkdir -p "$out/$dirname"
            for f in "$entry"*; do
              [ -e "$f" ] || continue
              name=$(basename "$f")
              if [ ! -e "$out/bin/$name" ] && [ ! -L "$out/bin/$name" ] && \
                 [ ! -e "$out/sbin/$name" ] && [ ! -L "$out/sbin/$name" ]; then
                cp -L "$f" "$out/$dirname/$name"
                chmod +x "$out/$dirname/$name"
              fi
            done
            ;;
          nix-support|newroot)
            # nix-support: Nix build metadata — never needed at runtime.
            # newroot:     overlay pivot staging dir — owned by the rootfs, not packages.
            ;;
          *)
            # Merge the directory tree into the rootfs.
            # -rL follows symlinks so store symlinks become real files.
            mkdir -p "$out/$dirname"
            cp -rL "$entry/." "$out/$dirname/" 2>/dev/null || true
            ;;
        esac
      done
    '') config.packages}

    # ── /sbin/init-pseudofs — idempotent pseudo-filesystem mounts ──────────
    # After switch_root from the A/B initramfs, /proc, /sys, and /dev are
    # already mounted (the initramfs moved them with mount --move before
    # exec switch_root).  A plain 'mount' would print "Resource busy" and
    # clutter the boot log.  Guard each mount with mountpoint -q so it only
    # runs when the filesystem isn't already there.
    cat > $out/sbin/init-pseudofs << 'PSEUDO_EOF'
#!/bin/sh
mountpoint -q /dev  2>/dev/null || mount -t devtmpfs devtmpfs /dev
mountpoint -q /proc 2>/dev/null || mount -t proc proc /proc
mountpoint -q /sys  2>/dev/null || mount -t sysfs sysfs /sys
exec /bin/busybox mdev -s
PSEUDO_EOF
    chmod +x $out/sbin/init-pseudofs

    # ── inittab ────────────────────────────────────────────────────────────
    cat > $out/etc/inittab << 'EOF'
# Mount pseudo-filesystems and populate /dev — idempotent so it's safe
# whether we came up from the A/B initramfs (already mounted) or directly.
::sysinit:/sbin/init-pseudofs
${lib.optionalString config.system.sdExpand.enable
  "::sysinit:/sbin/expand-rootfs"}
${lib.optionalString config.services.getty.enable
  "${config.services.getty.tty}::respawn:/bin/busybox getty -L ${config.services.getty.tty} ${toString config.services.getty.baud} vt100"}
${lib.optionalString config.services.ssh.enable
  "::respawn:/sbin/start-dropbear"}
${lib.optionalString config.networking.dhcp.enable
  "::once:/sbin/start-dhcp"}
${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: svc:
  lib.optionalString svc.enable "::${svc.action}:/sbin/svc-${name}"
) config.services.user)}
::ctrlaltdel:/bin/busybox reboot
EOF

    # ── hostname ───────────────────────────────────────────────────────────
    echo "${config.networking.hostname}" > $out/etc/hostname

    # ── Login banner (/etc/issue) — shown by getty before the login prompt ─
    ${lib.optionalString (config.system.banner != null) ''
      cp ${pkgs.writeText "issue" config.system.banner} $out/etc/issue
    ''}

    # ── Message of the day (/etc/motd) — shown by login after auth ─────────
    ${lib.optionalString (config.system.motd != null) ''
      cp ${pkgs.writeText "motd" config.system.motd} $out/etc/motd
    ''}

    # ── user / password database ───────────────────────────────────────────
    # passwd: shadow-style (password field is 'x', real hash is in shadow)
    cat > $out/etc/passwd << 'PASSWD_EOF'
root:x:0:0:root:/root:/bin/sh
nobody:x:65534:65534:nobody:/:/bin/false
PASSWD_EOF

    # shadow: root hash set at build time via users.root.hashedPassword
    # lib.escapeShellArg wraps the hash in single quotes so the shell does
    # not expand the $ signs inside the crypt hash string.
    printf 'root:%s:1:0:99999:7:::\n' ${lib.escapeShellArg config.users.root.hashedPassword} \
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
