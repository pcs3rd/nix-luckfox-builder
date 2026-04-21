{ lib, config, pkgs, ... }:

let
  meshingAround = import ../../pkgs/meshing-around.nix { inherit pkgs; };
in

{
  config = lib.mkIf config.services."meshing-around".enable {
    packages = [ meshingAround ];

    services.user."meshing-around" = {
      enable = true;
      action = "respawn";
      script = ''
        export PYTHONHOME=/opt/meshing-around
        export PYTHONPATH=/opt/meshing-around/lib
        cd /opt/meshing-around
        exec /bin/python3 mesh_bot.py >> /var/log/meshing-around.log 2>&1
      '';
    };
  };
}
