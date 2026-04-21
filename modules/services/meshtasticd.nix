# meshtasticd service module
#
# Enable in configuration.nix:
#
#   services.meshtasticd.enable = true;
#
#   # Optional: supply your own config.yaml (recommended)
#   services.meshtasticd.configFile = ./meshtasticd-config.yaml;
#
# The daemon logs to /var/log/meshtasticd.log.
# Configure the node via the Meshtastic app or CLI after first boot.

{ lib, config, pkgs, ... }:

let
  cfg         = config.services.meshtasticd;
  meshtasticd = import ../../pkgs/meshtasticd.nix { inherit pkgs; };

  configFile =
    if cfg.configFile != null
    then cfg.configFile
    else "${meshtasticd}/etc/meshtasticd/config.yaml";

  args = lib.concatStringsSep " " (
    [ "--config" configFile ]
    ++ cfg.extraArgs
  );
in

{
  config = lib.mkIf cfg.enable {
    packages = [ meshtasticd ];

    # Install the config file at /etc/meshtasticd/config.yaml.
    # The rootfs package copy mechanism handles etc/ automatically.

    services.user.meshtasticd = {
      enable = true;
      action = "respawn";
      script = ''
        mkdir -p /var/log /etc/meshtasticd
        # Copy config template on first boot if no config exists yet
        if [ ! -f /etc/meshtasticd/config.yaml ]; then
          cp ${configFile} /etc/meshtasticd/config.yaml
        fi
        exec meshtasticd ${args} >> /var/log/meshtasticd.log 2>&1
      '';
    };
  };
}
