# QEMU testing

No real hardware needed. All QEMU targets emulate an ARMv7 Cortex-A7
(`qemu-system-arm -M virt`) using a nixpkgs cross-compiled kernel.
SSH forwarding is set up automatically on a random free port; the port
is printed at startup. Exit QEMU with **Ctrl-A X**.

> **Darwin note:** The QEMU targets require building an ARM Linux kernel,
> which must happen on a Linux host. On Apple Silicon, configure a
> nix-darwin Linux builder first. On Intel Mac, a remote Linux builder
> is required. On Linux hosts, all targets build natively.

---

## Available QEMU targets

| Command | Description |
|---|---|
| `nix run .#qemu-test` | Boot read-only ext4 rootfs via virtio-blk (fast, stateless) |
| `nix run .#qemu-vm` | Boot from QCOW2 disk with ephemeral writes (clean on exit) |
| `nix run .#qemu-overlay` | Boot rootfs.img with a temporary QCOW2 overlay |
| `nix run .#qemu-ab` | Full A/B boot path — slot-select initramfs, squashfs slots, overlayfs |
| `nix build .#qemu-vm-bundle` | Portable directory: QCOW2 + kernel + `run.sh` |
| `nix build .#qemu-vm-disk` | Standalone compressed QCOW2 image |
| `nix build .#qemu-ab-disk` | Raw A/B SD image (MBR + 4 partitions) |
| `nix build .#qemu-ab-rootfs` | Squashfs rootfs for streaming via `upgrade` |

---

## Simple tests (`qemu-test`, `qemu-vm`, `qemu-overlay`)

These three modes are good for quickly verifying package and service
changes before committing to an A/B image build.

```sh
# Fastest: read-only rootfs, no state
nix run .#qemu-test

# Writable disk — changes persist until QEMU exits
nix run .#qemu-vm

# Writable overlay on top of a raw image
nix run .#qemu-overlay
```

SSH into whichever is running:

```sh
ssh root@localhost -p <printed-port>
```

---

## A/B rootfs testing (`qemu-ab`)

`nix run .#qemu-ab` exercises the full A/B upgrade path — the same
slot-select initramfs, squashfs slot partitions, overlayfs persist layer,
`/bin/upgrade`, `/bin/slot`, and `/bin/slot-share` that run on real
hardware, but targeting a virtio-blk disk instead of an SD card.

The QCOW2 overlay at `~/.cache/luckfox-ab.qcow2` persists across QEMU
runs so slot flips and rootfs upgrades accumulate. Pass `--reset` to
start fresh from slot A.

### Disk layout

```
Sector 0          MBR + partition table
Byte 512          slot indicator ('a' or 'b') — raw byte between MBR and SPL
p1  ext4 "boot"   kernel + initramfs + boot.scr
p2  squashfs      slot A rootfs (read-only, compressed)
p3  squashfs      slot B rootfs (read-only, compressed)
p4  ext4 "persist" overlayfs upper/work dirs — survives reboots
```

### Testing an upgrade

```sh
# Terminal 1 — start the VM (prints SSH port)
nix run .#qemu-ab

# Terminal 2 — check current slot
ssh root@localhost -p <port> slot
# running:  A  (/dev/vdap2)
# standby:  B  (/dev/vdap3)

# Build a new rootfs squashfs and stream it over SSH
nix build .#qemu-ab-rootfs
ssh root@localhost -p <port> upgrade < result/rootfs.squashfs
# VM reboots automatically into slot B

# Reconnect and confirm the flip
ssh root@localhost -p <port> slot
# running:  B  (/dev/vdap3)
# standby:  A  (/dev/vdap2)
```

### Testing a bad upgrade (fallback)

```sh
# Pipe zeros — intentionally corrupt the inactive slot
dd if=/dev/zero bs=1M count=64 | ssh root@localhost -p <port> upgrade
# VM reboots; slot-select detects the bad squashfs and falls back to A

ssh root@localhost -p <port> slot
# WARNING: Boot failure: slot B (/dev/vdap3) failed to mount; fell back to slot A.
#
# running:    A  (/dev/vdap2)
# standby:    B  (/dev/vdap3)
# next boot:  B  (still pointing at failed slot — run: slot a)

# Fix the indicator to match what actually booted
ssh root@localhost -p <port> slot a
```

### Resetting to a clean state

```sh
nix run .#qemu-ab -- --reset
```

This deletes the QCOW2 overlay and recreates it from the freshly-built
base image, returning to slot A with empty persist.
