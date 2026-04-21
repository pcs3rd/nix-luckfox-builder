
# Full Firmware Pipeline (Rockchip + U-Boot + NixOS-style)

## Outputs
- sd.img
- uboot/
- rockchip/parameter.txt
- firmware bundle

## Features
- Mode A U-Boot (vendor blobs)
- Rockchip NAND/eMMC layout generator
- NixOS-style module system

Test in Qemu:
nix build .#qemu-test

# Build Targets
git+file:///Users/rdean3/Local%20Projects/nix-luckfox-builder?ref=refs/heads/main&rev=afa7940f8ae506485ed21b6ec24a8765cfe97f66
├───apps
│   ├───aarch64-darwin
│   │   ├───qemu-overlay: app: no description
│   │   ├───qemu-test: app: no description
│   │   └───qemu-vm: app: no description
│   ├───aarch64-linux
│   │   ├───qemu-overlay: app: no description
│   │   ├───qemu-test: app: no description
│   │   └───qemu-vm: app: no description
│   ├───x86_64-darwin
│   │   ├───qemu-overlay: app: no description
│   │   ├───qemu-test: app: no description
│   │   └───qemu-vm: app: no description
│   └───x86_64-linux
│       ├───qemu-overlay: app: no description
│       ├───qemu-test: app: no description
│       └───qemu-vm: app: no description
├───defaultPackage
│   ├───aarch64-darwin: package 'firmware-package'
│   ├───aarch64-linux omitted (use '--all-systems' to show)
│   ├───x86_64-darwin omitted (use '--all-systems' to show)
│   └───x86_64-linux omitted (use '--all-systems' to show)
├───devShells
│   ├───aarch64-darwin
│   │   └───default: development environment 'nix-shell'
│   ├───aarch64-linux
│   │   └───default omitted (use '--all-systems' to show)
│   ├───x86_64-darwin
│   │   └───default omitted (use '--all-systems' to show)
│   └───x86_64-linux
│       └───default omitted (use '--all-systems' to show)
└───packages
    ├───aarch64-darwin
    │   ├───pico-mini-b: package 'firmware-package'
    │   ├───qemu-initramfs: package 'rootfs.cpio.gz'
    │   ├───qemu-overlay: package 'qemu-overlay-luckfox'
    │   ├───qemu-test: package 'qemu-test-luckfox'
    │   ├───qemu-vm: package 'qemu-vm-luckfox'
    │   ├───qemu-vm-bundle: package 'luckfox-vm-bundle'
    │   ├───qemu-vm-disk: package 'luckfox-vm.qcow2'
    │   ├───rootfs: package 'rootfs'
    │   ├───sdImage: package 'sd.img'
    │   ├───sdImage-flashable: package 'sd-flashable'
    │   └───uboot: package 'uboot'
    ├───aarch64-linux
    │   ├───pico-mini-b omitted (use '--all-systems' to show)
    │   ├───qemu-initramfs omitted (use '--all-systems' to show)
    │   ├───qemu-overlay omitted (use '--all-systems' to show)
    │   ├───qemu-test omitted (use '--all-systems' to show)
    │   ├───qemu-vm omitted (use '--all-systems' to show)
    │   ├───qemu-vm-bundle omitted (use '--all-systems' to show)
    │   ├───qemu-vm-disk omitted (use '--all-systems' to show)
    │   ├───rootfs omitted (use '--all-systems' to show)
    │   ├───sdImage omitted (use '--all-systems' to show)
    │   ├───sdImage-flashable omitted (use '--all-systems' to show)
    │   └───uboot omitted (use '--all-systems' to show)
    ├───x86_64-darwin
    │   ├───pico-mini-b omitted (use '--all-systems' to show)
    │   ├───qemu-initramfs omitted (use '--all-systems' to show)
    │   ├───qemu-overlay omitted (use '--all-systems' to show)
    │   ├───qemu-test omitted (use '--all-systems' to show)
    │   ├───qemu-vm omitted (use '--all-systems' to show)
    │   ├───qemu-vm-bundle omitted (use '--all-systems' to show)
    │   ├───qemu-vm-disk omitted (use '--all-systems' to show)
    │   ├───rootfs omitted (use '--all-systems' to show)
    │   ├───sdImage omitted (use '--all-systems' to show)
    │   ├───sdImage-flashable omitted (use '--all-systems' to show)
    │   └───uboot omitted (use '--all-systems' to show)
    └───x86_64-linux
        ├───pico-mini-b omitted (use '--all-systems' to show)
        ├───qemu-initramfs omitted (use '--all-systems' to show)
        ├───qemu-overlay omitted (use '--all-systems' to show)
        ├───qemu-test omitted (use '--all-systems' to show)
        ├───qemu-vm omitted (use '--all-systems' to show)
        ├───qemu-vm-bundle omitted (use '--all-systems' to show)
        ├───qemu-vm-disk omitted (use '--all-systems' to show)
        ├───rootfs omitted (use '--all-systems' to show)
        ├───sdImage omitted (use '--all-systems' to show)
        ├───sdImage-flashable omitted (use '--all-systems' to show)
        └───uboot omitted (use '--all-systems' to show)  

# Configuration
Make your changes in configuration.nix. THis repo includes an example that builds a rootfs with meshing-around and nrfnet running as services. 

# Claude To-Do. 
 - Package bitfocus companion satilite as a package/service.  
 - Draft/propose a more minimal alternative to meshing-around. We only really need _basic_ bbs and store & foward services for now.  
 - See what changes we eould need to make to allow this to also build for the pine64 Ox64. This sbc runs a bl808, and has 64-bit 480MHz RV64 C906 core and two 32-bit 320MHz RV32 E907 + 150MHz E902 cores, 728KB internal SRAM and 64MB internal PSRAM. We don't _need_ to add support for this, but if it isn't too hard, they're also pretty cheap.   
 - Add a helper script at /bin/mcu. This script needs to take two options: reset and bootloader. The reset option should toggle a pin to simulate a button press using a mosfet. The bootloader option needs to press reset twice. 
 - Package a version of the meshtastic python cli with the smallest footprint possible