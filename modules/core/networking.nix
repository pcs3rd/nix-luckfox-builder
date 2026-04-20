
{ lib, config, ... }:

{
  config.services.definitions.dhcp = lib.mkIf config.networking.dhcp.enable {
    enable = true;
    run = ''
      ip link set ${config.networking.interface} up
      exec udhcpc -i ${config.networking.interface} -f
    '';
  };
}
