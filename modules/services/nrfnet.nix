{ lib, config, pkgs, ... }:

let
  cfg    = config.services.nrfnet;
  nrfnet = import ../../pkgs/nrfnet.nix { inherit pkgs; };

  args = lib.concatStringsSep " " (
    [ "--${cfg.role}"
      "--channel=${toString cfg.channel}"
    ] ++ cfg.extraArgs
  );

  # RF24 (used by nrfnet) hardcodes /dev/spidev0.0.
  # The RV1103 GPIO-header SPI bus is spi1, which the kernel enumerates as
  # /dev/spidev1.0.  Symlink spidev0.0 → spidev1.0 at boot so nrfnet finds it.
  spiAlias =
    let
      src  = "/dev/spidev${toString cfg.spiDev.bus}.${toString cfg.spiDev.cs}";
      dest = "/dev/spidev0.0";
    in
      lib.optionalString (cfg.spiDev.bus != 0 || cfg.spiDev.cs != 0) ''
        if [ -e ${src} ] && [ ! -e ${dest} ]; then
          ln -sf ${src} ${dest}
          echo "spidev-alias: ${dest} -> ${src}"
        fi
      '';
in

{
  config = lib.mkIf cfg.enable (lib.mkMerge [

    { packages = [ nrfnet ]; }

    # Symlink the real spidev path to spidev0.0 so RF24 finds it.
    (lib.mkIf (cfg.spiDev.bus != 0 || cfg.spiDev.cs != 0) {
      services.user."spidev-alias" = {
        enable = true;
        action = "sysinit";
        script = spiAlias;
      };
    })

    # nrfnet tunnel daemon (not auto-started by default; run manually or
    # set services.user.nrfnet.enable = true in configuration.nix).
    {
      services.user.nrfnet = {
        enable = lib.mkDefault false;
        action = "respawn";
        script = ''
          exec /bin/nrfnet ${args} >> /var/log/nrfnet.log 2>&1
        '';
      };
    }

  ]);
}
