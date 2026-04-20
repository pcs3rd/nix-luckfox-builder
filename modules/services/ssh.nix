{ lib, config, ... }:

{
  # Register the dropbear SSH service.
  # The dropbear binary itself is added to the rootfs by modules/core/rootfs.nix
  # when services.ssh.enable = true.
  config.services.definitions.ssh = lib.mkIf config.services.ssh.enable {
    enable = lib.mkDefault false;
    run    = ''exec dropbear -R -F'';
  };
}
