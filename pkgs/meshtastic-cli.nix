# meshtastic-cli — minimal Meshtastic Python CLI for the embedded rootfs.
#
# Provides /bin/meshtastic (the upstream CLI) with the smallest possible
# footprint by omitting all optional extras:
#
#   Included:
#     meshtastic  — core: CLI, protobuf API, serial/TCP transport
#     pypubsub    — required by meshtastic internals
#
#   Excluded (not needed for CLI use):
#     ephem       — satellite predictions  (only used by meshing-around bot)
#     requests    — HTTP                   (only used by meshing-around bot)
#     geopy       — geocoding              (only used by meshing-around bot)
#     beautifulsoup4                       (only used by meshing-around bot)
#     schedule                             (only used by meshing-around bot)
#     grpcio      — gRPC (large C extension; meshtastic works fine without it
#                   for serial/TCP usage)
#
# Usage on the device:
#   meshtastic --info
#   meshtastic --sendtext "hello" --dest '!ab12cd34'
#   meshtastic --export-config > /etc/meshtastic-config.yaml
#
# To update to a newer meshtastic release, bump nixpkgs (the version tracks
# upstream automatically).
#
# Packaging notes — identical strategy to meshing-around.nix:
#   1. Gather site-packages into one flat directory.
#   2. Copy the Python stdlib alongside (PYTHONHOME trick).
#   3. Patch ELF interpreter + RPATH so the binary runs on the musl rootfs.
#   4. Write a /bin/meshtastic launcher that sets PYTHONHOME/PYTHONPATH.

{ pkgs }:

let
  lib = pkgs.lib;

  python = pkgs.python3;

  deps = with python.pkgs; [
    meshtastic   # core CLI + serial/TCP transport
    pypubsub     # required by meshtastic
  ];

  bundledLibs = pkgs.runCommand "meshtastic-cli-site-packages" {} ''
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

    # One level of transitive deps
    ${lib.concatMapStrings (d:
      lib.concatMapStrings (t: "copy_sp \"${t}\"\n")
        (d.propagatedBuildInputs or [])
    ) deps}
  '';

in

pkgs.stdenv.mkDerivation {
  pname   = "meshtastic-cli";
  version = python.pkgs.meshtastic.version;

  # No external source — we reuse the nixpkgs meshtastic package directly.
  dontUnpack = true;

  nativeBuildInputs = [ pkgs.buildPackages.patchelf ];

  dontBuild = true;
  dontFixup = true;

  installPhase = ''
    # ── Python standard library ───────────────────────────────────────────
    mkdir -p $out/opt/meshtastic-cli/lib
    for pyLibDir in ${python}/lib/python*/; do
      pyVer=$(basename "$pyLibDir")
      mkdir -p "$out/opt/meshtastic-cli/lib/$pyVer"
      cp -rLT "$pyLibDir" "$out/opt/meshtastic-cli/lib/$pyVer"

      # Drop heavy-but-unused stdlib dirs
      for trimDir in test unittest tkinter idlelib turtledemo lib2to3 ensurepip distutils venv; do
        rm -rf "$out/opt/meshtastic-cli/lib/$pyVer/$trimDir" || true
      done
      find "$out/opt/meshtastic-cli/lib/$pyVer" \
        -name '__pycache__' -prune -exec rm -rf {} \; 2>/dev/null || true

      find "$out/opt/meshtastic-cli/lib/$pyVer" -name '*.so*' -type f | \
        while read -r so; do
          patchelf --set-rpath "/lib" "$so" 2>/dev/null || true
        done
    done

    # ── Bundled site-packages ─────────────────────────────────────────────
    cp -rLT ${bundledLibs} $out/opt/meshtastic-cli/lib/

    # Trim test directories
    find "$out/opt/meshtastic-cli/lib" -maxdepth 3 \
      \( -name 'test' -o -name 'tests' \) -type d \
      -exec rm -rf {} + 2>/dev/null || true

    # ── Python binary ─────────────────────────────────────────────────────
    mkdir -p $out/bin $out/lib

    realPython=$(find ${python}/bin -name '.python*-wrapped' | head -1)
    if [ -z "$realPython" ]; then
      realPython=$(readlink -f ${python}/bin/python3)
    fi

    install -Dm755 "$realPython" $out/bin/python3.bin

    cat > $out/bin/python3 << 'PYWRAP'
#!/bin/sh
export PYTHONHOME=/opt/meshtastic-cli
export PYTHONPATH=/opt/meshtastic-cli/lib
exec /bin/python3.bin "$@"
PYWRAP
    chmod +x $out/bin/python3

    interp=$(patchelf --print-interpreter "$realPython" 2>/dev/null || true)
    if [ -n "$interp" ] && [ -f "$interp" ]; then
      interpName=$(basename "$interp")
      install -Dm755 "$interp" "$out/lib/$interpName"
      patchelf --set-interpreter "/lib/$interpName" $out/bin/python3.bin
      patchelf --set-rpath        "/lib"             $out/bin/python3.bin
    fi

    # ── Shared library bundling ──────────────────────────────────────────
    copy_needed() {
      local elf="$1"
      local rpath
      rpath=$(patchelf --print-rpath "$elf" 2>/dev/null || true)
      patchelf --print-needed "$elf" 2>/dev/null | while read -r libname; do
        [ -f "$out/lib/$libname" ] && continue
        found=""
        for rdir in $(echo "$rpath" | tr ':' '\n'); do
          [ -z "$rdir" ] && continue
          candidate="$rdir/$libname"
          if [ -e "$candidate" ]; then
            found=$(readlink -f "$candidate" 2>/dev/null || echo "$candidate")
            break
          fi
        done
        if [ -z "$found" ]; then
          found=$(find -L \
            ${python} \
            ${pkgs.zlib} \
            ${pkgs.libffi} \
            ${pkgs.openssl.out} \
            ${pkgs.sqlite} \
            ${pkgs.bzip2} \
            ${pkgs.xz} \
            ${pkgs.ncurses} \
            ${pkgs.expat} \
            ${pkgs.readline} \
            ${pkgs.stdenv.cc.cc.lib} \
            -name "$libname" -type f 2>/dev/null | head -1)
        fi
        if [ -n "$found" ] && [ -f "$found" ]; then
          install -Dm755 "$found" "$out/lib/$libname"
          patchelf --set-rpath "/lib" "$out/lib/$libname" 2>/dev/null || true
          copy_needed "$found"
        fi
      done
    }

    copy_needed "$realPython"
    for pyLibDir in ${python}/lib/python*/; do
      find -L "$pyLibDir" -name '*.so*' -type f | while read -r so; do
        copy_needed "$so"
      done
    done
    find -L ${bundledLibs} -name '*.so*' -type f 2>/dev/null | while read -r so; do
      copy_needed "$so"
    done

    # ── Launcher ─────────────────────────────────────────────────────────
    # meshtastic installs a __main__.py entrypoint under meshtastic/
    cat > $out/bin/meshtastic << 'LAUNCHER'
#!/bin/sh
export PYTHONHOME=/opt/meshtastic-cli
export PYTHONPATH=/opt/meshtastic-cli/lib
exec /bin/python3.bin -m meshtastic "$@"
LAUNCHER
    chmod +x $out/bin/meshtastic
  '';

  meta = {
    description = "Meshtastic Python CLI — minimal embedded build";
    homepage    = "https://github.com/meshtastic/python";
  };
}
