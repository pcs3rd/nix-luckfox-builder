
{ pkgs, config, lib, ... }:

let
  rootfs = config.system.build.rootfs;
  uboot  = config.system.build.uboot;

in {
  config.system.build.rockchip = lib.mkIf config.rockchip.enable
    (pkgs.runCommand "rockchip-layout" {} ''
      OUT=$out
      mkdir -p $OUT

      echo "Generating Rockchip parameter.txt layout"

      cat > $OUT/parameter.txt << EOF
FIRMWARE_VER: 1.0
MACHINE_MODEL: Luckfox
MACHINE_ID: 0x000000
MANUFACTURER: NixOS
MAGIC: 0x5041524B
ATAG: 0x00200800
MACHINE: 0
CHECK_MASK: 0x80
PWR_HLD: 0,0,A,0,1
CMDLINE: ${config.boot.cmdline}
EOF

      echo "Creating loader placeholders"

      cp ${uboot}/SPL $OUT/loader.bin 2>/dev/null || true
      cp ${uboot}/u-boot.bin $OUT/uboot.bin 2>/dev/null || true

      echo "Rockchip bundle ready" > $OUT/manifest.txt
    '');
}
