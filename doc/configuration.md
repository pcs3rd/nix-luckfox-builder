# Configuration reference

All customisation happens in `configuration.nix`. It is a standard Nix
module — a function that receives `pkgs`, `lib`, `buildDate`, and any other
`specialArgs`, and returns an attribute set of option values.

```nix
{ pkgs, buildDate ? "unknown", ... }:

let
  localPkgs = import ./pkgs { inherit pkgs; };
in

{
  imports = [ ./hardware/pico-mini-b.nix ];

  packages = with localPkgs; [ sysinfo htop nano ];

  services.ssh.enable = true;
  # … see sections below
}
```

---

## Packages

Binaries from each package's `bin/` are copied into `/bin` on the rootfs.
Prefer `pkgs.pkgsStatic.foo` — static binaries need no dynamic linker.

```nix
packages = with localPkgs; [
  sysinfo
  htop
  nano
  meshtastic-cli
  pkgs.pkgsStatic.util-linux   # lsblk, blkid, etc.
];
```

See [packages.md](packages.md) for the full package catalogue.

---

## USB port mode

The OTG port can be forced to a specific role:

```nix
system.usb.mode = "otg";   # "host" | "device" | "otg" (default)
```

The Luckfox RV1103 role-switch sysfs path is pre-populated in
`hardware/pico-mini-b.nix`.

---

## USB gadget (serial console over USB)

When the OTG port is in `"device"` mode, the USB gadget stack exposes
virtual functions to the connected host computer.

```nix
system.usb.mode = "device";

system.usbGadget = {
  enable    = true;
  functions = [ "acm" ];         # "acm" | "ecm" | "rndis" | "mass_storage"
  product   = "Luckfox";         # string shown in lsusb on the host
};
```

`"acm"` gives a CDC-ACM virtual serial port with an automatic getty, so
you get a login shell over USB without any network setup.

Connect from the host:

```sh
# Linux
screen /dev/ttyACM0 115200
# macOS
screen /dev/cu.usbmodem* 115200
```

Multiple functions can be combined: `functions = [ "acm" "ecm" ]` gives
both a serial console and a USB Ethernet interface simultaneously.

Requires kernel `CONFIG_USB_GADGET`, `CONFIG_USB_CONFIGFS`, and the
per-function driver options. These are enabled in the Luckfox vendor
kernel when gadget support is turned on.

---

## MCU control (`/bin/mcu`)

Toggle GPIO pins via MOSFET to reset or bootload an attached MCU:

```nix
system.mcu = {
  enable        = true;
  resetPin      = 47;   # GPIO number for the RESET MOSFET gate
  bootloaderPin = -1;   # -1 = double-tap reset (RP2040 UF2 mode)
                        # Set to a GPIO number for a dedicated BOOT pin
                        # (STM32, nRF52, etc.)
};
```

```sh
mcu reset       # pulse RESET once
mcu bootloader  # enter bootloader (double-tap or BOOT + RESET)
```

---

## A/B rootfs

Zero-downtime over-SSH upgrades using squashfs slots and overlayfs.

```nix
system.abRootfs.enable = true;
```

When enabled, the SD image uses a 4-partition layout:

| Partition | Filesystem | Label | Contents |
|---|---|---|---|
| p1 | ext4 | `boot` | kernel, initramfs, boot.scr |
| p2 | squashfs | — | slot A rootfs (read-only) |
| p3 | squashfs | — | slot B rootfs (read-only) |
| p4 | ext4 | `persist` | overlayfs upper/work dirs |

See [ab-rootfs.md](ab-rootfs.md) for the full upgrade workflow and
runtime tools (`slot`, `upgrade`, `slot-share`).

---

## zram swap

Compressed RAM swap — useful on the 64 MB Luckfox board.
A 32 MB zram device yields roughly 96 MB of effective swap at
near-zero latency.

```nix
system.zram = {
  enable    = true;
  size      = "32M";
  algorithm = "lz4";   # lz4 | lzo | lzo-rle | zstd
};
```

---

## Login banner and MOTD

```nix
# /etc/issue — shown by getty before the login prompt
# Escape sequences: \n = hostname, \l = tty, \r = kernel release
system.banner = ''
  Luckfox Pico Mini B — \n  (\l)
  Kernel \r  |  Built ${buildDate}
'';

# /etc/motd — shown after successful login
system.motd = ''
  Type 'slot' to check the active A/B slot.
  Type 'upgrade < image' to update the inactive slot.
'';
```

`buildDate` is injected automatically by the flake as a `YYYY-MM-DD`
string derived from `self.lastModifiedDate` (the timestamp of the last
git commit). On a dirty tree it falls back to `"unknown"`.

---

## Networking

```nix
networking = {
  hostname    = "luckfox";
  dhcp.enable = true;        # runs udhcpc on boot
};
```

---

## Root password

```nix
# Generate a hash with: openssl passwd -6 yourpassword
users.root.hashedPassword = "$6$...";

# "!" locks the account (no password login, SSH key only)
users.root.hashedPassword = "!";
```

---

## Kernel modules

To load `=m` drivers at runtime, point `device.kernelModulesPath` at a
derivation that provides a `lib/modules/` tree:

```nix
device.kernelModulesPath = "${localPkgs.luckfox-kernel-modules}/lib/modules";
```

Build and verify the modules derivation first:

```sh
nix build .#packages.aarch64-darwin.pico-mini-b
```
