{ lib, config, pkgs, ... }:

let
  cfg    = config.services.nrfnet;
  nrfnet = import ../../pkgs/nrfnet.nix { inherit pkgs; };

  args = lib.concatStringsSep " " (
    [ "--${cfg.role}"
      "--spi_device=${cfg.spiDevice}"
      "--channel=${toString cfg.channel}"
    ] ++ cfg.extraArgs
  );
in

{
  config = lib.mkIf cfg.enable {
    packages = [ nrfnet ];

    services.user.nrfnet = {
      enable = true;
      action = "respawn";
      script = ''
        exec /bin/nrfnet ${args} >> /var/log/nrfnet.log 2>&1
      '';
    };
  };
}
