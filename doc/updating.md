# Updating the firmware

This document covers how to build a new rootfs image and stream it to a
running device using the A/B upgrade system.

For a first-time flash from a build host (writing the initial SD card image),
see [getting-started.md](getting-started.md) instead.

---

## Prerequisites

- A device already running an image built with `system.abRootfs.enable = true`
- SSH access to the device (`ssh root@luckfox`)
- A working `nix` installation on the build host

---

## Build a new rootfs image

```sh
nix build .#rootfsPartition
# Produces: result/rootfs.squashfs
```

The resulting file is a raw squashfs image ready to be streamed directly into
the inactive slot partition on the device.

---

## Stream the update over SSH

### Basic (no verification)

```sh
ssh root@luckfox upgrade < result/rootfs.squashfs
```

### With SHA1 verification (recommended)

Compute the hash on the build host and pass it to `upgrade`. The device
verifies the received image matches before touching the slot indicator — a
corrupt or truncated transfer aborts cleanly and leaves the running system
intact.

```sh
SHA=$(sha1sum result/rootfs.squashfs | awk '{print $1}')
ssh root@luckfox upgrade --sha1 "$SHA" < result/rootfs.squashfs
```

On success you'll see:

```
upgrade: current=a  next=b  target=/dev/mmcblk0p3
upgrade: streaming and hashing — do not interrupt...
upgrade: sha1 OK  (a3f1c2...)
upgrade: activating slot B
upgrade: complete — rebooting into slot B in 3 s
```

On hash mismatch the slot byte is **not** flipped:

```
upgrade: HASH MISMATCH — aborting
  expected: a3f1c2...
  computed: 9b4e77...
upgrade: slot NOT flipped — your running system is untouched
```

### With compression

If your link has limited bandwidth, compress on the host and decompress on
the device. SHA1 is computed on the **uncompressed** image (after `gunzip`),
so pass the hash of `result/rootfs.squashfs` as usual:

```sh
SHA=$(sha1sum result/rootfs.squashfs | awk '{print $1}')
gzip -c result/rootfs.squashfs | ssh root@luckfox "gunzip | upgrade --sha1 $SHA"
```

---

## Using netcat instead of SSH (higher throughput)

TCP over a half-duplex link (such as a CC1101 or nRF24L01+ TUN/TAP tunnel)
suffers from constant direction switching as data and ACKs compete. A
unidirectional `netcat` stream avoids this and can significantly improve
transfer speed on radio links.

> **Only use this on a trusted network.** netcat transfers are unencrypted.

On the device (listen for incoming data):

```sh
nc -l -p 9000 | upgrade --sha1 <hash>
```

On the build host (send the image):

```sh
SHA=$(sha1sum result/rootfs.squashfs | awk '{print $1}')
nc -q1 <device-ip> 9000 < result/rootfs.squashfs
```

---

## Check slot status after reboot

After the device reboots, confirm it came up on the new slot:

```sh
ssh root@luckfox slot
# running:   B  (/dev/mmcblk0p3)
# standby:   A  (/dev/mmcblk0p2)
```

If the new slot fails to mount (e.g. a corrupt image that passed the SHA1
check but has a bad squashfs superblock), the initramfs automatically falls
back to the previous slot. `slot` will report the failure:

```
WARNING: Boot failure: slot B (/dev/mmcblk0p3) failed to mount; fell back to slot A.

running:    A  (/dev/mmcblk0p2)
standby:    B  (/dev/mmcblk0p3)
next boot:  B  (still pointing at failed slot — run: slot a)
```

Reset the pointer so the device doesn't keep trying the bad slot on every boot:

```sh
slot a
```

---

## Force a rollback without waiting for a failure

If the new slot boots but behaves incorrectly, you can switch back manually
without waiting for a mount failure:

```sh
slot a    # point to slot A on next boot
reboot
```

---

## Keep config files across upgrades

Each slot starts with a fresh overlay upper layer. Files written to the
running system (e.g. `/etc/myapp/config`) exist only in the current slot's
upper layer and will not be visible after upgrading to the other slot.

Use `slot-share` to hard-link a file between both slot persist layers so
both slots share one copy:

```sh
slot-share /etc/myapp/config
```

Changes from either slot are immediately visible to the other. See
[ab-rootfs.md](ab-rootfs.md) for full `slot-share` documentation.
