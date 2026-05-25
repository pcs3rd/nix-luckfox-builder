# Nintendo 3DS hardware board module.
#
# Analogous to luckfox-board.nix.  Sets all hardware-specific configuration
# for the Nintendo 3DS family (Old 3DS, New 3DS, 2DS, and variants):
#
#   - kernel:   linux-3ds fork, cross-compiled for ARMv6 (ARM11 MPCore)
#   - console:  tty0 (framebuffer — top screen shows kernel log)
#   - cmdline:  suitable for firm_linux_loader initramfs boot
#   - hostname: nintendo-3ds
#   - disabled: Rockchip SPL/U-Boot, USB gadget, MCU control, A/B rootfs
#
# ── Usage in configuration.nix ───────────────────────────────────────────────
#
#   nintendo3ds.support = true;
#
# ── Boot chain ────────────────────────────────────────────────────────────────
#
#   3DS power-on
#     → Boot9 (ARM9 boot ROM)
#     → Luma3DS (CFW, hold [START] to enter chainloader)
#     → firm_linux_loader.firm  (our payload in /luma/payloads/)
#     → /linux/zImage + /linux/initramfs.cpio.gz  (from SD card)
#     → busybox init
#
# ── Hardware notes ────────────────────────────────────────────────────────────
#
#   Old 3DS:  ARM11 MPCore @ 268 MHz, 128 MB RAM
#   New 3DS:  ARM11 MPCore @ 804 MHz, 256 MB RAM (extra cores visible to Linux)
#   Storage:  SD card (FAT32, standard 3DS layout)
#   Console:  top screen via linux-3ds framebuffer driver
#   WiFi:     Broadcom BCM43362 (Old) / BCM4334 (New) — driver support varies

{ config, lib, pkgs, ... }:

let
  cfg = config.nintendo3ds;
in

{
  options.nintendo3ds = {
    support = lib.mkEnableOption "Nintendo 3DS hardware support";
  };

  config = lib.mkIf cfg.support {

    device.name = lib.mkDefault "nintendo-3ds";

    # ── Kernel ────────────────────────────────────────────────────────────────
    # Cross-compiled for ARMv6 from the linux-3ds fork.
    # See pkgs/nintendo-3ds-kernel.nix for build details.
    device.kernel = lib.mkDefault
      "${import ../../pkgs/nintendo-3ds-kernel.nix { inherit pkgs; }}/zImage";

    # The linux-3ds kernel uses a built-in device tree (CONFIG_ARM_APPENDED_DTB
    # or similar).  No external DTB file is needed or supported by firm_linux_loader.
    device.dtb = lib.mkDefault null;

    # ── Boot command line ─────────────────────────────────────────────────────
    # firm_linux_loader reads /linux/cmdline.txt and passes it to the kernel.
    #   console=tty0        → framebuffer console (top screen output)
    #   rdinit=/sbin/init   → use the initramfs as the root (no pivot_root)
    #   loglevel=7          → verbose boot messages on top screen
    boot.cmdline = lib.mkDefault
      "console=tty0 rdinit=/sbin/init loglevel=7";

    # ── Console (getty) ───────────────────────────────────────────────────────
    # tty0 = framebuffer console; the 3DS bottom screen shows a virtual
    # keyboard in linux-3ds, and the top screen shows text output.
    services.getty = {
      enable = lib.mkDefault true;
      tty    = lib.mkDefault "tty0";
      baud   = lib.mkDefault 115200;
    };

    # ── Hostname ───────────────────────────────────────────────────────────────
    networking.hostname = lib.mkDefault "nintendo-3ds";

    # ── Disable Rockchip / Luckfox-specific features ──────────────────────────
    # These are set via mkForce so that configuration.nix cannot accidentally
    # re-enable them with a plain assignment.
    rockchip.enable   = lib.mkForce false;
    boot.uboot.enable = lib.mkForce false;

    # ── Disable USB gadget ─────────────────────────────────────────────────────
    # The 3DS USB port is used for charging and file transfer in the official
    # firmware.  Linux-3ds does not support USB gadget mode.
    system.usbGadget.enable = lib.mkForce false;
    system.usb.mode         = lib.mkForce "host";

    # ── Disable MCU control ────────────────────────────────────────────────────
    # The Luckfox MCU helper (GPIO-controlled RESET/BOOT pins) has no analogue
    # on the 3DS.
    system.mcu.enable = lib.mkForce false;

    # ── Disable A/B rootfs ─────────────────────────────────────────────────────
    # The 3DS boots via firm_linux_loader which loads the initramfs directly
    # from the SD card.  Upgrades are done by replacing /linux/initramfs.cpio.gz.
    # A/B slot switching requires bootloader cooperation that firm_linux_loader
    # does not provide; use single initramfs mode for now.
    system.abRootfs.enable = lib.mkForce false;

    # ── Login banner ───────────────────────────────────────────────────────────
    system.banner = lib.mkDefault ''
      Nintendo 3DS — Linux  (\l)
      Kernel \r  |  ${config.networking.hostname}
    '';

    system.motd = lib.mkDefault ''
      Welcome to Linux on the 3DS!
      WiFi networking may require additional firmware — see /lib/firmware/.
    '';
  };
}
