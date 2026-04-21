# mesh-bbs service module
#
# Runs the minimal BBS + store-and-forward bot as a busybox init service.
# Enable in configuration.nix:
#
#   services."mesh-bbs" = {
#     enable    = true;
#     interface = {
#       type       = "serial";
#       serialPort = "/dev/ttyACM0";
#       # type     = "tcp";
#       # host     = "192.168.1.x";
#     };
#     channel       = 0;     # Meshtastic channel index to monitor (0-7)
#     listLimit     = 10;    # max posts shown by `bbs list`
#     maxMessageLen = 200;   # max bytes per outgoing LoRa message chunk
#     dataDir       = "/var/lib/mesh-bbs";
#   };

{ lib, config, pkgs, ... }:

let
  cfg     = config.services."mesh-bbs";
  meshBbs = import ../../pkgs/mesh-bbs { inherit pkgs; };

  ifaceArg =
    if cfg.interface.type == "tcp"
    then "--tcp ${cfg.interface.host}"
    else "--serial ${cfg.interface.serialPort}";
in

{
  config = lib.mkIf cfg.enable {
    packages = [ meshBbs ];

    services.user."mesh-bbs" = {
      enable = true;
      action = "respawn";
      script = ''
        mkdir -p ${cfg.dataDir} /var/log
        export PYTHONHOME=/opt/mesh-bbs
        export PYTHONPATH=/opt/mesh-bbs/lib
        exec /bin/mesh-bbs \
          ${ifaceArg} \
          --channel      ${toString cfg.channel} \
          --list-limit   ${toString cfg.listLimit} \
          --max-msg-len  ${toString cfg.maxMessageLen} \
          --data-dir     ${cfg.dataDir} \
          >> /var/log/mesh-bbs.log 2>&1
      '';
    };
  };
}
