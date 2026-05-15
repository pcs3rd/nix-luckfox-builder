{ lib, config, pkgs, ... }:

let
  cfg    = config.services.nrfnet;
  nrfnet = import ../../pkgs/nrfnet.nix { inherit pkgs; spiDev = cfg.spiDev; };

  args = lib.concatStringsSep " " (
    [ "--${cfg.role}"
      "--channel=${toString cfg.channel}"
    ] ++ cfg.extraArgs
  );
in

{
  config = lib.mkIf cfg.enable {
    packages = [ nrfnet ];

    services.user.nrfnet = {
      enable = lib.mkDefault false;
      action = "respawn";
      script = ''
        exec /bin/nrfnet ${args} >> /var/log/nrfnet.log 2>&1
      '';
    };
  };
}
