# meshing-around — BBS mesh bot for Meshtastic networks
#
# Source: https://github.com/SpudGunMan/meshing-around
#
# ── Before this builds, fill in the commit hash ───────────────────────────────
#
#   Run:  nix-prefetch-github SpudGunMan meshing-around
#   Then replace MESHING_REV and MESHING_SHA256 below.
#
# ─────────────────────────────────────────────────────────────────────────────
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
#   4. Write a launcher at $out/bin/meshing-around that sets PYTHONPATH=/opt/…/lib
#
# When added to `packages = [ localPkgs.meshing-around ]` in configuration.nix,
# rootfs.nix will merge each $out/ subdirectory into the rootfs:
#   opt/meshing-around/ → /opt/meshing-around/
#   bin/python3         → /bin/python3          (skipped if busybox already owns it)
#   bin/meshing-around  → /bin/meshing-around

{ pkgs }:

let
  lib = pkgs.lib;

  MESHING_REV    = "9fe580a3cbd35c6b6f31f82bfa1c6b6a666e47c8";
  MESHING_SHA256 = "sha256-Rm6Mi5yNsJ6K8jig/v1cP8BwKiWBznkAk3sGdx0xIlc=";

  python = pkgs.python3;

  # Python packages available in nixpkgs for this project.
  # dadjokes and some optional deps are not in nixpkgs — skip them; the bot
  # handles missing optional modules gracefully.
  deps = with python.pkgs; [
    meshtastic      # core: Meshtastic protobuf API + serial/TCP transport
    pypubsub        # pub/sub used by the meshtastic library
    ephem           # pyephem: satellite pass predictions
    requests        # HTTP (weather, NOAA, Wikipedia)
    geopy           # geocoding (--pos features)
    beautifulsoup4  # HTML scraping for weather pages
    schedule        # cron-style task scheduling
    maidenhead      # ham radio grid-square conversions
    wikipedia       # Wikipedia article lookups
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
    ${lib.concatMapStrings (d: ''copy_sp "${d}"''\n'') deps}

    # Propagated (transitive) deps — one level deep is usually enough
    ${lib.concatMapStrings (d:
      lib.concatMapStrings (t: ''copy_sp "${t}"''\n'')
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
  dontFixup  = true;   # skip strip/patchelf — these are Python scripts + a foreign ELF

  installPhase = ''
    # ── Application source ───────────────────────────────────────────────────
    mkdir -p $out/opt/meshing-around
    cp -r . $out/opt/meshing-around/

    # ── Bundled Python packages ───────────────────────────────────────────────
    # Placed inside the app directory so PYTHONPATH=/opt/meshing-around/lib
    # is a single, self-contained addition.
    mkdir -p $out/opt/meshing-around/lib
    cp -rLT ${bundledLibs} $out/opt/meshing-around/lib/

    # ── Python interpreter ────────────────────────────────────────────────────
    # Copy the actual ELF binary (not the nixpkgs wrapper script) so it works
    # on the target without the Nix store.
    mkdir -p $out/bin
    pythonBin=$(readlink -f ${python}/bin/python3)
    install -Dm755 "$pythonBin" $out/bin/python3

    # ── Launcher ─────────────────────────────────────────────────────────────
    cat > $out/bin/meshing-around << 'LAUNCHER'
#!/bin/sh
# meshing-around launcher
# Config file is read from /etc/meshing-around/config.ini by default;
# override with MESHING_CONFIG env var or pass --config <path> as an argument.
export PYTHONPATH=/opt/meshing-around/lib
exec /bin/python3 /opt/meshing-around/main.py "$@"
LAUNCHER
    chmod +x $out/bin/meshing-around

    # ── Default config template ───────────────────────────────────────────────
    # Copied to /etc/meshing-around/ in the rootfs.  Edit before flashing.
    mkdir -p $out/etc/meshing-around
    if [ -f app/config.template ]; then
      cp app/config.template $out/etc/meshing-around/config.ini
    elif [ -f config.template ]; then
      cp config.template $out/etc/meshing-around/config.ini
    fi
  '';

  meta = {
    description = "BBS mesh bot for Meshtastic networks (store-and-forward, weather, games)";
    homepage    = "https://github.com/SpudGunMan/meshing-around";
  };
}
