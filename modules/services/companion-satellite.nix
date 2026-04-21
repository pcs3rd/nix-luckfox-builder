# Bitfocus Companion Satellite service module
#
# Connects this device as a satellite to a main Companion server.
# Enable in configuration.nix:
#
#   services.companion-satellite = {
#     enable = true;
#     host   = "192.168.1.100";   # IP or hostname of your Companion server
#     port   = 16622;              # default satellite port
#   };
#
# The satellite binary scans for USB HID devices (Stream Deck, etc.) and
# exposes them to the remote Companion instance over TCP.

{ lib, config, pkgs, ... }:

let
  cfg = config.services.companion-satellite;
  sat = import ../../pkgs/companion-satellite.nix { inherit pkgs; };
in

{
  config = lib.mkIf cfg.enable {
    packages = [ sat ];

    services.user.companion-satellite = {
      enable = true;
      action = "respawn";
      script = ''
        exec /bin/companion-satellite \
          --host ${cfg.host} \
          --port ${toString cfg.port} \
          >> /var/log/companion-satellite.log 2>&1
      '';
    };
  };
}
