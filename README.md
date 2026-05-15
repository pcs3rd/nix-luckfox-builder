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

## How to update the Luckfox firmware

Once a device is running, you can push new firmware over SSH without
touching the SD card. The A/B rootfs system writes to the inactive slot and
reboots atomically — if something goes wrong it falls back automatically.

**1. Edit `configuration.nix`** — change packages, services, or settings.

**2. Build the new rootfs on your Mac/Linux host:**

```sh
nix build .#rootfsPartition
# produces: result/rootfs.squashfs
```

**3. Stream it to the device:**

```sh
# Recommended — verify the image wasn't corrupted in transit
SHA=$(sha1sum result/rootfs.squashfs | awk '{print $1}')
ssh root@luckfox upgrade --sha1 "$SHA" < result/rootfs.squashfs
```

The device writes to the inactive slot, flips the boot pointer, and reboots.
After it comes back up, confirm the new slot is active:

```sh
ssh root@luckfox slot
# running:  B  (/dev/mmcblk0p3)
# standby:  A  (/dev/mmcblk0p2)
```

**Roll back** at any time: `ssh root@luckfox "slot a && reboot"`

> For compression, netcat transfers over radio links, and `slot-share` for
> persisting config across upgrades, see **[doc/updating.md](doc/updating.md)**.

---

## How to update Meshtastic firmware on an attached nRF52 device

The Luckfox can flash a connected Meshtastic device (Heltec T114 or similar
nRF52840 board) over UART using `adafruit-nrfutil` — no USB cable or separate
computer required.

### Prerequisites

Enable `adafruit-nrfutil` in `configuration.nix` and reflash the Luckfox:

```nix
packages = with localPkgs; [
  # ... other packages ...
  adafruit-nrfutil
];
```

Wire the T114 UART to the Luckfox GPIO header:

```
T114 TX  →  Luckfox RX  (UART1_RX)
T114 RX  →  Luckfox TX  (UART1_TX)
T114 RST →  Luckfox GPIO 145  (direct wire, no MOSFET needed)
GND      →  GND  (shared between both boards)
```

### Get the firmware

Download the latest Meshtastic `.zip` for the T114 from the
[Meshtastic releases page](https://github.com/meshtastic/firmware/releases).
Copy it to the Luckfox over SSH:

```sh
scp firmware-heltec-t114-2.x.x.xxxxxxx.zip root@luckfox:/tmp/
```

### Flash over UART

SSH in and run:

```sh
ssh root@luckfox

# Put the T114 into DFU bootloader mode (double-tap reset)
mcu bootloader

# Flash — adjust the port and filename as needed
adafruit-nrfutil dfu serial \
  -pkg /tmp/firmware-heltec-t114-2.x.x.xxxxxxx.zip \
  -p /dev/ttyS1 \
  -b 115200
```

The flash takes 1–2 minutes. The T114 reboots automatically when done.

### Verify

```sh
meshtastic --port /dev/ttyS1 --info
```

You should see the new firmware version in the output.

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
