# Flashable SD image for the Luckfox Pico Mini A.
#
# The Mini A uses the same RV1103 silicon as the Mini B; only difference is
# the absence of onboard SPI NOR flash.  luckfox.model = "pico-mini-a" sets
# the correct DTB (rv1103-luckfox-pico-mini-a.dtb with Mini B fallback) and
# hostname automatically via modules/core/luckfox-board.nix.
#
# ── Build ─────────────────────────────────────────────────────────────────────
#
#   nix build .#pico-mini-a-sdImage-flashable
#   nix build .#pico-mini-a-flash-bundle
#
# ── Flash (macOS) ─────────────────────────────────────────────────────────────
#
#   diskutil list                          # find SD card — e.g. /dev/disk4
#   diskutil unmountDisk /dev/disk4
#   sudo dd if=result/sd-flashable.img of=/dev/rdisk4 bs=4m status=progress
#   # note: use rdiskN (raw device) — NOT diskN — for reliable raw writes
#
# ── Verify the write ──────────────────────────────────────────────────────────
#
#   # Sector 64 (SPL — Rockchip loader magic):
#   sudo dd if=/dev/rdisk4 bs=512 skip=64 count=1 2>/dev/null | xxd | head -2
#
#   # MBR partition table (byte 446) + boot signature (byte 510 = 55 aa):
#   sudo dd if=/dev/rdisk4 bs=1 skip=446 count=66 2>/dev/null | xxd
#
# ── Notes ─────────────────────────────────────────────────────────────────────
#
#   Mini A has no SPI flash: the boot ROM goes directly to SD card.  No SPI
#   flashing step is needed or possible.  A correctly written SD card boots
#   without holding BOOT.
#
#   Connect a serial adapter (115200 baud) to the UART pads to see U-Boot
#   and kernel output if the board doesn't boot as expected.

{ lib, ... }:

{
  imports = [ ../configuration.nix ];

  # Switch to Mini A — luckfox-board.nix picks up the correct DTB and hostname.
  luckfox.model = lib.mkForce "pico-mini-a";
}
