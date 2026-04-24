# A/B rootfs — zero-downtime over-SSH upgrades without bootloader involvement.
#
# ── How it works ─────────────────────────────────────────────────────────────
#
# A single reserved byte at a fixed raw offset on the disk (default: byte 512,
# i.e. the first byte of sector 1) holds the active slot: 'a' or 'b'.
# Sector 1 sits between the MBR (sector 0) and the first bootloader stage and
# is never touched by any filesystem or bootloader on either supported board.
#
# On every boot a tiny slot-select initramfs reads that byte, mounts the
# matching rootfs partition, and exec's switch_root into it.  The bootloader
# loads one fixed thing: the kernel + this initramfs.  No U-Boot env vars,
# no fw_setenv, no CONFIG_ENV_OFFSET required.
#
# ── Board-specific disk layouts ──────────────────────────────────────────────
#
# Luckfox Pico Mini B (Rockchip RV1103):
#
#   Sector    0 (  512 B) : MBR + partition table
#   Sector    1 (  512 B) : slot indicator byte ('a' or 'b')  ← managed here
#   Sectors 2–63          : unused / reserved
#   Sector   64           : Rockchip SPL / idbloader
#   Sector 16384          : U-Boot proper
#   Sector 4096  ( 2 MiB) : ext4  rootfs A  (label: rootfs-a, /dev/mmcblk0p1)
#   Sector 4096 + A size  : ext4  rootfs B  (label: rootfs-b, /dev/mmcblk0p2)
#
#   The kernel and initramfs live in partition 1.  U-Boot always boots from
#   there; the initramfs picks the active slot by filesystem label.
#
#   Configuration:
#     system.abRootfs = {
#       enable  = true;
#       # slotLabelA / slotLabelB default to "rootfs-a" / "rootfs-b"
#     };
#
# ── Upgrade workflow ──────────────────────────────────────────────────────────
#
# On the build host:
#   nix build .#rootfsPartition          # raw ext4 image of the rootfs
#   ssh root@device upgrade < result/rootfs.ext4
#
# On the device, /bin/upgrade:
#   1. Reads current slot from the raw disk offset
#   2. Writes new rootfs to the INACTIVE partition (dd from stdin)
#   3. Atomically flips the slot byte on disk
#   4. Reboots into the new slot
#
# To inspect the active slot at runtime:   /bin/slot
#
# ── Configuration ─────────────────────────────────────────────────────────────
#
#   system.abRootfs = {
#     enable     = true;
#     slotOffset = 512;        # byte offset of the indicator (default: sector 1)
#     slotLabelA = "rootfs-a"; # ext4 label of slot A partition (default)
#     slotLabelB = "rootfs-b"; # ext4 label of slot B partition (default)
#   };
#
#   The disk device is derived at runtime from whichever partition carries
#   slotLabelA, so no hardcoded device paths are needed.
#
# The SD image builder (sdimage.nix) detects A/B and:
#   • creates two equal-size rootfs partitions
#   • writes 'a' to the slot indicator sector
#   • embeds INITRD /initramfs-slotselect.cpio.gz in extlinux.conf

{ pkgs, config, lib, ... }:

let
  cfg = config.system.abRootfs;

  # ── Slot-select init script (content baked at Nix build time) ─────────────
  # Device paths are Nix-interpolated; $SLOT/$ROOT are runtime shell variables.
  slotSelectInit = pkgs.writeScript "slot-select-init" ''
    #!/bin/sh
    mount -t proc     proc     /proc
    mount -t sysfs    sysfs    /sys
    mount -t devtmpfs devtmpfs /dev 2>/dev/null || true

    # Re-scan /sys and create any device nodes that devtmpfs may have missed.
    # This is especially important on QEMU warm resets where virtio-blk
    # enumeration can race ahead of the devtmpfs mount.
    mdev -s 2>/dev/null || true

    # Wait for at least one block device to appear in /sys/block.
    i=0
    while [ $i -lt 10 ] && [ -z "$(ls /sys/block/ 2>/dev/null)" ]; do
      sleep 1
      i=$(( i + 1 ))
    done

    # Locate partitions by filesystem label — device-name-agnostic.
    # Works for /dev/vda1, /dev/mmcblk0p1, /dev/sda1, etc.
    SLOT_A_DEV=$(blkid -t LABEL="${cfg.slotLabelA}" -o device 2>/dev/null | head -1)
    SLOT_B_DEV=$(blkid -t LABEL="${cfg.slotLabelB}" -o device 2>/dev/null | head -1)

    if [ -z "$SLOT_A_DEV" ]; then
      echo "slot-select: FATAL — no partition with LABEL=${cfg.slotLabelA}" >&2
      exec /bin/sh
    fi

    # Derive the whole disk from the partition path:
    #   /dev/vda1      → /dev/vda
    #   /dev/mmcblk0p1 → /dev/mmcblk0
    DISK=$(echo "$SLOT_A_DEV" | sed -E 's/p?[0-9]+$//')

    # Read single slot indicator byte from the reserved raw disk location.
    SLOT=$(dd if="$DISK" bs=1 skip=${toString cfg.slotOffset} count=1 2>/dev/null)

    if [ "$SLOT" = "b" ] && [ -n "$SLOT_B_DEV" ]; then
      ROOT="$SLOT_B_DEV"
    else
      ROOT="$SLOT_A_DEV"
      SLOT=a
    fi
    echo "slot-select: slot=$SLOT  disk=$DISK  root=$ROOT"

    if ! mount "$ROOT" /newroot; then
      echo "slot-select: WARNING — $ROOT failed, falling back to $SLOT_A_DEV" >&2
      mount "$SLOT_A_DEV" /newroot || {
        echo "slot-select: FATAL — cannot mount any slot; dropping to shell" >&2
        exec /bin/sh
      }
    fi

    for mnt in proc sys dev; do
      mount --move "/$mnt" "/newroot/$mnt" 2>/dev/null || true
    done

    exec switch_root /newroot /sbin/init
  '';

  # ── Slot-select initramfs (tiny cpio.gz: busybox + init script) ───────────
  slotSelectInitramfs = pkgs.runCommand "slot-select-initramfs" {
    nativeBuildInputs = with pkgs.buildPackages; [ cpio gzip ];
  } ''
    mkdir -p fs/{bin,proc,sys,dev,newroot}

    cp ${pkgs.pkgsStatic.busybox}/bin/busybox fs/bin/busybox
    chmod +x fs/bin/busybox
    for cmd in sh mount umount dd switch_root sleep mdev blkid sed mkdir head; do
      ln -sf busybox fs/bin/$cmd
    done

    cp ${slotSelectInit} fs/init
    chmod +x fs/init

    mkdir -p $out
    ( cd fs && find . | cpio -o -H newc | gzip -9 ) > $out/initramfs-slotselect.cpio.gz
  '';

  # ── /bin/upgrade ──────────────────────────────────────────────────────────
  upgradeScript = pkgs.writeScript "upgrade" ''
    #!/bin/sh
    #
    # upgrade — stream a new rootfs image from stdin to the inactive slot,
    #           flip the slot indicator, and reboot.
    #
    # From the build host:
    #   nix build .#rootfsPartition
    #   ssh root@luckfox upgrade < result/rootfs.ext4
    #
    # With compression (saves transfer time):
    #   gzip -c result/rootfs.ext4 | ssh root@luckfox "gunzip | upgrade"

    OFFSET="${toString cfg.slotOffset}"

    # Refuse to run if stdin is a terminal — a rootfs image must be piped in.
    if [ -t 0 ]; then
      echo "upgrade: error: no input detected — pipe a rootfs image into this command" >&2
      echo "  nix build .#rootfsPartition" >&2
      echo "  ssh root@luckfox upgrade < result/rootfs.ext4" >&2
      exit 1
    fi

    # Resolve slot partitions by filesystem label — works on any device name.
    SLOT_A=$(blkid -t LABEL="${cfg.slotLabelA}" -o device 2>/dev/null | head -1)
    SLOT_B=$(blkid -t LABEL="${cfg.slotLabelB}" -o device 2>/dev/null | head -1)

    if [ -z "$SLOT_A" ]; then
      echo "upgrade: error: no partition with LABEL=${cfg.slotLabelA}" >&2
      exit 1
    fi

    # Derive the whole-disk device from the slot A partition path.
    DISK=$(echo "$SLOT_A" | sed -E 's/p?[0-9]+$//')

    CURRENT=$(dd if="$DISK" bs=1 skip="$OFFSET" count=1 2>/dev/null)
    case "$CURRENT" in
      b) NEXT=a; TARGET=$SLOT_A ;;
      *) NEXT=b; TARGET=$SLOT_B ;;
    esac

    if [ -z "$TARGET" ]; then
      echo "upgrade: error: no partition with LABEL=${cfg.slotLabelB} for target slot" >&2
      exit 1
    fi

    echo "upgrade: current=$CURRENT  next=$NEXT  target=$TARGET"
    echo "upgrade: streaming rootfs from stdin — do not interrupt..."

    dd of="$TARGET" bs=4M
    sync

    echo "upgrade: activating slot $NEXT"
    printf '%s' "$NEXT" | dd of="$DISK" bs=1 seek="$OFFSET" conv=notrunc 2>/dev/null
    sync

    echo "upgrade: complete — rebooting into slot $NEXT in 3 s"
    sleep 3
    reboot
  '';

  # ── /bin/slot ─────────────────────────────────────────────────────────────
  slotScript = pkgs.writeScript "slot" ''
    #!/bin/sh
    # slot          — show active and standby slots
    # slot a        — set slot A active on next boot (no reboot)
    # slot b        — set slot B active on next boot (no reboot)
    OFFSET="${toString cfg.slotOffset}"

    # Resolve slot partitions by filesystem label — works on any device name.
    SLOT_A=$(blkid -t LABEL="${cfg.slotLabelA}" -o device 2>/dev/null | head -1)
    SLOT_B=$(blkid -t LABEL="${cfg.slotLabelB}" -o device 2>/dev/null | head -1)

    if [ -z "$SLOT_A" ]; then
      echo "slot: error: no partition with LABEL=${cfg.slotLabelA}" >&2
      exit 1
    fi

    # Derive the whole-disk device from the slot A partition path.
    DISK=$(echo "$SLOT_A" | sed -E 's/p?[0-9]+$//')

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

  # ── Standalone rootfs ext4 image (for streaming via `upgrade`) ───────────
  # Built to match the size of one slot in the A/B SD image.  The upgrade
  # script streams this from stdin with  ssh root@device upgrade < rootfs.ext4
  rootfsPartitionImage = pkgs.runCommand "rootfs-partition" {
    nativeBuildInputs = with pkgs.buildPackages; [ e2fsprogs ];
  } ''
    mkdir -p $out
    # Use 128 MiB by default; large enough for a typical NixOS-lite rootfs.
    # The upgrade script uses `dd of="$TARGET"` which writes exactly as many
    # bytes as it reads, so the partition on the device must be ≥ this size.
    PART_BYTES=$(( 128 * 1024 * 1024 ))
    dd if=/dev/zero of=$out/rootfs.ext4 bs=1 count=0 seek=$PART_BYTES 2>/dev/null
    mkfs.ext4 \
      -d ${config.system.build.rootfs} \
      -L rootfs \
      -E lazy_itable_init=0,lazy_journal_init=0 \
      $out/rootfs.ext4
  '';

in

{
  config = lib.mkMerge [
    {
      # Always set these — readOnly options with no default must have exactly
      # one definition. null when A/B is disabled, derivation when enabled.
      system.build.slotSelectInitramfs = if cfg.enable then slotSelectInitramfs else null;
      system.build.rootfsPartition     = if cfg.enable then rootfsPartitionImage else null;
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
