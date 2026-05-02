# Extending the system

---

## Adding a service

1. Create `modules/services/myservice.nix` following the pattern in
   `modules/services/mesh-bbs.nix` or `modules/services/nrfnet.nix`.

   A minimal service module looks like this:

   ```nix
   { config, lib, pkgs, ... }:

   let cfg = config.services.myservice;
   in {
     options.services.myservice = {
       enable = lib.mkEnableOption "myservice";
       # … add your options here
     };

     config = lib.mkIf cfg.enable {
       packages = [ /* any runtime packages */ ];
       services.user.myservice = {
         enable = true;
         action = "respawn";
         script = ''
           exec /bin/myservice-binary --foreground
         '';
       };
     };
   }
   ```

2. Add the file to the imports list in `modules/services/default.nix`.

3. If the service needs new top-level options, add them to
   `modules/core/options.nix`.

4. Enable the service in `configuration.nix`:

   ```nix
   services.myservice.enable = true;
   ```

---

## Repository layout

```
configuration.nix           Main system configuration (edit this)
flake.nix                   Flake outputs — packages, apps, devShells

configurations/
  qemu-test.nix             QEMU initramfs test (fast, stateless)
  qemu-vm.nix               QEMU QCOW2 disk VM
  qemu-ab.nix               QEMU A/B rootfs test (squashfs + overlayfs)
  sdimage.nix               Flashable SD image with overlayfs
  sdimage.nix               Flashable SD image (layout from system.abRootfs.enable)

hardware/
  pico-mini-b.nix           Luckfox Pico Mini B hardware profile

pkgs/
  default.nix               Package registry
  sysinfo/                  Lightweight system-info utility (C, static)
  mesh-bbs/                 Minimal Meshtastic BBS + store-and-forward bot
  meshing-around.nix        Full-featured Meshtastic bot
  meshtastic-cli.nix        Meshtastic Python CLI wrapper
  meshtasticd.nix           Linux-native Meshtastic daemon
  companion-satellite.nix   Bitfocus Companion Satellite client
  nrfnet.nix                nRF24L01+ TUN/TAP tunnel
  rf24.nix                  RF24 C++ library (nrfnet build dep)
  uboot.nix                 U-Boot SPL + u-boot.img for RV1103
  luckfox-kernel-modules.nix Vendor kernel modules for =m drivers
  htop.nix                  htop
  nano.nix                  nano

modules/
  core/
    options.nix             All Nix module option declarations
    rootfs.nix              Rootfs directory builder
    sdimage.nix             Flashable SD image builder (single + A/B)
    ab-rootfs.nix           A/B system: initramfs, /bin/upgrade, /bin/slot, /bin/slot-share
    mcu.nix                 /bin/mcu GPIO control helper
    usb.nix                 USB OTG role switch
    usb-gadget.nix          USB gadget stack (CDC-ACM, ECM, RNDIS, mass_storage)
    firmware.nix            Firmware bundle builder
    image.nix               Raw disk image builder
    uboot.nix               U-Boot integration
    rockchip.nix            Rockchip parameter.txt + idbloader
    networking.nix          Hostname + network interface setup
    services.nix            services.user wiring into /etc/inittab
  services/
    default.nix             Service module registry (imports all service files)
    mesh-bbs.nix            mesh-bbs service
    meshing-around.nix      meshing-around service
    meshtasticd.nix         meshtasticd service
    nrfnet.nix              nrfnet service
    companion-satellite.nix Companion Satellite service
    ssh.nix                 dropbear SSH service
    getty.nix               Serial console (busybox getty)
    zram.nix                zram swap
  networking/
    dhcp.nix                udhcpc DHCP client

lib/
  mkSystem.nix              Module system evaluator (wraps lib.evalModules)

doc/                        Documentation (you are here)
```
