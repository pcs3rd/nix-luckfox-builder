{ lib, config, ... }:

{
  config.services.user."meshing-around" = lib.mkIf config.services."meshing-around".enable {
    enable = true;
    action = "respawn";
    script = ''
      export PYTHONPATH=/opt/meshing-around/lib
      cd /opt/meshing-around
      exec /bin/python3 mesh_bot.py >> /var/log/meshing-around.log 2>&1
    '';
  };
}
