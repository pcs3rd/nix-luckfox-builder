{ lib, config, ... }:

{
  config.services.definitions.getty = lib.mkIf config.services.getty.enable {
    enable = true;
    run    = ''exec getty -L ${config.services.getty.tty} ${toString config.services.getty.baud} vt100'';
  };
}
