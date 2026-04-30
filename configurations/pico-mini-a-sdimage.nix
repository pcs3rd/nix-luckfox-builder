# Flashable SD image for the Luckfox Pico Mini A.
#
# The Mini A uses the same RV1103 silicon as the Mini B.  The only hardware
# difference is the absence of onboard SPI NOR flash.  Because of this:
#
#   • The SPL, U-Boot, and kernel are identical to the Mini B build.
#   • There is no SPI image to flash (no SPI flash on Mini A).
#   • SD card boot works directly — the boot ROM has no SPI to try first.
#
# ── Build ─────────────────────────────────────────────────────────────────────
#
#   nix build .#pico-mini-a-sdImage-flashable
#   nix build .#pico-mini-a-flash-bundle
#
# ── Flash ─────────────────────────────────────────────────────────────────────
#
#   # On macOS, use the raw device (rdiskN) for reliable sector-accurate writes:
#   diskutil list                          # find your SD card, e.g. /dev/disk4
#   diskutil unmountDisk /dev/disk4
#   sudo dd if=result/sd-flashable.img of=/dev/rdisk4 bs=4m status=progress
#
#   # Verify sector 64 (SPL) was written:
#   sudo dd if=/dev/rdisk4 bs=512 skip=64 count=1 2>/dev/null | xxd | head -2
#
# ── Notes ─────────────────────────────────────────────────────────────────────
#
#   Unlike the Mini B, the boot ROM goes directly to SD card (no SPI to try
#   first), so a correctly written SD card should boot without any SPI flashing.
#
#   If the board still enters maskrom mode after writing:
#     1. Use `dd` (not Raspberry Pi Imager) — RPi Imager may skip raw areas.
#     2. Verify via `dd if=/dev/rdiskN bs=1 skip=446 count=66 | xxd` that the
#        MBR partition table is present at byte 446 of the SD card.
#     3. Connect a serial adapter to the UART pads (115200 baud) to see U-Boot
#        output — this reveals exactly where the boot chain fails.

{ config, lib, ... }:

{
  imports = [
    ../configuration.nix
    ../hardware/pico-mini-a-kernel.nix
  ];

  # Override hostname to distinguish Mini A from Mini B on the network.
  networking.hostname = lib.mkForce "luckfox-mini-a";

  # Image and boot cmdline are inherited from configuration.nix.
  # system.abRootfs.enable  = false  (single ext4 partition, set in configuration.nix)
  # system.imageSize         = 512   (MiB, set in configuration.nix)
}
