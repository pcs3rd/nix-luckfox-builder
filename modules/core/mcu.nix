# /bin/mcu — GPIO helper for controlling an attached MCU's reset/bootloader pins.
#
# The Luckfox drives a MOSFET that shorts the MCU's RESET or BOOT pin to ground,
# simulating a button press without requiring actual physical buttons.
#
# Usage (on the running device):
#   mcu reset       — toggle RESET once  → normal reboot of the MCU
#   mcu bootloader  — toggle RESET twice → double-tap bootloader entry
#                     (also works for devices that use RESET+BOOT pin hold:
#                      set system.mcu.bootloaderPin to a second GPIO number)
#
# Configuration (in configuration.nix):
#   system.mcu = {
#     enable       = true;
#     resetPin     = 47;   # GPIO number connected to the RESET MOSFET gate
#     bootloaderPin = -1;  # optional second pin (BOOT0/BOOTSEL); -1 = unused
#   };
#
# GPIO sysfs interface (Linux kernel ≥ 4.8 also supports /dev/gpiochipN via
# libgpiod, but sysfs works universally and requires no extra binaries):
#   /sys/class/gpio/export           — write GPIO number to export
#   /sys/class/gpio/gpioN/direction  — write "out" to set as output
#   /sys/class/gpio/gpioN/value      — write "1" or "0"

{ lib, config, pkgs, ... }:

let
  cfg = config.system.mcu;

  # Duration in milliseconds for which the reset/boot pin is held low.
  PRESS_MS = 100;
  # Gap between the two presses in bootloader mode.
  GAP_MS   = 150;

  mcuScript = pkgs.writeScript "mcu" ''
    #!/bin/sh
    #
    # mcu — MCU reset / bootloader helper
    # GPIO pin numbers are baked in at build time by the Nix configuration.
    #
    RESET_PIN="${toString cfg.resetPin}"
    BOOT_PIN="${toString cfg.bootloaderPin}"
    PRESS_MS="${toString PRESS_MS}"
    GAP_MS="${toString GAP_MS}"
    GPIO_BASE="/sys/class/gpio"

    # ── Helpers ───────────────────────────────────────────────────────────────
    gpio_export() {
      local pin="$1"
      if [ ! -d "$GPIO_BASE/gpio$pin" ]; then
        echo "$pin" > "$GPIO_BASE/export" || { echo "Failed to export GPIO $pin" >&2; exit 1; }
        sleep 0.05
      fi
      echo out > "$GPIO_BASE/gpio$pin/direction"
    }

    gpio_set() {
      local pin="$1" val="$2"
      echo "$val" > "$GPIO_BASE/gpio$pin/value"
    }

    # Pull pin LOW for PRESS_MS then release (active-low MOSFET: 1=off, 0=on)
    gpio_press() {
      local pin="$1"
      gpio_export "$pin"
      gpio_set    "$pin" 0
      sleep "$(echo "$PRESS_MS" | awk '{printf "%.3f", $1/1000}')"
      gpio_set    "$pin" 1
    }

    # ── Commands ──────────────────────────────────────────────────────────────
    CMD="${1:-}"
    case "$CMD" in

      reset)
        echo "mcu: reset (GPIO $RESET_PIN, active LOW for ${PRESS_MS} ms)"
        gpio_press "$RESET_PIN"
        echo "mcu: done"
        ;;

      bootloader)
        # Double-tap reset to enter the RP2040/RP2350 UF2 bootloader.
        # For STM32 DFU or nRF52 OTA targets that use a dedicated BOOT pin,
        # hold the boot pin while pressing reset once.
        if [ "$BOOT_PIN" != "-1" ] && [ -n "$BOOT_PIN" ]; then
          echo "mcu: bootloader (hold BOOT GPIO $BOOT_PIN, pulse RESET GPIO $RESET_PIN)"
          gpio_export "$BOOT_PIN"
          gpio_set    "$BOOT_PIN" 0     # assert BOOT
          sleep 0.05
          gpio_press  "$RESET_PIN"      # pulse RESET with BOOT held
          sleep 0.1
          gpio_set    "$BOOT_PIN" 1     # release BOOT
        else
          echo "mcu: bootloader (double-tap RESET GPIO $RESET_PIN)"
          gpio_press "$RESET_PIN"
          sleep "$(echo "$GAP_MS" | awk '{printf "%.3f", $1/1000}')"
          gpio_press "$RESET_PIN"
        fi
        echo "mcu: done"
        ;;

      help|--help|-h|"")
        cat << USAGE
Usage: mcu <command>

Commands:
  reset       Pulse the MCU RESET pin once (normal reboot).
  bootloader  Enter bootloader mode:
              - With bootloaderPin set: hold BOOT pin while pulsing RESET.
              - Without: double-tap RESET (RP2040 UF2 convention).

Current GPIO configuration:
  resetPin     = $RESET_PIN
  bootloaderPin = $BOOT_PIN  (-1 means unused)

USAGE
        ;;

      *)
        echo "mcu: unknown command '$CMD'. Try: mcu help" >&2
        exit 1
        ;;
    esac
  '';

in

{
  config = lib.mkIf cfg.enable {
    # Wire the generated script into the rootfs under /bin/mcu
    packages = [
      (pkgs.runCommand "mcu-script" {} ''
        mkdir -p $out/bin
        cp ${mcuScript} $out/bin/mcu
        chmod +x $out/bin/mcu
      '')
    ];
  };
}
