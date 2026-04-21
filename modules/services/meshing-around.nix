{ lib, config, pkgs, ... }:

let
  cfg = config.services."meshing-around";
  meshingAround = import ../../pkgs/meshing-around.nix { inherit pkgs; };
in

{
  config = lib.mkIf cfg.enable {
    packages = [ meshingAround ];

    services.user."meshing-around" = {
      enable = true;
      action = "respawn";
      script = ''
        # ── Working directory ─────────────────────────────────────────────────
        # /opt/meshing-around is in the read-only Nix store.  We run the bot
        # from /var/lib/meshing-around so that it can write logs, caches, and
        # other runtime state next to itself.
        mkdir -p /var/lib/meshing-around /var/log

        # ── Config.ini ────────────────────────────────────────────────────────
        # Copy the full config template on first boot so the user can customise
        # other settings (callsign, BBS options, etc.) by editing the file on
        # the running system.  On every subsequent boot we only overwrite the
        # [interface] section so Nix-managed values always win while user edits
        # to other sections are preserved.
        if [ ! -f /var/lib/meshing-around/config.ini ]; then
          cp /etc/meshing-around/config.ini /var/lib/meshing-around/config.ini
        fi

        # Patch [interface] keys — sed in-place rewrites only the matching lines.
        # We use a | delimiter to avoid conflicts with path characters in values.
        sed -i "s|^type = .*|type = ${cfg.interface.type}|"           /var/lib/meshing-around/config.ini
        sed -i "s|^port = .*|port = ${cfg.interface.serialPort}|"     /var/lib/meshing-around/config.ini
        sed -i "s|^hostname = .*|hostname = ${cfg.interface.host}|"   /var/lib/meshing-around/config.ini
        sed -i "s|^mac = .*|mac = ${cfg.interface.mac}|"              /var/lib/meshing-around/config.ini

        # ── Launch ────────────────────────────────────────────────────────────
        export PYTHONHOME=/opt/meshing-around
        export PYTHONPATH=/opt/meshing-around/lib
        cd /var/lib/meshing-around
        exec /bin/python3 /opt/meshing-around/mesh_bot.py >> /var/log/meshing-around.log 2>&1
      '';
    };
  };
}
