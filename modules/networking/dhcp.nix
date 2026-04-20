
{ pkgs, config, ... }:

{
  config.system.build.rootfs = pkgs.runCommand "rootfs-net" {} ''
    cp -r ${config.system.build.rootfs} $out
  '';
}
