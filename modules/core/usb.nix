# USB OTG port mode configuration.
#
# Both the Luckfox Pico Mini B (RV1103) and the Pine64 Ox64 (BL808) have a
# single USB 2.0 OTG port that can act as either a USB host (connecting USB
# devices) or a USB peripheral (appearing as a device to a host computer).
#
# The Linux kernel exposes this via the USB role switch subsystem:
#   /sys/class/usb_role/<controller>/role
#
# Writing "host" or "device" to that file switches the port mode.
# Writing "none" (or leaving it untouched) lets the hardware's ID pin decide
# automatically — that's the "otg" mode and is the default.
#
# Configuration (in configuration.nix or a hardware profile):
#
#   system.usb = {
#     mode           = "host";    # "host" | "device" | "otg" (default)
#     roleSwitchPath = null;      # auto-detect, or set e.g.:
#                                 # "/sys/class/usb_role/fcd00000.usb-role-switch/role"
#   };
#
# Practical examples:
#   mode = "host"    → connect a USB keyboard, hub, flash drive, etc.
#   mode = "device"  → appear as a CDC-ACM serial port, RNDIS ethernet, or
#                      USB mass storage to the connected host computer.
#   mode = "otg"     → let the ID pin decide (default; no script generated).
#
# If roleSwitchPath is null (the default) the script does:
#   find /sys/class/usb_role -maxdepth 1 -name role | head -1
# which works on most boards as long as only one OTG controller is present.
# Set it explicitly if auto-detection picks the wrong controller.

{ lib, config, ... }:

let
  cfg = config.system.usb;

  # The value written to the role file.
  # "device" is the modern kernel name; "peripheral" was used in older kernels.
  roleValue = if cfg.mode == "device" then "device" else "host";

  # Shell fragment that resolves the sysfs role file at runtime.
  findRole =
    if cfg.roleSwitchPath != null
    then ''ROLE_FILE="${cfg.roleSwitchPath}"''
    else ''ROLE_FILE=$(find /sys/class/usb_role -maxdepth 2 -name role 2>/dev/null | head -1)'';

in

{
  # Only emit any configuration when the user has requested a specific mode.
  # "otg" means "let the hardware decide" — no script needed.
  config = lib.mkIf (cfg.mode != "otg") {
    services.user."usb-mode" = {
      enable = true;
      action = "sysinit";   # runs once at boot, after mdev -s populates /sys
      script = ''
        ${findRole}

        if [ -z "$ROLE_FILE" ] || [ ! -e "$ROLE_FILE" ]; then
          echo "usb-mode: WARNING — no USB role switch found in /sys/class/usb_role" >&2
          echo "usb-mode: set system.usb.roleSwitchPath explicitly if your controller" >&2
          echo "usb-mode: is not auto-detected (check: ls /sys/class/usb_role/)" >&2
          exit 0
        fi

        echo "usb-mode: setting $(cat "$ROLE_FILE") → ${roleValue}  ($ROLE_FILE)"

        # Try the modern "device" name first; fall back to "peripheral" for
        # kernels older than ~5.10 that haven't renamed the mode yet.
        if echo "${roleValue}" > "$ROLE_FILE" 2>/dev/null; then
          echo "usb-mode: ok"
        elif [ "${roleValue}" = "device" ]; then
          echo "peripheral" > "$ROLE_FILE" \
            && echo "usb-mode: ok (peripheral fallback)" \
            || echo "usb-mode: ERROR — could not set mode" >&2
        else
          echo "usb-mode: ERROR — could not write to $ROLE_FILE" >&2
        fi
      '';
    };
  };
}
