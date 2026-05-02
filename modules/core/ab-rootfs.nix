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
#   With SHA1 verification (recommended — detects corruption or truncation):
#   SHA=$(sha1sum result/rootfs.squashfs | awk '{print $1}')
#   ssh root@device upgrade --sha1 "$SHA" < result/rootfs.squashfs
#
# On the device, /bin/upgrade:
#   1. Reads current slot from the raw disk offset
#   2. Streams new squashfs to the INACTIVE partition while hashing in-flight
#   3. Verifies SHA1 before touching the slot byte (aborts on mismatch)
#   4. Atomically flips the slot byte on disk
#   5. Reboots into the new slot
#
# The persist partition is NOT cleared on upgrade.  Each slot has its own
# overlay directory, so upgrading to slot B starts with a fresh upper layer.
#
# To inspect the active slot at runtime:   /bin/slot
# To force a specific slot on next boot:   /bin/slot a   (or /bin/slot b)
# To share a config file between slots:    /bin/slot-share /etc/myapp/config
# To list shared files:                    /bin/slot-share --list
# To un-share a file:                      /bin/slot-share --unshare /etc/myapp/config
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
#     swapSize            = 256;        # MiB disk swap in persist (0 = off)
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
    # skip partition entries to get only whole disks.
    #
    # Naming conventions:
    #   SCSI/virtio:  sda (disk), sda1 (partition)  — disk does NOT end in digit
    #   MMC:          mmcblk0 (disk), mmcblk0p1 (partition) — disk ENDS in digit!
    #   NVMe:         nvme0n1 (disk), nvme0n1p1 (partition) — disk ends in digit
    #
    # The old "skip if name ends in digit" rule works for SCSI/virtio but
    # incorrectly drops mmcblk0 and nvme0n1.  Explicitly accept the MMC/NVMe
    # whole-disk patterns; fall back to the digit-suffix heuristic for others.
    i=0
    DISK=""
    while [ $i -lt 20 ] && [ -z "$DISK" ]; do
      mdev -s 2>/dev/null || true
      DISK=$(awk 'NR>2 { n=$NF
        if (n ~ /^(ram|loop|mtdblock)/) next
        if (n ~ /^mmcblk[0-9]+$/) { print "/dev/" n; exit }
        if (n ~ /^nvme[0-9]+n[0-9]+$/) { print "/dev/" n; exit }
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

    # The kernel registers the whole disk (mmcblk1) before it finishes reading
    # the partition table and registering the individual partitions (mmcblk1p1..p4).
    # Wait until all the partitions we care about (slot A and persist) exist.
    j=0
    while [ $j -lt 10 ] && { [ ! -b "$SLOT_A" ] || [ ! -b "$PERSIST" ]; }; do
      mdev -s 2>/dev/null || true
      sleep 1
      j=$(( j + 1 ))
    done
    if [ ! -b "$SLOT_A" ]; then
      echo "slot-select: WARNING — $SLOT_A not yet visible; /proc/partitions:" >&2
      cat /proc/partitions >&2
    fi
    if [ ! -b "$PERSIST" ]; then
      echo "slot-select: WARNING — $PERSIST not yet visible; /proc/partitions:" >&2
      cat /proc/partitions >&2
    fi

    # Read single slot indicator byte from the reserved raw disk location.
    SLOT=$(dd if="$DISK" bs=1 skip=${toString cfg.slotOffset} count=1 2>/dev/null)

    if [ "$SLOT" = "b" ]; then
      ROOT="$SLOT_B"
    else
      ROOT="$SLOT_A"
      SLOT=a
    fi
    echo "slot-select: disk=$DISK  slot=$SLOT  root=$ROOT"

    FALLBACK_MSG=""

    # ── Mount active squashfs slot ──────────────────────────────────────────
    # Squashfs can be mounted directly from a raw partition — no loop device
    # needed.  The kernel reads the squashfs superblock from the block device.
    if ! mount -t squashfs "$ROOT" /squash; then
      ATTEMPTED="$SLOT"
      # Fall back to the OTHER slot (not always A — if A is the corrupt one
      # we must try B, not retry A).
      if [ "$SLOT" = "a" ]; then
        FB_SLOT=b; FB_ROOT="$SLOT_B"
      else
        FB_SLOT=a; FB_ROOT="$SLOT_A"
      fi
      echo "slot-select: WARNING — slot $ATTEMPTED ($ROOT) failed; falling back to slot $FB_SLOT" >&2
      mount -t squashfs "$FB_ROOT" /squash || {
        echo "slot-select: FATAL — cannot mount any squashfs slot" >&2
        exec /bin/sh
      }
      SLOT="$FB_SLOT"
      FALLBACK_MSG="Boot failure: slot $(echo "$ATTEMPTED" | tr a-z A-Z) ($ROOT) failed to mount; fell back to slot $(echo "$FB_SLOT" | tr a-z A-Z)."
    fi

    # ── Mount persist partition for overlayfs upper/work dirs ───────────────
    # On first boot the ext4 partition is raw (never formatted).  Three cases:
    #   1. Mount succeeds (already formatted)        → use it, writes survive reboots
    #   2. Block device exists but mount fails       → format with mke2fs, then mount
    #   3. Block device missing (test / minimal build) → fall back to tmpfs
    if mount -t ext4 "$PERSIST" /persist 2>/dev/null; then
      echo "slot-select: persist=$PERSIST  (writes survive reboots)"
    elif [ -b "$PERSIST" ]; then
      echo "slot-select: formatting persist partition $PERSIST (first boot)..."
      mke2fs -t ext4 -L "${cfg.persistLabel}" "$PERSIST" \
        && mount -t ext4 "$PERSIST" /persist \
        && echo "slot-select: persist formatted and mounted (first boot)" \
        || {
          echo "slot-select: WARNING — mke2fs failed; falling back to tmpfs (ephemeral)" >&2
          mount -t tmpfs tmpfs /persist
        }
    else
      mount -t tmpfs tmpfs /persist
      echo "slot-select: WARNING — $PERSIST not found; using tmpfs (ephemeral)"
    fi

    mkdir -p /persist/slot-"$SLOT"/upper /persist/slot-"$SLOT"/work

    ${lib.optionalString (cfg.swapSize > 0) ''
    # ── Disk-backed swap from persist partition ─────────────────────────────
    # /persist/swapfile is created here on first boot and activated with
    # swapon.  Because the persist mount persists inside the kernel VFS through
    # switch_root, the swap stays live for the entire system lifetime with no
    # userspace service required.
    SWAPFILE=/persist/swapfile
    if [ ! -f "$SWAPFILE" ]; then
      echo "slot-select: creating swap file (${toString cfg.swapSize} MiB)..."
      dd if=/dev/zero of="$SWAPFILE" bs=1M count=${toString cfg.swapSize} 2>/dev/null
      chmod 600 "$SWAPFILE"
      mkswap "$SWAPFILE"
    fi
    swapon "$SWAPFILE" \
      && echo "slot-select: swap activated (${toString cfg.swapSize} MiB)" \
      || echo "slot-select: WARNING — swapon failed (non-fatal)" >&2
    ''}

    # ── Overlay: squashfs lower + persist upper ─────────────────────────────
    # The squashfs mount at /squash and persist at /persist remain live inside
    # the kernel VFS even after switch_root discards the initramfs root — the
    # overlay holds references to both.
    if ! mount -t overlay overlay \
        -o "lowerdir=/squash,upperdir=/persist/slot-$SLOT/upper,workdir=/persist/slot-$SLOT/work" \
        /newroot; then
      echo "slot-select: WARNING — overlay failed; binding squashfs read-only" >&2
      if [ -z "$FALLBACK_MSG" ]; then
        FALLBACK_MSG="Boot failure: overlayfs failed; rootfs is read-only (squashfs bind mount)."
      else
        FALLBACK_MSG="$FALLBACK_MSG  Also: overlayfs failed; rootfs is read-only."
      fi
      mount --bind /squash /newroot || {
        echo "slot-select: FATAL — cannot set up root" >&2
        exec /bin/sh
      }
    fi

    # ── Record boot result in the new root so /bin/slot can report it ────────
    # Both files are written into /newroot (the overlay), so they land in the
    # persist upper layer and survive reboots.
    #
    #   /var/log/boot-slot      — the slot that actually booted this time ('a'/'b')
    #   /var/log/boot-fallback  — human-readable message when a fallback occurred
    #                             (absent when the intended slot booted cleanly)
    #
    # The fallback file is cleared automatically when a new slot is activated
    # because each slot has its own fresh upper layer in the persist partition.
    mkdir -p /newroot/var/log
    printf '%s\n' "$SLOT" > /newroot/var/log/boot-slot
    if [ -n "$FALLBACK_MSG" ]; then
      printf '%s\n' "$FALLBACK_MSG" > /newroot/var/log/boot-fallback
    else
      rm -f /newroot/var/log/boot-fallback 2>/dev/null || true
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
    for cmd in sh mount umount dd switch_root sleep mdev awk mkdir cat chmod insmod mke2fs tr${lib.optionalString (cfg.swapSize > 0) " mkswap swapon"}; do
      ln -sf busybox fs/bin/$cmd
    done

    ${lib.concatMapStrings (entry: ''
      if [ -d "${entry}" ]; then
        find "${entry}" -name '*.ko' -exec cp {} fs/lib/modules/ \; 2>/dev/null || true
      elif [ -f "${entry}" ]; then
        cp "${entry}" fs/lib/modules/
      fi
      # If path doesn't exist the module is built into the kernel — skip silently.
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
    #           slot, verify its integrity, flip the slot indicator, and reboot.
    #
    # From the build host:
    #   nix build .#rootfsPartition
    #   ssh root@device upgrade < result/rootfs.squashfs
    #
    # With SHA1 verification (recommended):
    #   SHA=$(sha1sum result/rootfs.squashfs | awk '{print $1}')
    #   ssh root@device upgrade --sha1 "$SHA" < result/rootfs.squashfs
    #
    # With compression (saves transfer bandwidth):
    #   gzip -c result/rootfs.squashfs | ssh root@device "gunzip | upgrade"
    #   SHA=$(sha1sum result/rootfs.squashfs | awk '{print $1}')
    #   gzip -c result/rootfs.squashfs | ssh root@device "gunzip | upgrade --sha1 $SHA"

    OFFSET="${toString cfg.slotOffset}"
    EXPECTED_SHA1=""

    # ── Parse arguments ───────────────────────────────────────────────────────
    while [ $# -gt 0 ]; do
      case "$1" in
        --sha1)
          shift
          EXPECTED_SHA1="$1"
          shift
          ;;
        --sha1=*)
          EXPECTED_SHA1="''${1#--sha1=}"
          shift
          ;;
        --help|-h)
          echo "usage: upgrade [--sha1 <40-char-hex>]"
          echo ""
          echo "  Streams a squashfs rootfs from stdin to the inactive slot,"
          echo "  verifies the SHA1 hash (if given), flips the slot, and reboots."
          echo ""
          echo "  --sha1 <hash>   Abort if the SHA1 of the received image does"
          echo "                  not match.  The slot byte is NOT flipped on"
          echo "                  mismatch — the running system stays intact."
          exit 0
          ;;
        *)
          echo "upgrade: unknown argument: $1" >&2
          echo "usage: upgrade [--sha1 <40-char-hex>]" >&2
          exit 1
          ;;
      esac
    done

    # Validate the hash format if one was provided.
    if [ -n "$EXPECTED_SHA1" ]; then
      SHA1_LEN=$(printf '%s' "$EXPECTED_SHA1" | awk '{ print length }')
      case "$EXPECTED_SHA1" in
        *[!0-9a-fA-F]*)
          echo "upgrade: error: --sha1 must contain only hex digits (0-9, a-f)" >&2
          exit 1
          ;;
      esac
      if [ "$SHA1_LEN" != 40 ]; then
        echo "upgrade: error: --sha1 must be 40 hex characters (got $SHA1_LEN)" >&2
        exit 1
      fi
      # Normalise to lower-case for comparison.
      EXPECTED_SHA1=$(printf '%s' "$EXPECTED_SHA1" | tr 'A-F' 'a-f')
    fi

    # ── Refuse to run if stdin is a terminal ──────────────────────────────────
    if [ -t 0 ]; then
      echo "upgrade: error: no input — pipe a squashfs image into this command" >&2
      echo "  nix build .#rootfsPartition" >&2
      echo "  ssh root@device upgrade < result/rootfs.squashfs" >&2
      exit 1
    fi

    # ── Locate disk via the persist partition's ext4 label ───────────────────
    PERSIST=$(findfs LABEL="${cfg.persistLabel}" 2>/dev/null)
    if [ -z "$PERSIST" ]; then
      echo "upgrade: error: no partition with LABEL=${cfg.persistLabel}" >&2
      exit 1
    fi

    DISK=$(echo "$PERSIST" | sed -E 's/p?[0-9]+$//')
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

    # ── Stream image to the inactive slot (with optional in-flight hashing) ──
    #
    # When --sha1 is given, stdin is tee'd through a named FIFO to sha1sum
    # running in the background, while the main flow goes to dd.  Both finish
    # when stdin reaches EOF; we then compare hashes BEFORE flipping the slot
    # byte, so a corrupt or truncated transfer leaves the running system intact.
    #
    # Named FIFO approach works on BusyBox:
    #   sha1sum opens the FIFO for read (blocks until the write end is opened).
    #   tee then opens the FIFO for write (unblocks sha1sum) and starts copying.
    #   When tee closes, sha1sum sees EOF, finalises the digest, and exits.
    HASH_FIFO=""
    HASH_OUT=""

    cleanup() {
      [ -n "$HASH_FIFO" ] && rm -f "$HASH_FIFO" 2>/dev/null || true
      [ -n "$HASH_OUT"  ] && rm -f "$HASH_OUT"  2>/dev/null || true
    }
    trap cleanup EXIT INT TERM

    if [ -n "$EXPECTED_SHA1" ]; then
      echo "upgrade: streaming and hashing — do not interrupt..."
      HASH_FIFO="/tmp/upgrade-hash-fifo-$$"
      HASH_OUT="/tmp/upgrade-hash-out-$$"
      mkfifo "$HASH_FIFO"
      sha1sum "$HASH_FIFO" > "$HASH_OUT" &
      HASH_PID=$!
      tee "$HASH_FIFO" | dd of="$TARGET" bs=4M
      wait "$HASH_PID"

      COMPUTED=$(awk '{ print $1 }' "$HASH_OUT" | tr 'A-F' 'a-f')

      if [ "$COMPUTED" != "$EXPECTED_SHA1" ]; then
        echo "upgrade: HASH MISMATCH — aborting" >&2
        echo "  expected: $EXPECTED_SHA1" >&2
        echo "  computed: $COMPUTED" >&2
        echo "upgrade: slot NOT flipped — your running system is untouched" >&2
        exit 1
      fi
      echo "upgrade: sha1 OK  ($COMPUTED)"
    else
      echo "upgrade: streaming squashfs from stdin — do not interrupt..."
      dd of="$TARGET" bs=4M
    fi

    sync

    # ── Flip slot indicator ───────────────────────────────────────────────────
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
    # slot          — show running and configured slots
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
          echo "slot: already configured for slot $(echo "$TARGET" | tr a-z A-Z) — nothing to do"
          exit 0
        fi
        printf '%s' "$TARGET" | dd of="$DISK" bs=1 seek="$OFFSET" conv=notrunc 2>/dev/null
        sync
        echo "slot: next boot will use slot $(echo "$TARGET" | tr a-z A-Z) — reboot to apply"
        ;;
      "")
        # Disk byte → what the bootloader is configured to try next boot.
        CONFIGURED=$(dd if="$DISK" bs=1 skip="$OFFSET" count=1 2>/dev/null)
        [ "$CONFIGURED" = "b" ] || CONFIGURED=a

        # /var/log/boot-slot → what actually booted this session (written by initramfs).
        RUNNING=$(cat /var/log/boot-slot 2>/dev/null | tr -d '[:space:]')
        [ "$RUNNING" = "b" ] || RUNNING=a

        # Derive the standby slot (the one not currently running).
        if [ "$RUNNING" = "b" ]; then
          STANDBY=a; RUNNING_PART=$SLOT_B; STANDBY_PART=$SLOT_A
        else
          STANDBY=b; RUNNING_PART=$SLOT_A; STANDBY_PART=$SLOT_B
        fi

        # ── Boot failure / fallback warning ──────────────────────────────────
        FALLBACK=""
        if [ -f /var/log/boot-fallback ]; then
          FALLBACK=$(cat /var/log/boot-fallback)
        fi

        if [ -n "$FALLBACK" ]; then
          echo "WARNING: $FALLBACK"
          echo ""
        fi

        # ── Slot status ───────────────────────────────────────────────────────
        echo "running:    $(echo "$RUNNING" | tr a-z A-Z)  ($RUNNING_PART)"
        echo "standby:    $(echo "$STANDBY" | tr a-z A-Z)  ($STANDBY_PART)"

        # Show if the disk byte disagrees with what actually booted.
        if [ "$CONFIGURED" != "$RUNNING" ]; then
          if [ -n "$FALLBACK" ]; then
            # A fallback record exists — the configured slot genuinely failed last boot.
            echo "next boot:  $(echo "$CONFIGURED" | tr a-z A-Z)  (still pointing at failed slot — run: slot $(echo "$RUNNING" | tr a-z A-Z))"
          else
            # User has manually switched slots; not a failure.
            echo "next boot:  $(echo "$CONFIGURED" | tr a-z A-Z)  (reboot to apply)"
          fi
        fi
        ;;
      *)
        echo "usage: slot [a|b]" >&2
        exit 1
        ;;
    esac
  '';

  # ── /bin/slot-share ──────────────────────────────────────────────────────
  slotShareScript = pkgs.writeScript "slot-share" ''
    #!/bin/sh
    #
    # slot-share — hard-link files between slot A and slot B persist layers
    #
    # Both slots' writable upper directories live on the same ext4 persist
    # partition, so a hard link is literally one inode on disk — no duplicate
    # data.  Writes to the file from either slot go to the same inode and are
    # instantly visible from both.
    #
    # Usage:
    #   slot-share /etc/myapp/config     — share a file between both slots
    #   slot-share --list                — list files currently shared
    #   slot-share --unshare /etc/myapp/config  — give each slot its own copy
    #
    # Notes:
    #   • The file must already exist somewhere on the running system.
    #     If it is only in the squashfs lower layer (not yet written to the
    #     overlay upper), slot-share copies it up first.
    #   • The persist partition is mounted read-write for the duration of the
    #     command and unmounted before exit.
    #   • Hard links cannot cross filesystem boundaries, so this only works
    #     for files on the overlay (rootfs).  You cannot share files that live
    #     exclusively inside the squashfs (they are read-only there).

    PERSIST_LABEL="${cfg.persistLabel}"
    PERSIST_MNT=""

    die() { echo "slot-share: error: $*" >&2; exit 1; }

    cleanup() {
      if [ -n "$PERSIST_MNT" ]; then
        umount "$PERSIST_MNT" 2>/dev/null || true
        rmdir  "$PERSIST_MNT" 2>/dev/null || true
      fi
    }
    trap cleanup EXIT INT TERM

    # Mount the persist partition at a temporary path so we can access both
    # slot-a/upper and slot-b/upper regardless of which slot is running.
    PERSIST_DEV=$(findfs LABEL="$PERSIST_LABEL" 2>/dev/null) \
      || die "no partition with LABEL=$PERSIST_LABEL"

    PERSIST_MNT="/var/log/slot-share-$$"
    mkdir -p "$PERSIST_MNT" \
      || die "cannot create temp mount dir $PERSIST_MNT"

    mount -t ext4 "$PERSIST_DEV" "$PERSIST_MNT" \
      || die "cannot mount persist partition ($PERSIST_DEV)"

    # Which slot are we running on right now?
    CURRENT=$(cat /var/log/boot-slot 2>/dev/null | tr -d '[:space:]')
    [ "$CURRENT" = "b" ] || CURRENT=a
    [ "$CURRENT" = "b" ] && OTHER=a || OTHER=b

    CUR_UPPER="$PERSIST_MNT/slot-$CURRENT/upper"
    OTH_UPPER="$PERSIST_MNT/slot-$OTHER/upper"

    # ── Helpers ───────────────────────────────────────────────────────────────

    # Print the inode number of a file (busybox stat supports -c '%i').
    inode_of() { stat -c '%i' "$1" 2>/dev/null; }

    # Ensure a file from the running root is present in the current upper layer.
    # Overlayfs only copies up on first write; for a read-only file that has
    # never been touched, the upper entry won't exist yet.
    ensure_in_upper() {
      local rel="$1" dst="$CUR_UPPER/$1"
      if [ ! -e "$dst" ]; then
        # Source from the live root (the overlay's merged view).
        [ -e "/$rel" ] || return 1
        mkdir -p "$(dirname "$dst")"
        cp -p "/$rel" "$dst"
      fi
      return 0
    }

    case "$1" in

      # ── slot-share /path/to/file ──────────────────────────────────────────
      /*)
        FILE="$1"
        REL="''${FILE#/}"
        CUR_FILE="$CUR_UPPER/$REL"
        OTH_FILE="$OTH_UPPER/$REL"

        # Check the file actually exists (either in overlay or squashfs lower).
        [ -e "$FILE" ] || die "$FILE does not exist"

        # Ensure the file is in the current slot's upper layer.
        ensure_in_upper "$REL" \
          || die "could not copy $FILE into slot $CURRENT upper layer"

        # Already shared?
        if [ -e "$OTH_FILE" ]; then
          CI=$(inode_of "$CUR_FILE")
          OI=$(inode_of "$OTH_FILE")
          if [ -n "$CI" ] && [ "$CI" = "$OI" ]; then
            echo "slot-share: $FILE is already shared between slot A and slot B"
            exit 0
          fi
          # Other slot has a different version — replace with a hard link to ours.
          rm -f "$OTH_FILE"
        fi

        mkdir -p "$(dirname "$OTH_FILE")"
        ln "$CUR_FILE" "$OTH_FILE" \
          || die "hard link failed — are both uppers on the same filesystem?"

        echo "slot-share: $FILE is now shared (one copy, two slots)"
        ;;

      # ── slot-share --list ─────────────────────────────────────────────────
      --list|-l)
        echo "Files shared between slot-a and slot-b persist layers:"
        COUNT=0
        if [ -d "$CUR_UPPER" ] && [ -d "$OTH_UPPER" ]; then
          # Walk the current upper; compare inodes with the other upper.
          find "$CUR_UPPER" -type f | while IFS= read -r CUR_FILE; do
            REL="''${CUR_FILE#$CUR_UPPER}"
            OTH_FILE="$OTH_UPPER$REL"
            [ -e "$OTH_FILE" ] || continue
            CI=$(inode_of "$CUR_FILE")
            OI=$(inode_of "$OTH_FILE")
            [ -n "$CI" ] && [ "$CI" = "$OI" ] || continue
            echo "  $REL"
            COUNT=$(( COUNT + 1 ))
          done
        fi
        [ "$COUNT" -eq 0 ] && echo "  (none)"
        ;;

      # ── slot-share --unshare /path ────────────────────────────────────────
      --unshare|-u)
        FILE="$2"
        [ -n "$FILE" ] || { echo "usage: slot-share --unshare <path>" >&2; exit 1; }
        REL="''${FILE#/}"
        CUR_FILE="$CUR_UPPER/$REL"
        OTH_FILE="$OTH_UPPER/$REL"

        UNSHARED=0
        for SLOT_FILE in "$CUR_FILE" "$OTH_FILE"; do
          [ -f "$SLOT_FILE" ] || continue
          NLINK=$(stat -c '%h' "$SLOT_FILE" 2>/dev/null)
          if [ "''${NLINK:-1}" -gt 1 ]; then
            # Break the hard link: copy to a temp file then rename over it.
            TMP="''${SLOT_FILE}.tmp.$$"
            cp -p "$SLOT_FILE" "$TMP" && mv "$TMP" "$SLOT_FILE" \
              || { rm -f "$TMP" 2>/dev/null; die "copy failed for $SLOT_FILE"; }
            UNSHARED=$(( UNSHARED + 1 ))
          fi
        done

        if [ "$UNSHARED" -gt 0 ]; then
          echo "slot-share: $FILE unshared — each slot now has its own independent copy"
        else
          echo "slot-share: $FILE was not shared (or does not exist in a slot upper layer)"
        fi
        ;;

      ""|--help|-h)
        echo "usage: slot-share <path>              share a file between both slots"
        echo "       slot-share --list              list files currently shared"
        echo "       slot-share --unshare <path>    give each slot its own copy"
        ;;

      *)
        echo "slot-share: unrecognised argument: $1" >&2
        echo "usage: slot-share <path> | --list | --unshare <path>" >&2
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
          cp ${upgradeScript}   $out/bin/upgrade
          cp ${slotScript}      $out/bin/slot
          cp ${slotShareScript} $out/bin/slot-share
          chmod +x $out/bin/upgrade $out/bin/slot $out/bin/slot-share
        '')
      ];
    })
  ];
}
