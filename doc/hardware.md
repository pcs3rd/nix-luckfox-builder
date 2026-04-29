# Hardware support

## Supported boards

### Luckfox Pico Mini B

| Property | Value |
|---|---|
| SoC | Rockchip RV1103 |
| CPU | ARM Cortex-A7 @ 1.2 GHz |
| RAM | 64 MB |
| libc | musl (armv7l-unknown-linux-musleabihf) |
| Kernel | Rockchip downstream 5.10.x (vendor SDK) |
| Bootloader | U-Boot + Rockchip SPL (built by this repo) |
| Hardware profile | `hardware/pico-mini-b.nix` |
| Main config | `configuration.nix` |

---

## Kernel setup

The kernel, DTBs, and modules are built from the LuckfoxTECH SDK source by
`pkgs/luckfox-kernel.nix` — no pre-built binaries need to be dropped in
manually. The same SDK repository that provides U-Boot also contains the
kernel source under `sysdrv/source/kernel/`.

```sh
# Build the kernel standalone to inspect the output
nix build .#luckfox-kernel
ls result/dtbs/       # find the DTB name for your board
ls result/lib/modules/
```

The first time you build, check `result/dtbs/` to confirm the DTB filename.
The default in `hardware/pico-mini-b.nix` is
`rv1103-luckfox-pico-mini-b.dtb`. If the SDK generates a different name
(e.g. `rv1106-luckfox-pico-mini-b.dtb`), update `device.dtb` in
`hardware/pico-mini-b.nix` accordingly.

---

## Build targets

All targets are cross-compiled for ARMv7 musl from any supported host
(Apple Silicon, Intel Mac, or Linux x86_64/aarch64).

| `nix build .#<target>` | Output | Use |
|---|---|---|
| `luckfox-kernel` | `zImage` + `dtbs/` + `lib/modules/` | Kernel built from SDK source |
| `pico-mini-b` | firmware bundle dir | U-Boot + rootfs together |
| `rootfs` | rootfs directory tree | Inspect or repack manually |
| `uboot` | `SPL` + `u-boot.img` | Bootloader blobs only |
| `sdImage` | `result/sd.img` | Raw SD image |
| `sdImage-flashable` | `result/sd-flashable.img` | Flash to card with `dd` |
| `rootfsPartition` | `result/rootfs.squashfs` | Slot squashfs for `upgrade` streaming |
| `slotSelectInitramfs` | `result/initramfs-slotselect.cpio.gz` | Slot-select initramfs only |
| `spi-image` | `result/spi.img` | Raw 8 MiB SPI NOR image (SPL only) |

On Apple Silicon, prefix targets with `.#packages.aarch64-darwin.`:

```sh
nix build .#packages.aarch64-darwin.sdImage-flashable
```

---

## Flashing

### SD card (required every time without SPI bootloader)

```sh
nix build .#sdImage-flashable
sudo dd if=result/sd-flashable.img of=/dev/sdX bs=4M status=progress
```

Replace `/dev/sdX` with your SD card device (`diskutil list` on macOS,
`lsblk` on Linux).

The Pico Mini B normally boots from its onboard SPI NOR flash. To boot
from the SD card, **hold the BOOT button while plugging in USB power**, then
release it after ~1 second. The RV1103 boot ROM bypasses SPI NOR and reads
the bootloader directly from the SD card.

---

### SPI NOR flash (boot from SD card without holding BOOT)

Flashing the SPL to SPI NOR makes the board boot from SD card automatically
on every power-on. The SPI NOR only needs to hold the SPL (~200 KB); U-Boot
and the kernel remain on the SD card.

**Build both outputs:**

```sh
# The SPI image to write to flash
nix build .#spi-image
# Produces result/spi.img (8 MiB raw image, SPL at offset 0x8000)

# The raw SPL binary needed to initialise DRAM before flashing
nix build .#uboot
# Produces result/SPL  ← this is what rkdeveloptool db expects
```

> **Important:** `rkdeveloptool db` takes the **raw SPL binary** (`result/SPL`),
> not the SPI image. `result/SPL` is a miniloader the boot ROM uses to bring
> up DRAM; `result/spi.img` is the full 8 MiB image written to flash afterward.

**Flash with `rkdeveloptool`:**

```sh
# 1. Enter maskrom mode: hold BOOT, plug in USB-C, release BOOT
# 2. Verify the device is visible
rkdeveloptool ld

# 3. Flash (run nix build steps above first)
rkdeveloptool db result/SPL        # upload raw SPL to initialise DRAM
rkdeveloptool ef                   # erase SPI NOR
rkdeveloptool wf result/spi.img    # write the 8 MiB SPI image
rkdeveloptool rd                   # reset

# Install rkdeveloptool if needed:
nix-shell -p rkdeveloptool
```

After flashing, the board boots from SD card on every power-on with no
button held. To restore the factory Luckfox firmware, re-flash using the
Luckfox SDK tools via the same maskrom procedure.
