# SD card filesystem builder for Nintendo 3DS Linux boot.
#
# Produces a directory tree to copy onto a 3DS SD card that already has
# Luma3DS installed (the standard homebrew/CFW setup).
#
# ── Output layout ─────────────────────────────────────────────────────────────
#
#   result/
#     luma/
#       payloads/
#         firm_linux_loader.firm   ← Luma3DS chainloader payload
#     linux/
#       zImage                     ← Linux kernel (ARM11, from linux-3ds)
#       initramfs.cpio.gz          ← Rootfs packed as cpio.gz initramfs
#       cmdline.txt                ← Kernel command line for firm_linux_loader
#
# ── How to use ────────────────────────────────────────────────────────────────
#
#   nix build .#nintendo-3ds-sdcard
#
#   # macOS — SD card usually mounts at /Volumes/NO\ NAME or similar:
#   cp -r result/* /Volumes/NO\ NAME/
#
#   # Linux — SD card at /mnt/sdcard:
#   cp -r result/* /mnt/sdcard/
#
#   # Boot: hold [START] while powering on → Luma3DS chainloader
#   # → select "firm_linux_loader" → Linux boots on top screen
#
# ── Upgrading the rootfs ──────────────────────────────────────────────────────
#
# Because the entire rootfs lives in the initramfs file, upgrading is as simple
# as replacing /linux/initramfs.cpio.gz on the SD card and rebooting:
#
#   nix build .#nintendo-3ds-sdcard
#   cp result/linux/initramfs.cpio.gz /Volumes/NO\ NAME/linux/
#
# No slot-switching is needed; the new rootfs takes effect on the next boot.
# (To preserve the running system across a bad upgrade, keep a backup copy of
# initramfs.cpio.gz on the SD card and swap back if needed.)

{ pkgs, config, lib, ... }:

{
  config.system.build.sdcardFilesystem = pkgs.runCommand "nintendo-3ds-sdcard" {
    nativeBuildInputs = with pkgs.buildPackages; [ cpio gzip ];
  } ''
    mkdir -p $out/luma/payloads
    mkdir -p $out/linux

    # ── firm_linux_loader FIRM payload ───────────────────────────────────────
    # The Luma3DS chainloader target that loads our Linux kernel.
    # Goes in /luma/payloads/ so Luma3DS finds it when [START] is held.
    cp ${import ../../pkgs/firm-linux-loader.nix { inherit pkgs; }} \
       $out/luma/payloads/firm_linux_loader.firm

    # ── Linux kernel ──────────────────────────────────────────────────────────
    # ARM zImage cross-compiled for ARM11 (ARMv6K) by pkgs/nintendo-3ds-kernel.nix.
    ${lib.optionalString (config.device.kernel != null) ''
      cp ${config.device.kernel} $out/linux/zImage
      echo "kernel: $(du -sh $out/linux/zImage | cut -f1)"
    ''}

    # ── Kernel command line ────────────────────────────────────────────────────
    # firm_linux_loader reads /linux/cmdline.txt (single line, no trailing newline
    # required) and passes the contents verbatim to the kernel as bootargs.
    printf '%s' ${lib.escapeShellArg config.boot.cmdline} > $out/linux/cmdline.txt
    echo "cmdline: $(cat $out/linux/cmdline.txt)"

    # ── Rootfs initramfs ──────────────────────────────────────────────────────
    # Pack the rootfs directory into a cpio.gz initramfs.
    # firm_linux_loader loads /linux/initramfs.cpio.gz as the ramdisk and the
    # kernel unpacks it as its initial root filesystem.
    # rdinit=/sbin/init (from boot.cmdline) tells the kernel to exec busybox
    # init from the initramfs rather than looking for a real root device.
    echo "packing initramfs from ${config.system.build.rootfs} ..."
    cd ${config.system.build.rootfs}
    find . | cpio --quiet -o -H newc | gzip -9 > $out/linux/initramfs.cpio.gz
    echo "initramfs: $(du -sh $out/linux/initramfs.cpio.gz | cut -f1)"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Nintendo 3DS SD card filesystem built"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Copy to SD card (macOS):"
    echo "    cp -r $out/* /Volumes/NO\\ NAME/"
    echo ""
    echo "  Copy to SD card (Linux):"
    echo "    cp -r $out/* /mnt/sdcard/"
    echo ""
    echo "  Boot: hold [START] → Luma3DS chainloader → firm_linux_loader"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Contents:"
    find $out -type f | sort | while read f; do
      printf '    %s  (%s)\n' "''${f#$out/}" "$(du -sh "$f" | cut -f1)"
    done
  '';
}
