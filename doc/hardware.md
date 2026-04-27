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
| `sdImage-ab` | `result/sd-flashable.img` | A/B image — flash once, upgrade over SSH |
| `rootfsPartition` | `result/rootfs.squashfs` | Slot squashfs for `upgrade` streaming |
| `slotSelectInitramfs` | `result/initramfs-slotselect.cpio.gz` | Slot-select initramfs only |

On Apple Silicon, prefix targets with `.#packages.aarch64-darwin.`:

```sh
nix build .#packages.aarch64-darwin.sdImage-flashable
```

### Flashing

```sh
nix build .#sdImage-flashable
sudo dd if=result/sd-flashable.img of=/dev/sdX bs=4M status=progress
```

Replace `/dev/sdX` with your SD card device (`diskutil list` on macOS,
`lsblk` on Linux). The image is safe to flash to any card ≥ the image size.
