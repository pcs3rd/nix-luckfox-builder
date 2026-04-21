
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


# Configuration
Make your changes in configuration.nix. THis repo includes an example that builds a rootfs with meshing-around and nrfnet running as services. 