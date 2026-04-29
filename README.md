# nix-luckfox-builder

A NixOS-style firmware builder for the **Luckfox Pico Mini B** (Rockchip RV1103, ARMv7 musl).
Produces flashable SD card images, rootfs trees, and QEMU test environments
from a single declarative `configuration.nix`.

---

## Quick start

```sh
# Clone
git clone https://github.com/youruser/nix-luckfox-builder
cd nix-luckfox-builder

# Build and flash
nix build .#sdImage-flashable
sudo dd if=result/sd-flashable.img of=/dev/sdX bs=4M status=progress

# Or test in QEMU first — no hardware needed
nix run .#qemu-test

# Zero-downtime upgrades over SSH (A/B rootfs)
nix build .#rootfsPartition
ssh root@luckfox upgrade < result/rootfs.squashfs  # stream future upgrades
```

See **[doc/getting-started.md](doc/getting-started.md)** for full flashing
instructions, including how to boot from SD card and optionally flash the SPI
NOR so the BOOT button is no longer needed.

---

## Documentation

| Document | Contents |
|---|---|
| [doc/getting-started.md](doc/getting-started.md) | First-time build, SD card flashing, SPI NOR setup |
| [doc/hardware.md](doc/hardware.md) | Supported boards, kernel setup, build targets |
| [doc/configuration.md](doc/configuration.md) | configuration.nix reference — USB, MCU, zram, networking, users |
| [doc/services.md](doc/services.md) | Service options — SSH, getty, mesh-bbs, meshtasticd, nrfnet, companion-satellite |
| [doc/updating.md](doc/updating.md) | Streaming firmware updates — SHA1 verification, netcat, rollback |
| [doc/ab-rootfs.md](doc/ab-rootfs.md) | A/B rootfs — upgrade workflow, slot/upgrade/slot-share tools, fallback |
| [doc/packages.md](doc/packages.md) | Package catalogue, adding packages, pinning versions |
| [doc/qemu.md](doc/qemu.md) | QEMU test modes, A/B upgrade testing, reset |
| [doc/extending.md](doc/extending.md) | Adding services, full repository layout |

---

## Key features

**Declarative configuration** — hardware, packages, services, and networking
are all described in `configuration.nix` and rebuilt reproducibly by Nix.

**A/B rootfs with overlayfs** — squashfs slot partitions keep the rootfs
immutable and compressed; writes go to a persist ext4 partition via
overlayfs. Upgrading writes to the inactive slot and reboots atomically.
A bad upgrade falls back automatically with a clear error in `slot`.

**`slot-share`** — hard-link config files between slot persist layers so
both slots share a single copy on disk. Writes from either slot update the
shared inode immediately.

**QEMU test environment** — the full boot path (slot-select initramfs,
squashfs mounts, overlayfs, upgrade workflow) runs in QEMU on any Linux
host, including Apple Silicon via nix-darwin Linux builder.

**Static busybox rootfs** — no systemd, no glibc, no dynamic linker
required. The base system fits in a few megabytes of squashfs.
