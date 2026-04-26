# A/B rootfs — zero-downtime over-SSH upgrades with squashfs + overlayfs.
#
# ── How it works ─────────────────────────────────────────────────────────────
#
# A single reserved byte at a fixed raw offset on the disk (default: byte 512,
# i.e. the first byte of sector 1) holds the active slot: 'a' or 'b'.
# Sector 1 sits between the MBR (sector 0) and the first bootloader stage and
# is never touched by any filesystem or bootloader on either supported board.
#
# ── Disk layout ──────────────────────────────────────────────────────────────
#
#   Sector    0 (  512 B) : MBR + partition table
#   Sector    1 (  512 B) : slot indicator byte ('a' or 'b')  ← managed here
#   Sectors 2–63          : unused / reserved
#   Sector   64           : Rockchip SPL / idbloader  (raw, not a partition)
#   Sector 16384          : U-Boot proper              (raw, not a partition)
#
#   Partition 1  (ext4,     label: "boot")    — kernel + initramfs + boot.scr
#   Partition 2  (squashfs, no label)         — slot A rootfs  (read-only)
#   Partition 3  (squashfs, no label)         — slot B rootfs  (read-only)
#   Partition 4  (ext4,     label: "persist") — overlayfs upper/work dirs
#
# ── Boot path ────────────────────────────────────────────────────────────────
#
#   1. U-Boot finds boot.scr in partition 1, loads kernel + initramfs.
#   2. Kernel starts with the slot-select initramfs as the initial root.
#   3. The initramfs reads the slot indicator byte from the raw disk.
#   4. It mounts the active squashfs slot (p2 or p3) at /squash.
#   5. It mounts the persist ext4 partition (p4) at /persist.
#   6. It creates /persist/slot-{a,b}/upper and /persist/slot-{a,b}/work.
#   7. It mounts overlayfs: lower=/squash, upper/work in persist.
#   8. exec switch_root into the overlay — the running rootfs is read-write.
#
#   Result: the rootfs is a live overlay.  Reads come from squashfs (fast,
#   compressed, immutable).  Writes land in the persist partition and survive
#   reboots.  Each slot has its own upper layer, so a fresh upgrade starts
#   with an empty writable layer.
#
# ── Kernel requirements ───────────────────────────────────────────────────────
#
#   CONFIG_SQUASHFS=y  (+ CONFIG_SQUASHFS_LZ4=y for lz4 compression)
#   CONFIG_OVERLAY_FS=y
#
#   If these are compiled as modules (=m), add them to extraKernelModules
#   so the initramfs loads them before attempting to mount:
#     system.abRootfs.extraKernelModules = [
#       "${kernelModulesPath}/kernel/fs/squashfs/squashfs.ko"
#       "${kernelModulesPath}/kernel/fs/overlayfs/overlay.ko"
#     ];
#
# ── Upgrade workflow ──────────────────────────────────────────────────────────
#
# On the build host:
#   nix build .#rootfsPartition         # produces result/rootfs.squashfs
#   ssh root@device upgrade < result/rootfs.squashfs
#
# On the device, /bin/upgrade:
#   1. Reads current slot from the raw disk offset
#   2. Writes new squashfs to the INACTIVE partition (dd from stdin)
#   3. Atomically flips the slot byte on disk
#   4. Reboots into the new slot
#
# The persist partition is NOT cleared on upgrade.  Each slot has its own
# overlay directory, so upgrading to slot B starts with a fresh upper layer.
#
# To inspect the active slot at runtime:   /bin/slot
# To force a specific slot on next boot:   /bin/slot a   (or /bin/slot b)
#
# ── Configuration ─────────────────────────────────────────────────────────────
#
#   system.abRootfs = {
#     enable              = true;
#     slotOffset          = 512;        # byte offset of the indicator (default)
#     bootPartLabel       = "boot";     # ext4 label of the boot partition
#     bootPartSize        = 64;         # MiB
#     persistLabel        = "persist";  # ext4 label of the persist partition
#     persistSize         = 256;        # MiB
#     squashfsCompression = "lz4";      # compression algorithm
#   };

{ pkgs, config, lib, ... }:

let
  cfg = config.system.abRootfs;

  # ── Slot-select init script (runs as PID 1 in the initramfs) ─────────────
  slotSelectInit = pkgs.writeScript "slot-select-init" ''
    #!/bin/sh
    mount -t proc     proc     /proc
    mount -t sysfs    sysfs    /sys
    mount -t devtmpfs devtmpfs /dev 2>/dev/null || true

    # Load any kernel modules embedded at build time
    # (e.g. virtio_blk, squashfs, overlay).
    # Three passes handle simple dependency chains without needing modprobe.
    if [ -n "$(ls /lib/modules/*.ko 2>/dev/null)" ]; then
      echo "slot-select: loading modules: $(ls /lib/modules/)"
      for pass in 1 2 3; do
        for ko in /lib/modules/*.ko; do
          [ -f "$ko" ] && insmod "$ko" 2>&1 || true
        done
      done
    fi

    # Wait for the first real block disk to appear in /proc/partitions.
    # Re-run mdev -s each iteration so partition device nodes are created as
    # the kernel finishes scanning.  Skip RAM disks, MTD flash, and loop devices;
    # skip partition entries (names ending in a digit) to get only whole disks.
    i=0
    DISK=""
    while [ $i -lt 20 ] && [ -z "$DISK" ]; do
      mdev -s 2>/dev/null || true
      DISK=$(awk 'NR>2 { n=$NF
        if (n ~ /^(ram|loop|mtdblock)/) next
        if (n ~ /[0-9]$/) next
        print "/dev/" n; exit
      }' /proc/partitions 2>/dev/null)
      [ -z "$DISK" ] && sleep 1
      i=$(( i + 1 ))
    done

    if [ -z "$DISK" ]; then
      echo "slot-select: FATAL — no block device found after 20 s" >&2
      cat /proc/partitions >&2
      exec /bin/sh
    fi

    # Derive partition paths from the disk name.
    # Fixed layout: p1=boot(ext4), p2=slot-A(squashfs),
    #               p3=slot-B(squashfs), p4=persist(ext4).
    # mmcblk* and nvme* use a 'p' prefix before the partition number.
    case "$DISK" in
      *mmcblk* | *nvme*)
        SLOT_A="''${DISK}p2"
        SLOT_B="''${DISK}p3"
        PERSIST="''${DISK}p4"
        ;;
      *)
        SLOT_A="''${DISK}2"
        SLOT_B="''${DISK}3"
        PERSIST="''${DISK}4"
        ;;
    esac

    # Read single slot indicator byte from the reserved raw disk location.
    SLOT=$(dd if="$DISK" bs=1 skip=${toString cfg.slotOffset} count=1 2>/dev/null)

    if [ "$SLOT" = "b" ]; then
      ROOT="$SLOT_B"
    else
      ROOT="$SLOT_A"
      SLOT=a
    fi
    echo "slot-select: disk=$DISK  slot=$SLOT  root=$ROOT"

    # ── Mount active squashfs slot ──────────────────────────────────────────
    # Squashfs can be mounted directly from a raw partition — no loop device
    # needed.  The kernel reads the squashfs superblock from the block device.
    if ! mount -t squashfs "$ROOT" /squash; then
      echo "slot-select: WARNING — $ROOT failed, falling back to slot A" >&2
      mount -t squashfs "$SLOT_A" /squash || {
        echo "slot-select: FATAL — cannot mount any squashfs slot" >&2
        exec /bin/sh
      }
      SLOT=a
    fi

    # ── Mount persist partition for overlayfs upper/work dirs ───────────────
    # Falls back to tmpfs if the persist partition isn't available yet
    # (e.g. on first boot before persist is formatted, or in minimal test builds).
    if mount -t ext4 "$PERSIST" /persist 2>/dev/null; then
      echo "slot-select: persist=$PERSIST  (writes survive reboots)"
    else
      mount -t tmpfs tmpfs /persist
      echo "slot-select: WARNING — no persist partition; using tmpfs (ephemeral)"
    fi

    mkdir -p /persist/slot-"$SLOT"/upper /persist/slot-"$SLOT"/work

    # ── Overlay: squashfs lower + persist upper ─────────────────────────────
    # The squashfs mount at /squash and persist at /persist remain live inside
    # the kernel VFS even after switch_root discards the initramfs root — the
    # overlay holds references to both.
    if ! mount -t overlay overlay \
        -o "lowerdir=/squash,upperdir=/persist/slot-$SLOT/upper,workdir=/persist/slot-$SLOT/work" \
        /newroot; then
      echo "slot-select: WARNING — overlay failed; binding squashfs read-only" >&2
      mount --bind /squash /newroot || {
        echo "slot-select: FATAL — cannot set up root" >&2
        exec /bin/sh
      }
    fi

    for mnt in proc sys dev; do
      mount --move "/$mnt" "/newroot/$mnt" 2>/dev/null || true
    done

    exec switch_root /newroot /sbin/init
  '';

  # ── Slot-select initramfs (tiny cpio.gz: busybox + init script) ──────────
  slotSelectInitramfs = pkgs.runCommand "slot-select-initramfs" {
    nativeBuildInputs = with pkgs.buildPackages; [ cpio gzip ];
  } ''
    # /squash  — squashfs lower layer mount point
    # /persist — ext4 persist partition mount point
    # /newroot — overlayfs mount point (becomes new root after switch_root)
    mkdir -p fs/{bin,lib/modules,proc,sys,dev,squash,persist,newroot}

    cp ${pkgs.pkgsStatic.busybox}/bin/busybox fs/bin/busybox
    chmod +x fs/bin/busybox
    for cmd in sh mount umount dd switch_root sleep mdev awk mkdir cat insmod; do
      ln -sf busybox fs/bin/$cmd
    done

    ${lib.concatMapStrings (entry: ''
      if [ -d ${entry} ]; then
        find ${entry} -name '*.ko' -exec cp {} fs/lib/modules/ \;
      else
        cp ${entry} fs/lib/modules/
      fi
    '') cfg.extraKernelModules}

    cp ${slotSelectInit} fs/init
    chmod +x fs/init

    mkdir -p $out
    ( cd fs && find . | cpio -o -H newc | gzip -9 ) > $out/initramfs-slotselect.cpio.gz
  '';

  # ── /bin/upgrade ─────────────────────────────────────────────────────────
  upgradeScript = pkgs.writeScript "upgrade" ''
    #!/bin/sh
    #
    # upgrade — stream a new squashfs rootfs image from stdin to the inactive
    #           slot, flip the slot indicator, and reboot.
    #
    # From the build host:
    #   nix build .#rootfsPartition
    #   ssh root@device upgrade < result/rootfs.squashfs
    #
    # With compression (saves transfer bandwidth):
    #   gzip -c result/rootfs.squashfs | ssh root@device "gunzip | upgrade"

    OFFSET="${toString cfg.slotOffset}"

    # Refuse to run if stdin is a terminal — a squashfs image must be piped in.
    if [ -t 0 ]; then
      echo "upgrade: error: no input — pipe a squashfs image into this command" >&2
      echo "  nix build .#rootfsPartition" >&2
      echo "  ssh root@device upgrade < result/rootfs.squashfs" >&2
      exit 1
    fi

    # Locate the disk via the persist partition's ext4 label.
    # Squashfs slot partitions have no filesystem label; the persist partition does.
    PERSIST=$(findfs LABEL="${cfg.persistLabel}" 2>/dev/null)

    if [ -z "$PERSIST" ]; then
      echo "upgrade: error: no partition with LABEL=${cfg.persistLabel}" >&2
      exit 1
    fi

    # Derive the whole-disk device from the persist partition path.
    DISK=$(echo "$PERSIST" | sed -E 's/p?[0-9]+$//')

    # Slot partitions by number: p2 = slot A, p3 = slot B.
    case "$DISK" in
      *mmcblk* | *nvme*) SLOT_A="''${DISK}p2"; SLOT_B="''${DISK}p3" ;;
      *)                 SLOT_A="''${DISK}2";  SLOT_B="''${DISK}3"  ;;
    esac

    CURRENT=$(dd if="$DISK" bs=1 skip="$OFFSET" count=1 2>/dev/null)
    case "$CURRENT" in
      b) NEXT=a; TARGET=$SLOT_A ;;
      *) NEXT=b; TARGET=$SLOT_B ;;
    esac

    echo "upgrade: current=$CURRENT  next=$NEXT  target=$TARGET"
    echo "upgrade: streaming squashfs from stdin — do not interrupt..."

    dd of="$TARGET" bs=4M
    sync

    echo "upgrade: activating slot $NEXT"
    printf '%s' "$NEXT" | dd of="$DISK" bs=1 seek="$OFFSET" conv=notrunc 2>/dev/null
    sync

    echo "upgrade: complete — rebooting into slot $NEXT in 3 s"
    sleep 3
    reboot
  '';

  # ── /bin/slot ────────────────────────────────────────────────────────────
  slotScript = pkgs.writeScript "slot" ''
    #!/bin/sh
    # slot          — show active and standby slots
    # slot a        — set slot A active on next boot (no reboot)
    # slot b        — set slot B active on next boot (no reboot)
    OFFSET="${toString cfg.slotOffset}"

    # Locate the disk via the persist partition's ext4 label.
    PERSIST=$(findfs LABEL="${cfg.persistLabel}" 2>/dev/null)

    if [ -z "$PERSIST" ]; then
      echo "slot: error: no partition with LABEL=${cfg.persistLabel}" >&2
      exit 1
    fi

    DISK=$(echo "$PERSIST" | sed -E 's/p?[0-9]+$//')

    case "$DISK" in
      *mmcblk* | *nvme*) SLOT_A="''${DISK}p2"; SLOT_B="''${DISK}p3" ;;
      *)                 SLOT_A="''${DISK}2";  SLOT_B="''${DISK}3"  ;;
    esac

    case "$1" in
      a|b)
        TARGET="$1"
        CURRENT=$(dd if="$DISK" bs=1 skip="$OFFSET" count=1 2>/dev/null)
        if [ "$CURRENT" = "$TARGET" ]; then
          echo "slot: already on slot $(echo "$TARGET" | tr a-z A-Z) — nothing to do"
          exit 0
        fi
        printf '%s' "$TARGET" | dd of="$DISK" bs=1 seek="$OFFSET" conv=notrunc 2>/dev/null
        sync
        echo "slot: next boot will use slot $(echo "$TARGET" | tr a-z A-Z) — reboot to apply"
        ;;
      "")
        CURRENT=$(dd if="$DISK" bs=1 skip="$OFFSET" count=1 2>/dev/null)
        case "$CURRENT" in
          b)
            echo "active:  B  ($SLOT_B)"
            echo "standby: A  ($SLOT_A)"
            ;;
          *)
            echo "active:  A  ($SLOT_A)"
            echo "standby: B  ($SLOT_B)"
            ;;
        esac
        ;;
      *)
        echo "usage: slot [a|b]" >&2
        exit 1
        ;;
    esac
  '';

  # ── Standalone rootfs squashfs image (for streaming via `upgrade`) ────────
  # Written byte-for-byte to a raw slot partition — no filesystem wrapper.
  # -mkfs-time 0 -all-time 0 suppress embedded timestamps for reproducibility.
  rootfsSquashfsImage = pkgs.runCommand "rootfs-squashfs" {
    nativeBuildInputs = with pkgs.buildPackages; [ squashfsTools ];
  } ''
    mkdir -p $out
    # SOURCE_DATE_EPOCH is set by Nix for reproducibility; mksquashfs honours it
    # automatically.  Do NOT also pass -mkfs-time/-all-time — mksquashfs treats
    # both at once as a fatal conflict.
    mksquashfs ${config.system.build.rootfs} $out/rootfs.squashfs \
      -comp ${cfg.squashfsCompression} \
      -noappend \
      -no-progress
    echo "squashfs size: $(du -sh $out/rootfs.squashfs | cut -f1)"
  '';

in

{
  config = lib.mkMerge [
    {
      # Always set these — readOnly options with no default must have exactly
      # one definition. null when A/B is disabled, derivation when enabled.
      system.build.slotSelectInitramfs = if cfg.enable then slotSelectInitramfs else null;
      system.build.rootfsPartition     = if cfg.enable then rootfsSquashfsImage else null;
    }
    (lib.mkIf cfg.enable {
      # Install upgrade and slot scripts into the rootfs only when A/B is on.
      packages = [
        (pkgs.runCommand "ab-rootfs-scripts" {} ''
          mkdir -p $out/bin
          cp ${upgradeScript} $out/bin/upgrade
          cp ${slotScript}    $out/bin/slot
          chmod +x $out/bin/upgrade $out/bin/slot
        '')
      ];
    })
  ];
}
