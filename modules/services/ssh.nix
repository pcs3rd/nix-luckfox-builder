
{ lib, config, pkgs, ... }:

{
  config.services.definitions.ssh = lib.mkIf config.services.ssh.enable {
    enable = true;
    run = ''exec dropbear -R -F'';
  };

  config.system.build.rootfs = pkgs.runCommand "rootfs-ssh" {} ''
    cp -r ${config.system.build.rootfs} $out
  '';
}
