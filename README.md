# nix-luckfox-builder

A NixOS-style firmware builder for small RISC-V and ARM Linux SBCs.
Produces flashable SD card images, rootfs trees, and QEMU test environments
from a single declarative `configuration.nix`.

Supported boards:
- **Luckfox Pico Mini B** — Rockchip RV1103, ARMv7 musl
- **Pine64 Ox64** — Bouffalo BL808, RV64 musl *(see setup note below)*

---

## Quick start

```sh
# Clone
git clone https://github.com/youruser/nix-luckfox-builder
cd nix-luckfox-builder

# Edit configuration.nix, then build and flash
nix build .#sdImage-flashable
dd if=result/sd-flashable.img of=/dev/sdX bs=4M status=progress

# Or test in QEMU first (no real hardware needed)
nix run .#qemu-test
```

---

## Supported devices

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
| Configuration | `configuration.nix` |

**Kernel setup:** The vendor kernel and DTB are not built by Nix — they come
from the Luckfox SDK. Drop them in `hardware/kernel/` and uncomment the paths
in `hardware/pico-mini-b.nix`. Until then, the rootfs and U-Boot still build
fine; only the SD image step is skipped.

```sh
# Get the SDK kernel (run on a Linux machine or use the Docker image)
git clone https://github.com/luckfox-eng29/luckfox-pico
cd luckfox-pico && ./build.sh lunch   # select Pico Mini B
# outputs: output/image/zImage, output/image/luckfox-pico-mini-b.dtb
```

**Build targets:**

| `nix build .#<target>` | Output | Use |
|---|---|---|
| `sdImage-flashable` | `result/sd-flashable.img` | Flash to SD card with `dd` |
| `pico-mini-b` | firmware bundle dir | U-Boot + rootfs together |
| `rootfs` | rootfs directory tree | Inspect or repack manually |
| `sdImage` | `result/sd.img` | Alternative raw image format |
| `uboot` | `result/SPL` + `u-boot.img` | Bootloader blobs only |

Replace `<target>` with `.#packages.aarch64-darwin.<target>` when building
from Apple Silicon, or `.#packages.x86_64-linux.<target>` from Linux.

---

### Pine64 Ox64 *(experimental)*

| Property | Value |
|---|---|
| SoC | Bouffalo BL808 |
| CPU | RV64GCV (C906) @ 480 MHz (Linux core) |
| RAM | 64 MB PSRAM |
| libc | musl (riscv64-unknown-linux-musl) |
| Kernel | OpenBouffalo buildroot v1.0.1 (Linux 6.x) |
| Bootloader | OpenBouffalo U-Boot (pre-flashed on SD p1) |
| Hardware profile | `hardware/ox64.nix` |
| Configuration | `configurations/ox64.nix` |

**One-time kernel setup:** The kernel Image and DTB are fetched from the
OpenBouffalo GitHub release and pinned by SHA256 hash. Run this once to
register the hash, then you never need to touch it again:

```sh
nix-prefetch-url --unpack \
  https://github.com/openbouffalo/buildroot_bouffalo/releases/download/v1.0.1/bl808-linux-pine64_ox64_full_defconfig.tar.gz
# Paste the printed hash into BUILDROOT_SHA256 in pkgs/ox64-firmware.nix
```

**SD card layout:** The Ox64 boots from a two-partition SD card.
Use the OpenBouffalo `sdcard.img` for partition 1 (FAT32 boot + U-Boot),
then write the Nix rootfs image to partition 2:

```sh
# Write OpenBouffalo boot partition (provides U-Boot + pre-loaders)
dd if=sdcard.img of=/dev/sdX bs=4M status=progress

# Overwrite partition 2 with the Nix rootfs
nix build .#packages.aarch64-darwin.ox64-image
dd if=result/sd.img of=/dev/sdX2 bs=4M status=progress
```

**Build targets:**

| `nix build .#<target>` | Output | Use |
|---|---|---|
| `ox64-rootfs` | rootfs directory tree | Inspect or repack |
| `ox64-image` | `result/sd.img` | Write to SD partition 2 |
| `ox64-firmware` | kernel Image + DTB + blobs | Fetched blobs only |

---

## QEMU targets

No real hardware needed. All QEMU targets emulate an ARMv7 Cortex-A7
(`qemu-system-arm -M virt`) using a nixpkgs cross-compiled kernel.

| Command | What it does |
|---|---|
| `nix run .#qemu-test` | Boot initramfs in QEMU (stateless, fast) |
| `nix run .#qemu-vm` | Boot from QCOW2 disk with ephemeral overlay |
| `nix run .#qemu-overlay` | Boot rootfs.img with ephemeral QCOW2 overlay |
| `nix build .#qemu-vm-bundle` | Build a portable dir with QCOW2 + kernel + `run.sh` |
| `nix build .#qemu-vm-disk` | Build standalone compressed QCOW2 image |
| `nix build .#qemu-initramfs` | Build initramfs cpio.gz only |

SSH forwarding is set up automatically on a random free port; the port number
is printed at startup. Exit QEMU with **Ctrl-A X**.

---

## Configuration

All customisation happens in `configuration.nix`. The file is structured in
sections — hardware, packages, system, services, networking, users.

```nix
{ pkgs, ... }:
let localPkgs = import ./pkgs { inherit pkgs; };
in {
  imports = [ ./hardware/pico-mini-b.nix ];  # or ./hardware/ox64.nix

  packages = with localPkgs; [ sysinfo htop nano meshtastic-cli ];

  system.usb.mode = "host";   # "host" | "device" | "otg"

  services."mesh-bbs".enable = true;
  # … see sections below
}
```

### USB port mode

The OTG port on each board can be forced to a specific role:

```nix
system.usb = {
  mode           = "host";   # "host" | "device" | "otg" (default: otg)
  roleSwitchPath = null;     # auto-detected; override if needed
};
```

The Luckfox RV1103 role switch path (`fcd00000.usb-role-switch`) is
pre-populated in `hardware/pico-mini-b.nix`. The Ox64 path is auto-detected.

### USB gadget / serial console

When the OTG port is in device mode, the USB gadget stack can expose virtual
functions to the connected host computer. The most useful for embedded work is
`acm` — a CDC-ACM virtual serial port that gives you a login shell over USB
without needing any network.

```nix
system.usb.mode = "device";   # put the port in device mode first

system.usbGadget = {
  enable    = true;
  functions = [ "acm" ];      # "acm" | "ecm" | "rndis" | "mass_storage"
  product   = "My Luckfox";   # string shown in lsusb on the host
};
```

When `"acm"` is in `functions`, a getty is automatically spawned on
`/dev/ttyGS0` so the device presents a login prompt over the USB serial port.
On the host, connect with:

```sh
# Linux
screen /dev/ttyACM0 115200
# macOS
screen /dev/cu.usbmodem* 115200
```

Multiple functions can be combined if your kernel has the composite gadget
driver: `functions = [ "acm" "ecm" ]` gives both a serial console and a USB
Ethernet interface simultaneously.

Requires kernel `CONFIG_USB_GADGET`, `CONFIG_USB_CONFIGFS`, and the
per-function options (`CONFIG_USB_CONFIGFS_SERIAL` for ACM, etc.). These are
present in the Luckfox vendor kernel (5.10) when gadget support is enabled.

### MCU control (`/bin/mcu`)

Toggle GPIO pins via MOSFET to reset or bootload an attached MCU:

```nix
system.mcu = {
  enable        = true;
  resetPin      = 47;  # GPIO number for RESET MOSFET gate
  bootloaderPin = -1;  # -1 = double-tap reset (RP2040 UF2)
                       # Set to a GPIO number for dedicated BOOT pin (STM32/nRF)
};
```

```sh
mcu reset       # pulse RESET once
mcu bootloader  # double-tap RESET, or hold BOOT + pulse RESET
```

### Services

#### mesh-bbs

A minimal Meshtastic BBS + store-and-forward bot. Commands are sent as direct
messages to the bot node.

```nix
services."mesh-bbs" = {
  enable        = true;
  interface.type       = "serial";          # or "tcp"
  interface.serialPort = "/dev/ttyACM0";   # or /dev/ttyUSB0
  # interface.host     = "192.168.1.x";    # for tcp mode
  channel       = 0;     # Meshtastic channel index to monitor (0-7)
  listLimit     = 10;    # max posts returned by `bbs list`
  maxMessageLen = 200;   # bytes per LoRa chunk (max ~230)
  dataDir       = "/var/lib/mesh-bbs";
};
```

**Commands (direct message to the bot):**

| Command | Action |
|---|---|
| `bbs list` | List last N posts |
| `bbs read N` | Read post #N in full |
| `bbs post TEXT` | Post TEXT to the BBS |
| `snf send !nodeId TEXT` | Queue TEXT for an offline node |
| `snf list` | Show messages queued for you |
| `snf pending` | Show all pending deliveries (admin) |

#### meshing-around

Full-featured Meshtastic bot (weather, APRS, games, satellite passes, …).
Use `mesh-bbs` above for a leaner alternative.

```nix
services."meshing-around" = {
  enable = true;
  interface.type       = "serial";
  interface.serialPort = "/dev/ttyACM0";
};
```

#### nrfnet

TUN/TAP network tunnel over nRF24L01+ SPI radio. Setting `enable = true`
installs `/bin/nrfnet` but does **not** auto-start the daemon — run it
manually or add it as a user service.

```nix
services.nrfnet = {
  enable    = true;
  role      = "primary";         # or "secondary"
  spiDevice = "/dev/spidev0.0";
  channel   = 42;                # RF channel (0-125)
};
```

#### meshtasticd

Linux-native Meshtastic daemon. Turns the SBC itself into a Meshtastic mesh node.

```nix
services.meshtasticd = {
  enable     = true;
  # configFile = ./meshtasticd-config.yaml;
};
```

#### SSH (dropbear)

```nix
services.ssh.enable = true;
users.root.hashedPassword = "…";  # openssl passwd -6 yourpassword
```

#### Bitfocus Companion Satellite

Connects USB HID devices (Stream Deck, etc.) attached to this board to a
remote Companion server on the network.

```nix
services.companion-satellite = {
  enable = true;
  host   = "192.168.1.100";   # Companion server IP
  port   = 16622;
};
```

**Note:** The derivation builds from source using a cross-compiled musl
Node.js (official pre-built releases are glibc-linked and won't run on this
rootfs). 

### zram swap

```nix
system.zram = {
  enable    = true;
  size      = "32M";        # 32 M zram ≈ 96 MB effective swap (3:1 compression)
  algorithm = "lz4";        # lz4 | lzo | lzo-rle | zstd
};
```

### Root password

```nix
users.root.hashedPassword = "!";  # locked (default)
# Generate: openssl passwd -6 yourpassword
```

---

## Available packages

All packages live in `pkgs/` and are registered in `pkgs/default.nix`.
Reference them in `configuration.nix` via `localPkgs.<name>`.

### Userspace tools

| Name | Version | Source | Notes |
|---|---|---|---|
| `sysinfo` | 1.0 | local | Lightweight static C utility — CPU, RAM, uptime |
| `htop` | 3.5.0 | nixpkgs static | Interactive process viewer |
| `nano` | nixpkgs | nixpkgs static | Terminal text editor (includes terminfo for vt100/linux) |
| `meshtastic-cli` | nixpkgs | nixpkgs `python3.pkgs.meshtastic` | Minimal Meshtastic CLI — `meshtastic --info`, `--sendtext`, etc. |

### Meshtastic / mesh services

| Name | Version | Source | Notes |
|---|---|---|---|
| `mesh-bbs` | 0.1.0 | local | Minimal BBS + store-and-forward bot; only `meshtastic` + `pypubsub` deps |
| `meshing-around` | unstable-`9fe580a3` | [SpudGunMan/meshing-around](https://github.com/SpudGunMan/meshing-around) @ `9fe580a3` | Full-featured bot: weather, APRS, games, satellite passes |
| `meshtasticd` | 2.5-luckfox | [meshtastic/firmware](https://github.com/meshtastic/firmware) @ `d50caf23` | Linux-native Meshtastic daemon (turns SBC into a mesh node) |
| `companion-satellite` | `97e9a870` | [bitfocus/companion-satellite](https://github.com/bitfocus/companion-satellite) @ `97e9a870` | Peripheral client — connects USB HID devices to Companion server |

### Radio / hardware

| Name | Version | Source | Notes |
|---|---|---|---|
| `nrfnet` | unstable-`934b34ef` | [aarossig/nrfnet](https://github.com/aarossig/nrfnet) @ `934b34ef` | TUN/TAP tunnel over nRF24L01+ SPI radio |
| `rf24` | `436c9eae` | [nRF24/RF24](https://github.com/nRF24/RF24) @ `436c9eae` | RF24 C++ library (nrfnet build dependency, not installed directly) |

### Board support

| Name | Version | Source | Notes |
|---|---|---|---|
| `uboot` | 2024.01-luckfox | [luckfox-eng29/luckfox-pico](https://github.com/luckfox-eng29/luckfox-pico) @ `438d5270` | U-Boot SPL + `u-boot.img` for RV1103 |
| `luckfox-kernel-modules` | 5.10-luckfox | [luckfox-eng29/luckfox-pico](https://github.com/luckfox-eng29/luckfox-pico) @ `438d5270` | Vendor kernel modules (`lib/modules/`) for `=m` drivers |
| `ox64-firmware` | v1.0.1 | [openbouffalo/buildroot_bouffalo](https://github.com/openbouffalo/buildroot_bouffalo) | Ox64 kernel Image + DTB + M0/D0 pre-loader blobs; fetched by hash |

> **Updating a pinned package:** Change the `_REV` constant in the relevant
> `pkgs/*.nix` file, then run `nix-prefetch-github <owner> <repo> --rev <newrev>`
> (or `nix-prefetch-url --unpack <url>` for tarball sources) and paste the new
> hash into the corresponding `_SHA256` constant.

---

## Adding packages

Drop a Nix derivation in `pkgs/` and register it in `pkgs/default.nix`:

```nix
# pkgs/default.nix
my-tool = import ./my-tool.nix { inherit pkgs; };
```

Then reference it in `configuration.nix`:

```nix
packages = with localPkgs; [ sysinfo my-tool ];
```

Static binaries (`pkgs.pkgsStatic.foo`) are self-contained and need no
dynamic linker. Dynamic binaries work too — shared libraries are copied into
`/lib` automatically.

---

## Adding a service

1. Create `modules/services/myservice.nix` following the pattern in
   `modules/services/mesh-bbs.nix` or `modules/services/nrfnet.nix`.
2. Add it to the imports list in `modules/services/default.nix`.
3. Add any options to `modules/core/options.nix`.
4. Enable it in `configuration.nix`.

---

## Repository layout

```
configuration.nix          Main system configuration (edit this)
configurations/
  qemu-test.nix            QEMU initramfs test config
  qemu-vm.nix              QEMU disk-image VM config
  sdimage.nix              Flashable SD image with overlayfs
  ox64.nix                 Pine64 Ox64 (BL808 RV64) config
hardware/
  pico-mini-b.nix          Luckfox Pico Mini B hardware profile
  ox64.nix                 Pine64 Ox64 hardware profile
pkgs/
  default.nix              Package registry
  mesh-bbs/                Minimal Meshtastic BBS + SNF bot
  meshing-around.nix       Full-featured Meshtastic bot
  companion-satellite.nix  Bitfocus Companion Satellite client
  meshtastic-cli.nix       Minimal meshtastic Python CLI
  nrfnet.nix               nRF24L01+ TUN/TAP tunnel
  rf24.nix                 RF24 library (nrfnet dep)
  meshtasticd.nix          Linux-native Meshtastic daemon
  uboot.nix                U-Boot for RV1103
  ox64-firmware.nix        OpenBouffalo kernel/DTB fetcher
  sysinfo/                 Lightweight system-info tool (C)
  htop.nix                 htop
  nano.nix                 nano
modules/
  core/
    options.nix            All Nix module options
    rootfs.nix             Rootfs builder
    sdimage.nix            Flashable SD image builder
    mcu.nix                /bin/mcu GPIO helper
    usb.nix                USB OTG role switch
    usb-gadget.nix         USB gadget stack (CDC-ACM console, ECM, RNDIS, mass storage)
    firmware.nix           Firmware bundle builder
    image.nix              Raw disk image builder
    uboot.nix              U-Boot integration
    rockchip.nix           Rockchip parameter.txt generator
    networking.nix         Hostname + interface setup
    services.nix           services.user wiring into inittab
  services/
    default.nix            Service module registry
    mesh-bbs.nix           mesh-bbs service
    meshing-around.nix     meshing-around service
    meshtasticd.nix        meshtasticd service
    nrfnet.nix             nrfnet service
    companion-satellite.nix Companion Satellite service
    ssh.nix                dropbear SSH
    getty.nix              Serial console
    zram.nix               zram swap
  networking/
    dhcp.nix               udhcpc DHCP client
lib/
  mkSystem.nix             Module system evaluator
flake.nix                  Flake outputs (packages, apps, devShells)
```
