# Getting started

This guide walks you through building and flashing firmware to the
**Luckfox Pico Mini B** for the first time.

---

## Prerequisites

- [Nix](https://nixos.org/download) with flakes enabled
- An SD card (8 GB or larger recommended)
- A USB-C cable

Enable flakes if you haven't already:

```sh
mkdir -p ~/.config/nix
echo "experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf
```

On Apple Silicon, you also need the [nix-darwin Linux builder](https://nixos.org/manual/nix/stable/advanced-topics/distributed-builds.html) running so Nix can cross-compile for ARM.

---

## Step 1 — Build the SD image

```sh
git clone https://github.com/youruser/nix-luckfox-builder
cd nix-luckfox-builder

nix build .#sdImage-flashable
```

On Apple Silicon, prefix the target:

```sh
nix build .#packages.aarch64-darwin.sdImage-flashable
```

This produces `result/sd-flashable.img` — a raw disk image containing the
bootloader, kernel, A/B rootfs slots, and a persist partition.

---

## Step 2 — Flash the SD card

Find your SD card device:

```sh
diskutil list          # macOS
lsblk                  # Linux
```

Then write the image (replace `/dev/sdX` or `/dev/diskN` with your device):

```sh
# Linux
sudo dd if=result/sd-flashable.img of=/dev/sdX bs=4M status=progress

# macOS (unmount first)
diskutil unmountDisk /dev/diskN
sudo dd if=result/sd-flashable.img of=/dev/rdiskN bs=4m
```

---

## Step 3 — Boot from the SD card

The Pico Mini B normally boots from its onboard SPI NOR flash. To boot from
the SD card **on first use**, you must bypass SPI NOR manually:

1. Insert the flashed SD card.
2. **Hold the BOOT button** on the board.
3. Plug in USB-C power while holding BOOT.
4. Release BOOT after about 1 second.

The RV1103 boot ROM detects the button and reads the bootloader directly from
the SD card instead of SPI NOR.

---

## Step 4 — Connect to the board

By default the firmware exposes a CDC-ACM serial console over USB:

```sh
# macOS
screen /dev/tty.usbmodem* 115200

# Linux
screen /dev/ttyACM0 115200
```

The default root password is set in `configuration.nix` under
`users.root.hashedPassword`. To generate a new hash:

```sh
openssl passwd -6 yourpassword
```

SSH is also enabled (dropbear). Once the board has a network address:

```sh
ssh root@luckfox
```

---

## Optional — Flash the SPI NOR so BOOT isn't needed

Flashing a small bootloader stub (SPL) to the onboard SPI NOR lets the board
boot from SD card automatically on every power-on — no button required.

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
> not the SPI image. The two are different: `result/SPL` is a miniloader the
> boot ROM can parse to bring up DRAM; `result/spi.img` is the full 8 MiB image
> you write to the flash afterward.

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

After flashing, the board boots from SD card automatically on every
power-on. To restore the factory Luckfox firmware, re-flash using the
Luckfox SDK tools via the same maskrom procedure.

---

## Next steps

| Document | Contents |
|---|---|
| [configuration.md](configuration.md) | Customise USB, MCU, networking, zram, users |
| [services.md](services.md) | Enable SSH, mesh-bbs, meshtasticd, nrfnet, etc. |
| [ab-rootfs.md](ab-rootfs.md) | Zero-downtime upgrades over SSH |
| [packages.md](packages.md) | Add or pin packages |
| [hardware.md](hardware.md) | Full build-target reference, kernel setup |
| [qemu.md](qemu.md) | Test the firmware in QEMU before flashing |
