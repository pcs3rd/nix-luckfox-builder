# Packages

All packages live in `pkgs/` and are registered in `pkgs/default.nix`.
Reference them in `configuration.nix` via `localPkgs.<name>`.

```nix
{ pkgs, ... }:
let
  localPkgs = import ./pkgs { inherit pkgs; };
in
{
  packages = with localPkgs; [ sysinfo htop nano meshtastic-cli ];
}
```

---

## Userspace tools

| Name | Source | Notes |
|---|---|---|
| `sysinfo` | local (`pkgs/sysinfo/`) | Lightweight static C utility — CPU, RAM, uptime |
| `htop` | nixpkgs static | Interactive process viewer |
| `nano` | nixpkgs static | Terminal text editor (includes terminfo for vt100/linux) |
| `meshtastic-cli` | nixpkgs `python3.pkgs.meshtastic` | `meshtastic --info`, `--sendtext`, etc. |

---

## Meshtastic / mesh services

| Name | Source | Notes |
|---|---|---|
| `mesh-bbs` | local (`pkgs/mesh-bbs/`) | Minimal BBS + store-and-forward bot |
| `meshing-around` | [SpudGunMan/meshing-around](https://github.com/SpudGunMan/meshing-around) | Full-featured bot: weather, APRS, games, satellite passes |
| `meshtasticd` | [meshtastic/firmware](https://github.com/meshtastic/firmware) | Linux-native Meshtastic daemon |
| `companion-satellite` | [bitfocus/companion-satellite](https://github.com/bitfocus/companion-satellite) | Peripheral client for Stream Deck etc. |

---

## Radio / hardware

| Name | Source | Notes |
|---|---|---|
| `nrfnet` | [aarossig/nrfnet](https://github.com/aarossig/nrfnet) | TUN/TAP tunnel over nRF24L01+ SPI radio |
| `rf24` | [nRF24/RF24](https://github.com/nRF24/RF24) | RF24 C++ library (nrfnet build dep, not installed directly) |

---

## Board support

| Name | Source | Notes |
|---|---|---|
| `uboot` | [luckfox-eng29/luckfox-pico](https://github.com/luckfox-eng29/luckfox-pico) | U-Boot SPL + `u-boot.img` for RV1103 |
| `luckfox-kernel-modules` | [luckfox-eng29/luckfox-pico](https://github.com/luckfox-eng29/luckfox-pico) | Vendor kernel modules (`lib/modules/`) for `=m` drivers |

---

## Adding a package

1. Create `pkgs/my-tool.nix` following the pattern of an existing package.
2. Register it in `pkgs/default.nix`:
   ```nix
   my-tool = import ./my-tool.nix { inherit pkgs; };
   ```
3. Add it to `configuration.nix`:
   ```nix
   packages = with localPkgs; [ sysinfo my-tool ];
   ```

**Static vs dynamic:** Static binaries (`pkgs.pkgsStatic.foo`) are
self-contained and need no dynamic linker. Dynamic binaries also work —
shared libraries are copied into `/lib` automatically by the rootfs
builder.

### Pinning a version

Packages fetched from GitHub are pinned by rev + sha256. To update:

```sh
# Fetch the new hash
nix-prefetch-url --unpack \
  https://github.com/<owner>/<repo>/archive/<newrev>.tar.gz

# Or with nix-prefetch-github
nix-prefetch-github <owner> <repo> --rev <newrev>
```

Then update the `_REV` and `_SHA256` constants in the relevant
`pkgs/*.nix` file.
