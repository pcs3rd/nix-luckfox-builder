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

    # Create /dev/net/tun device node and symlink spidev at boot.
    # busybox mdev does not auto-create /dev/net/tun even when CONFIG_TUN=y;
    # the node must be created explicitly before nrfnet opens the tunnel.
    (lib.mkIf (cfg.spiDev.bus != 0 || cfg.spiDev.cs != 0) {
      services.user."spidev-alias" = {
        enable = true;
        action = "sysinit";
        script = ''
          # TUN device node — major 10, minor 200
          if [ ! -e /dev/net/tun ]; then
            mkdir -p /dev/net
            mknod /dev/net/tun c 10 200
            echo "nrfnet-init: created /dev/net/tun"
          fi
          ${spiAlias}
        '';
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
