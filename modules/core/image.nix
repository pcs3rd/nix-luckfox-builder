{ pkgs, config, lib, ... }:

{
  config.system.build.image = pkgs.runCommand "sd.img" {
    buildInputs = [ pkgs.parted pkgs.e2fsprogs pkgs.util-linux ];
  } ''
    IMG=$out
    dd if=/dev/zero of=$IMG bs=1M count=${toString config.system.imageSize}

    parted $IMG --script mklabel msdos
    parted $IMG --script mkpart primary ext4 1MiB 100%

    LOOP=$(losetup --show -fP $IMG)
    PART=''${LOOP}p1
    sleep 1

    mkfs.ext4 $PART
    mkdir mnt
    mount $PART mnt

    cp -r ${config.system.build.rootfs}/* mnt/

    ${lib.optionalString (config.device.kernel != null) ''
      cp ${config.device.kernel} mnt/zImage
    ''}

    ${lib.optionalString (config.device.dtb != null) ''
      cp ${config.device.dtb} mnt/${config.device.name}.dtb
    ''}

    mkdir -p mnt/extlinux
    cat > mnt/extlinux/extlinux.conf << EOF
LABEL linux
  KERNEL /zImage
  ${lib.optionalString (config.device.dtb != null) "FDT /${config.device.name}.dtb"}
  APPEND ${config.boot.cmdline}
EOF

    umount mnt
    losetup -d $LOOP
  '';
}
