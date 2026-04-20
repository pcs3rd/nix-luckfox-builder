# meshing-around — BBS mesh bot for Meshtastic networks
#
# Source: https://github.com/SpudGunMan/meshing-around
#
# To update to a newer commit:
#   nix-prefetch-github SpudGunMan meshing-around
# then replace MESHING_REV and MESHING_SHA256 below.
#
# Packaging notes
# ───────────────
# The target rootfs has no Nix store, so we cannot rely on Nix's PYTHONPATH
# wrapper tricks.  Instead we:
#
#   1. Copy the application source to $out/opt/meshing-around/
#   2. Collect all Python packages' site-packages into
#      $out/opt/meshing-around/lib/  (a flat, self-contained directory)
#   3. Copy the Python interpreter binary itself to $out/bin/python3
#   4. Write a launcher at $out/bin/meshing-around that sets PYTHONPATH
#
# Omitted optional deps (handled gracefully at runtime if absent):
#   dadjokes  — not in nixpkgs
#   mudp      — not in nixpkgs; only needed for UDP transport mode
#   zeroconf  — only needed for UDP transport mode (mDNS node discovery)
#   RPIO      — Raspberry Pi GPIO; not applicable here

{ pkgs }:

let
  lib = pkgs.lib;

  MESHING_REV    = "9fe580a3cbd35c6b6f31f82bfa1c6b6a666e47c8";
  MESHING_SHA256 = "sha256-Rm6Mi5yNsJ6K8jig/v1cP8BwKiWBznkAk3sGdx0xIlc=";

  python = pkgs.python3;

  # Hard deps from requirements.txt that are available in nixpkgs.
  deps = with python.pkgs; [
    meshtastic      # core: Meshtastic protobuf API + serial/TCP transport
    pypubsub        # pub/sub used by the meshtastic library
    ephem           # pyephem: satellite pass predictions
    requests        # HTTP (weather, NOAA, etc.)
    geopy           # geocoding (--pos features)
    beautifulsoup4  # HTML scraping for weather pages
    schedule        # cron-style task scheduling
    # maidenhead — not in nixpkgs; grid-square features degrade gracefully
  ];

  # Gather all transitive site-packages into one flat directory so we can
  # copy it verbatim into the rootfs without Nix store references.
  bundledLibs = pkgs.runCommand "meshing-around-site-packages" {} ''
    mkdir -p $out

    copy_sp() {
      local pkg="$1"
      for sp in "$pkg"/lib/python*/site-packages; do
        [ -d "$sp" ] || continue
        cp -rLT "$sp" "$out" 2>/dev/null || true
      done
    }

    # Direct deps
    ${lib.concatMapStrings (d: "copy_sp \"${d}\"\n") deps}

    # Propagated (transitive) deps — one level deep is usually enough
    ${lib.concatMapStrings (d:
      lib.concatMapStrings (t: "copy_sp \"${t}\"\n")
        (d.propagatedBuildInputs or [])
    ) deps}
  '';

in

pkgs.stdenv.mkDerivation {
  pname   = "meshing-around";
  version = "unstable-${builtins.substring 0 8 MESHING_REV}";

  src = pkgs.fetchFromGitHub {
    owner  = "SpudGunMan";
    repo   = "meshing-around";
    rev    = MESHING_REV;
    sha256 = MESHING_SHA256;
  };

  dontBuild  = true;
  dontFixup  = true;   # skip strip/patchelf — Python scripts + a foreign ELF

  installPhase = ''
    # ── Application source ────────────────────────────────────────────────
    mkdir -p $out/opt/meshing-around
    cp -r . $out/opt/meshing-around/

    # ── Bundled Python packages ───────────────────────────────────────────
    mkdir -p $out/opt/meshing-around/lib
    cp -rLT ${bundledLibs} $out/opt/meshing-around/lib/

    # ── Python interpreter ────────────────────────────────────────────────
    # Copy the actual ELF binary (not the nixpkgs wrapper script) so it works
    # on the target without the Nix store.
    mkdir -p $out/bin
    pythonBin=$(readlink -f ${python}/bin/python3)
    install -Dm755 "$pythonBin" $out/bin/python3

    # ── Launcher ─────────────────────────────────────────────────────────
    cat > $out/bin/meshing-around << 'LAUNCHER'
#!/bin/sh
# meshing-around launcher — logs to /var/log/meshing-around.log
export PYTHONPATH=/opt/meshing-around/lib
cd /opt/meshing-around
exec /bin/python3 mesh_bot.py "$@"
LAUNCHER
    chmod +x $out/bin/meshing-around

    # ── Default config template ───────────────────────────────────────────
    # Installed to /etc/meshing-around/config.ini — edit before flashing.
    mkdir -p $out/etc/meshing-around
    cp config.template $out/etc/meshing-around/config.ini
  '';

  meta = {
    description = "BBS mesh bot for Meshtastic networks (store-and-forward, weather, games)";
    homepage    = "https://github.com/SpudGunMan/meshing-around";
  };
}
