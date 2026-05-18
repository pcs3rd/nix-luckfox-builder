# services.rf24gateway — RF24Gateway TUN/TAP IP gateway service
#
# Starts rf24gateway at boot, creates /dev/net/tun, and configures the
# tun_rf24 interface with the configured IP address.
#
# Example configuration.nix:
#
#   services.rf24gateway = {
#     enable    = true;
#     cePin     = 62;      # GPIO1_C6 — physical pin 9 on Mini A header
#     channel   = 1;
#     nodeId    = 0;       # 0 = master/gateway
#     ip        = "10.0.0.1";
#     mask      = "255.255.255.0";
#   };

{ lib, config, pkgs, ... }:

let
  cfg = config.services.rf24gateway;
  gw  = import ../../pkgs/rf24gateway.nix { inherit pkgs; };
in

{
  options.services.rf24gateway = {
    enable = lib.mkEnableOption "RF24Gateway TUN/TAP IP gateway";

    cePin = lib.mkOption {
      type        = lib.types.int;
      default     = 62;
      description = "GPIO number for the nRF24L01+ CE pin (GPIO1_C6 = 62 on Mini A).";
    };

    channel = lib.mkOption {
      type        = lib.types.int;
      default     = 1;
      description = "RF channel (0-125). Must match on all nodes in the mesh.";
    };

    nodeId = lib.mkOption {
      type        = lib.types.int;
      default     = 0;
      description = "Mesh node ID. 0 = master/gateway (this device). Clients use 1-255.";
    };

    ip = lib.mkOption {
      type        = lib.types.str;
      default     = "10.0.0.1";
      description = "IP address assigned to the tun_rf24 interface on this device.";
    };

    mask = lib.mkOption {
      type        = lib.types.str;
      default     = "255.255.255.0";
      description = "Subnet mask for the tun_rf24 interface.";
    };
  };

  config = lib.mkIf cfg.enable {
    packages = [ gw ];

    # Create /dev/net/tun and start the gateway, then bring up the interface.
    services.user.rf24gateway = {
      enable = true;
      action = "respawn";
      script = ''
        # Ensure TUN device node exists (busybox mdev does not auto-create it)
        if [ ! -e /dev/net/tun ]; then
          mkdir -p /dev/net
          mknod /dev/net/tun c 10 200
        fi

        # Start the gateway (blocks until signal)
        /bin/rf24gateway \
          --ce_pin  ${toString cfg.cePin} \
          --channel ${toString cfg.channel} \
          --node_id ${toString cfg.nodeId} \
          --ip      ${cfg.ip} \
          --mask    ${cfg.mask} &

        GW_PID=$!

        # Wait briefly for the TUN interface to appear, then configure it
        sleep 1
        if ip link show tun_rf24 > /dev/null 2>&1; then
          ip addr add ${cfg.ip}/${toString (
            # Convert dotted mask to prefix length
            let m = cfg.mask; in
            if m == "255.255.255.0"   then "24"
            else if m == "255.255.0.0"   then "16"
            else if m == "255.0.0.0"     then "8"
            else "24"
          )} dev tun_rf24 2>/dev/null || true
          ip link set tun_rf24 up
          echo "rf24gateway: tun_rf24 up — ${cfg.ip}"
        else
          echo "rf24gateway: WARNING — tun_rf24 did not appear (CONFIG_TUN missing?)"
        fi

        wait $GW_PID
      '';
    };
  };
}
