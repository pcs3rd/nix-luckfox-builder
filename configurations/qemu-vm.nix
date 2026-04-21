# QEMU VM configuration — boots from a virtio-blk QCOW2 disk image.
#
# Differences from qemu-test.nix:
#   - root= points at /dev/vda  (virtio-blk, not initramfs)
#   - SSH is enabled            (useful for long-lived sessions)
#   - nrfnet disabled           (no SPI hardware in virt machine)
#   - hostname = luckfox-vm

{ lib, ... }:

{
  imports = [ ../configuration.nix ];

  services.getty.tty = "ttyAMA0";

  networking.hostname = lib.mkForce "luckfox-vm";

  # Boot from the virtio-blk disk QEMU attaches as /dev/vda.
  boot.cmdline = lib.mkForce
    "console=ttyAMA0 root=/dev/vda rw init=/sbin/init panic=1";

  boot.uboot.enable = lib.mkForce false;
  rockchip.enable   = lib.mkForce false;
  system.zram.enable = lib.mkForce false;

  # nrfnet needs real SPI hardware — exclude from VM.
  services.nrfnet.enable = lib.mkForce false;

  # SSH makes long-lived VM sessions practical.
  services.ssh.enable = lib.mkForce true;
}
