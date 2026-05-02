# USB gadget stack configuration via Linux configfs.
#
# When enabled, a sysinit script mounts configfs, creates a USB gadget
# descriptor under /sys/kernel/config/usb_gadget/g0, and binds it to the
# board's USB Device Controller (UDC).  The USB port must be operating in
# device mode (set system.usb.mode = "device" or leave the ID pin floating).
#
# Supported gadget functions:
#   "acm"          — CDC-ACM virtual serial port
#                    Appears as /dev/ttyACMx on the host, /dev/ttyGS0 on target.
#                    When selected, a getty is spawned on /dev/ttyGS0 so you
#                    get a login shell over USB without any network setup.
#   "ecm"          — CDC-ECM USB ethernet adapter (Linux/macOS hosts)
#   "rndis"        — RNDIS USB ethernet (Windows-compatible)
#   "mass_storage" — USB mass storage; exposes massStorageDevice to the host
#
# Functions can be combined — e.g. [ "acm" "ecm" ] gives both serial and
# ethernet simultaneously if the kernel's composite gadget driver is loaded.
#
# Required kernel config:
#   CONFIG_USB_GADGET=y (or =m + modprobe usb_f_acm / usb_f_ecm)
#   CONFIG_USB_CONFIGFS=y
#   CONFIG_USB_CONFIGFS_SERIAL=y      (for acm)
#   CONFIG_USB_CONFIGFS_ECM=y         (for ecm)
#   CONFIG_USB_CONFIGFS_RNDIS=y       (for rndis)
#   CONFIG_USB_CONFIGFS_MASS_STORAGE=y (for mass_storage)
#
# Configuration example (in configuration.nix):
#
#   system.usb.mode = "device";   # put the port in device mode first
#
#   system.usbGadget = {
#     enable    = true;
#     functions = [ "acm" ];      # USB serial console
#     product   = "My Luckfox";
#   };

{ lib, config, ... }:

let
  cfg = config.system.usbGadget;

  hasAcm   = builtins.elem "acm"          cfg.functions;
  hasEcm   = builtins.elem "ecm"          cfg.functions;
  hasRndis = builtins.elem "rndis"        cfg.functions;
  hasMass  = builtins.elem "mass_storage" cfg.functions;

in

{
  config = lib.mkIf cfg.enable (lib.mkMerge [

    # ── Gadget setup (runs once at boot, before getty) ─────────────────────
    {
      services.user."usb-gadget" = {
        enable = true;
        action = "sysinit";
        script = ''
          GADGET=/sys/kernel/config/usb_gadget/g0

          # ── Fast path: legacy g_serial gadget (CONFIG_USB_G_SERIAL=y) ────────
          # When the kernel is built with USB_G_SERIAL=y, the CDC-ACM gadget is
          # created automatically at boot — /dev/ttyGS0 appears as soon as the
          # DWC3 UDC probes.  No configfs setup is needed; the usb-console
          # respawn service takes care of the getty.
          if [ -e /dev/ttyGS0 ]; then
            echo "usb-gadget: legacy g_serial gadget detected (/dev/ttyGS0 present) — skipping configfs setup"
            exit 0
          fi

          # ── Configfs path (CONFIG_USB_CONFIGFS=y) ────────────────────────────
          # Create the mount point if it doesn't exist yet (the kernel makes
          # /sys/kernel/config available in sysfs when CONFIG_CONFIGFS_FS=y, but
          # we need the directory to exist before we can mount over it).
          mkdir -p /sys/kernel/config 2>/dev/null || true

          # Mount configfs — show the error if it fails so we can diagnose it.
          if ! mountpoint -q /sys/kernel/config 2>/dev/null; then
            if mount -t configfs none /sys/kernel/config 2>/tmp/configfs-mount-err; then
              echo "usb-gadget: configfs mounted at /sys/kernel/config"
            else
              echo "usb-gadget: WARNING — configfs mount failed: $(cat /tmp/configfs-mount-err)" >&2
              echo "usb-gadget: Is CONFIG_CONFIGFS_FS=y in the kernel?" >&2
            fi
          fi

          # Tear down any leftover gadget from a previous boot so we start clean.
          if [ -d "$GADGET" ]; then
            echo > "$GADGET/UDC" 2>/dev/null || true
            for lnk in "$GADGET"/configs/c.1/*; do
              [ -L "$lnk" ] && rm -f "$lnk"
            done
          fi

          mkdir -p "$GADGET" 2>/tmp/gadget-mkdir-err || {
            echo "usb-gadget: ERROR — cannot create $GADGET: $(cat /tmp/gadget-mkdir-err)" >&2
            echo "usb-gadget: Is CONFIG_USB_CONFIGFS=y in the kernel?" >&2
            # Check if legacy /dev/ttyGS0 appeared in the meantime
            if [ -e /dev/ttyGS0 ]; then
              echo "usb-gadget: /dev/ttyGS0 now exists — legacy gadget came up, exiting ok"
              exit 0
            fi
            exit 1
          }

          # ── USB device descriptor ─────────────────────────────────────────
          printf '${cfg.idVendor}\n'  > "$GADGET/idVendor"
          printf '${cfg.idProduct}\n' > "$GADGET/idProduct"

          # ── String descriptors (English / 0x409) ──────────────────────────
          mkdir -p "$GADGET/strings/0x409"
          printf '${cfg.serialNumber}\n' > "$GADGET/strings/0x409/serialnumber"
          printf '${cfg.manufacturer}\n' > "$GADGET/strings/0x409/manufacturer"
          printf '${cfg.product}\n'      > "$GADGET/strings/0x409/product"

          # ── Configuration descriptor ──────────────────────────────────────
          mkdir -p "$GADGET/configs/c.1/strings/0x409"
          printf 'USB Gadget\n' > "$GADGET/configs/c.1/strings/0x409/configuration"
          printf '250\n'        > "$GADGET/configs/c.1/MaxPower"

          ${lib.optionalString hasAcm ''
            # CDC-ACM virtual serial port
            # Host sees /dev/ttyACMx; target gets /dev/ttyGS0.
            mkdir -p "$GADGET/functions/acm.GS0"
            ln -sf "$GADGET/functions/acm.GS0" "$GADGET/configs/c.1/acm.GS0"
          ''}

          ${lib.optionalString hasEcm ''
            # CDC-ECM Ethernet adapter (Linux / macOS hosts)
            mkdir -p "$GADGET/functions/ecm.usb0"
            ln -sf "$GADGET/functions/ecm.usb0" "$GADGET/configs/c.1/ecm.usb0"
          ''}

          ${lib.optionalString hasRndis ''
            # RNDIS Ethernet adapter (Windows hosts)
            mkdir -p "$GADGET/functions/rndis.usb0"
            ln -sf "$GADGET/functions/rndis.usb0" "$GADGET/configs/c.1/rndis.usb0"
          ''}

          ${lib.optionalString hasMass ''
            # USB mass storage — exposes the block device to the host computer.
            # WARNING: do not expose the running root partition; use a separate
            # disk or image file, or set lun.0/ro = 1 for read-only access.
            mkdir -p "$GADGET/functions/mass_storage.usb0"
            printf '1\n' > "$GADGET/functions/mass_storage.usb0/lun.0/removable"
            printf '${cfg.massStorageDevice}\n' \
              > "$GADGET/functions/mass_storage.usb0/lun.0/file"
            ln -sf "$GADGET/functions/mass_storage.usb0" \
              "$GADGET/configs/c.1/mass_storage.usb0"
          ''}

          # ── Bind to the board's USB Device Controller ─────────────────────
          UDC=$(ls /sys/class/udc 2>/dev/null | head -1)
          if [ -z "$UDC" ]; then
            echo "usb-gadget: ERROR — no UDC found in /sys/class/udc" >&2
            echo "usb-gadget: check: is the port in device mode? (system.usb.mode = \"device\")" >&2
            echo "usb-gadget: check: does the kernel have CONFIG_USB_GADGET + CONFIG_USB_CONFIGFS?" >&2
            exit 1
          fi

          echo "usb-gadget: binding gadget to UDC: $UDC"
          printf '%s\n' "$UDC" > "$GADGET/UDC" \
            && echo "usb-gadget: done" \
            || echo "usb-gadget: ERROR — could not bind gadget to $UDC" >&2
        '';
      };
    }

    # ── USB serial console getty (only when ACM function is active) ────────
    #
    # Spawned as a respawning service so a new login shell appears after logout.
    # Waits for /dev/ttyGS0 to be created (happens when the gadget is bound
    # to the UDC), then execs getty.
    (lib.mkIf hasAcm {
      services.user."usb-console" = {
        enable = true;
        action = "respawn";
        script = ''
          # /dev/ttyGS0 is created by the kernel once the gadget is bound.
          # Poll until it appears — the usb-gadget sysinit runs before us
          # but may still be in progress when this service starts.
          until [ -e /dev/ttyGS0 ]; do sleep 1; done
          exec /bin/busybox getty -L ttyGS0 0 vt100
        '';
      };
    })

  ]);
}
