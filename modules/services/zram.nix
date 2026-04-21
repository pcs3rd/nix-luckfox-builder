# zram compressed swap
#
# Creates a /dev/zram0 block device backed by compressed RAM and enables it
# as swap space during early init (busybox sysinit).
#
# Typical savings on a 64 MB board:
#   system.zram.size      = "32M"   → ~96 MB effective swap (lz4, ~3:1 ratio)
#   system.zram.algorithm = "lz4"   → fast enough to not stall light workloads
#
# Enable in configuration.nix:
#   system.zram.enable    = true;
#   system.zram.size      = "32M";   # default
#   system.zram.algorithm = "lz4";   # default

{ lib, config, ... }:

{
  config = lib.mkIf config.system.zram.enable {
    services.user.zram = {
      enable = true;
      action = "sysinit";   # runs early, blocks until swapon completes
      script = ''
        # Load the zram kernel module.
        modprobe zram || { echo "zram: modprobe failed" >&2; exit 1; }

        # Set compression algorithm before sizing the device.
        echo ${config.system.zram.algorithm} > /sys/block/zram0/comp_algorithm

        # Set device size.  The kernel rejects changes after the device is opened.
        echo ${config.system.zram.size} > /sys/block/zram0/disksize

        # Format and activate as swap.  Priority 10 means the kernel prefers
        # zram over any slower on-disk swap (which defaults to priority -1).
        mkswap  /dev/zram0
        swapon -p 10 /dev/zram0

        echo "zram: ${config.system.zram.size} swap enabled (${config.system.zram.algorithm})"
      '';
    };
  };
}
