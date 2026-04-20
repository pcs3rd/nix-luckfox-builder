
{ lib, config, ... }:

{
  config.services.definitions.getty = lib.mkIf config.services.getty.enable {
    enable = true;
    run = ''exec getty -L ttyS0 115200 vt100'';
  };
}
