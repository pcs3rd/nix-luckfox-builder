# A/B rootfs — zero-downtime upgrades

The A/B rootfs system allows the firmware image to be updated over SSH
with no downtime and automatic rollback on failure. Each slot is a
read-only squashfs image; writes land on a separate ext4 persist
partition via overlayfs and survive reboots.

---

## How it works

```
Sector 0          MBR + partition table
Byte 512          slot indicator byte — 'a' or 'b' (raw, between MBR and SPL)

p1  ext4 "boot"    kernel + initramfs-slotselect.cpio.gz + boot.scr
p2  squashfs        slot A rootfs (read-only, compressed)
p3  squashfs        slot B rootfs (read-only, compressed)
p4  ext4 "persist"  overlayfs upper/work dirs, shared across reboots
```

### Boot sequence

1. U-Boot reads `boot.scr` from p1 and loads the kernel + slot-select initramfs.
2. The initramfs reads the raw slot indicator byte from the disk.
3. It mounts the active squashfs slot (p2 or p3) at `/squash`.
4. It mounts the persist partition (p4) at `/persist`.
5. It sets up overlayfs: lower = squashfs, upper/work in `/persist/slot-{a,b}/`.
6. `switch_root` hands control to `/sbin/init` in the overlay.

The running rootfs is read-write: reads come from squashfs (fast,
compressed, immutable), writes go to the persist partition and survive
reboots. Each slot has its own overlay directory, so upgrading to a new
slot starts with a clean writable layer.

### Fallback

If the active slot's squashfs fails to mount (e.g. corrupted upgrade),
the initramfs automatically falls back to slot A and records the failure
in `/var/log/boot-fallback`. The `/bin/slot` tool reads this file and
displays a warning on the next login.

---

## Enabling A/B

```nix
# configuration.nix
system.abRootfs.enable = true;
```

Build and flash the initial image:

```sh
nix build .#sdImage-ab
sudo dd if=result/sd-flashable.img of=/dev/sdX bs=4M status=progress
```

---

## Upgrade workflow

On the build host:

```sh
nix build .#rootfsPartition       # produces result/rootfs.squashfs
ssh root@luckfox upgrade < result/rootfs.squashfs
```

`/bin/upgrade` on the device:
1. Reads the current slot indicator to find the inactive partition.
2. Streams stdin to that partition via `dd`.
3. Atomically writes the new slot indicator.
4. Reboots into the new slot.

The persist partition is **not** cleared on upgrade. The new slot's
overlay starts empty (fresh upper layer), but the other slot's overlay
data is untouched until it becomes active again.

---

## Runtime tools

### `/bin/slot`

Show the active slot and any boot failures:

```sh
slot
# running:  A  (/dev/mmcblk0p2)
# standby:  B  (/dev/mmcblk0p3)
```

After a failed upgrade and fallback:

```sh
slot
# WARNING: Boot failure: slot B (/dev/mmcblk0p3) failed to mount; fell back to slot A.
#
# running:    A  (/dev/mmcblk0p2)
# standby:    B  (/dev/mmcblk0p3)
# next boot:  B  (still pointing at failed slot — run: slot a)
```

Force a specific slot on next boot (without rebooting):

```sh
slot a    # configure slot A for next boot
slot b    # configure slot B for next boot
```

### `/bin/upgrade`

Stream a new squashfs rootfs into the inactive slot and reboot:

```sh
ssh root@luckfox upgrade < result/rootfs.squashfs

# With compression (saves bandwidth):
gzip -c result/rootfs.squashfs | ssh root@luckfox "gunzip | upgrade"
```

### `/bin/slot-share`

Hard-link a file between slot A and slot B persist layers so both slots
share **one copy** of the data on disk. Since both upper directories
live on the same ext4 persist partition, a hard link is a single inode —
no duplication. Writes to the file from either slot update the shared
inode immediately.

```sh
# Share a config file between both slots
slot-share /etc/myapp/config

# List files currently shared
slot-share --list

# Give each slot its own independent copy again
slot-share --unshare /etc/myapp/config
```

If the file only exists in the squashfs lower layer (never been written
to the overlay), `slot-share` copies it up to the current slot's upper
layer before creating the link.

---

## Advanced options

```nix
system.abRootfs = {
  enable              = true;
  slotOffset          = 512;     # raw byte offset of the slot indicator
  bootPartLabel       = "boot";  # ext4 label of p1
  bootPartSize        = 64;      # MiB — partition 1 size
  persistLabel        = "persist";
  persistSize         = 256;     # MiB — partition 4 size
  squashfsCompression = "lz4";   # lz4 | lzo | gzip | xz | zstd
};
```

Slot partition sizes are calculated automatically from the total image
size (`system.imageSize`) after subtracting boot and persist:

```
slot size = (total - boot - persist) / 2
```

`system.imageSize` defaults to 2048 MiB.

---

## Kernel requirements

The slot-select initramfs requires:

```
CONFIG_SQUASHFS=y      (+ CONFIG_SQUASHFS_LZ4=y for lz4 compression)
CONFIG_OVERLAY_FS=y
```

If these are compiled as modules (`=m`), list them in
`system.abRootfs.extraKernelModules` so the initramfs loads them before
attempting to mount:

```nix
system.abRootfs.extraKernelModules = [
  "${kernelModulesPath}/kernel/fs/squashfs/squashfs.ko"
  "${kernelModulesPath}/kernel/fs/overlayfs/overlay.ko"
];
```
