# mesh-bbs — minimal Meshtastic BBS + store-and-forward bot.
#
# Only two runtime Python deps:
#   meshtastic  — Meshtastic protobuf API + serial/TCP transport
#   pypubsub    — pub/sub used by the meshtastic library
#
# Packaging strategy (same as meshing-around):
#   1. Copy mesh_bbs.py to $out/opt/mesh-bbs/
#   2. Bundle meshtastic + pypubsub site-packages → $out/opt/mesh-bbs/lib/
#   3. Copy Python stdlib (needed for PYTHONHOME) → $out/opt/mesh-bbs/lib/python3.X/
#   4. Patch ELF interpreter + RPATH of the Python binary
#   5. Install /bin/mesh-bbs launcher that sets PYTHONHOME/PYTHONPATH

{ pkgs }:

let
  lib = pkgs.lib;

  python = pkgs.python3;

  # Minimal deps — no ephem, requests, geopy, beautifulsoup4, schedule
  deps = with python.pkgs; [
    meshtastic   # core transport + protobuf
    pypubsub     # pub/sub wiring
  ];

  # Collect transitive site-packages into a flat directory.
  bundledLibs = pkgs.runCommand "mesh-bbs-site-packages" {} ''
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

    # Propagated (transitive) deps — one level deep
    ${lib.concatMapStrings (d:
      lib.concatMapStrings (t: "copy_sp \"${t}\"\n")
        (d.propagatedBuildInputs or [])
    ) deps}
  '';

in

pkgs.stdenv.mkDerivation {
  pname   = "mesh-bbs";
  version = "0.1.0";

  src = ./.;   # just the local directory (mesh_bbs.py + this file)

  nativeBuildInputs = [ pkgs.buildPackages.patchelf ];

  dontBuild = true;
  dontFixup = true;

  installPhase = ''
    # ── Application source ────────────────────────────────────────────────
    mkdir -p $out/opt/mesh-bbs
    cp mesh_bbs.py $out/opt/mesh-bbs/

    # ── Python standard library ───────────────────────────────────────────
    mkdir -p $out/opt/mesh-bbs/lib
    for pyLibDir in ${python}/lib/python*/; do
      pyVer=$(basename "$pyLibDir")
      mkdir -p "$out/opt/mesh-bbs/lib/$pyVer"
      cp -rLT "$pyLibDir" "$out/opt/mesh-bbs/lib/$pyVer"

      # Trim heavyweight stdlib dirs not needed at runtime
      for trimDir in test unittest tkinter idlelib turtledemo lib2to3 ensurepip distutils venv; do
        rm -rf "$out/opt/mesh-bbs/lib/$pyVer/$trimDir" || true
      done
      find "$out/opt/mesh-bbs/lib/$pyVer" \
        -name '__pycache__' -prune -exec rm -rf {} \; 2>/dev/null || true

      # Patch RPATH of stdlib .so files
      find "$out/opt/mesh-bbs/lib/$pyVer" -name '*.so*' -type f | \
        while read -r so; do
          patchelf --set-rpath "/lib" "$so" 2>/dev/null || true
        done
    done

    # ── Bundled site-packages ─────────────────────────────────────────────
    cp -rLT ${bundledLibs} $out/opt/mesh-bbs/lib/

    # Trim test directories from bundled site-packages
    find "$out/opt/mesh-bbs/lib" -maxdepth 3 \
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
export PYTHONHOME=/opt/mesh-bbs
export PYTHONPATH=/opt/mesh-bbs/lib
exec /bin/python3.bin "$@"
PYWRAP
    chmod +x $out/bin/python3

    # Patch ELF interpreter + RPATH
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
        else
          echo "WARNING: could not find $libname (needed by $elf)" >&2
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
    cat > $out/bin/mesh-bbs << 'LAUNCHER'
#!/bin/sh
export PYTHONHOME=/opt/mesh-bbs
export PYTHONPATH=/opt/mesh-bbs/lib
exec /bin/python3.bin /opt/mesh-bbs/mesh_bbs.py "$@"
LAUNCHER
    chmod +x $out/bin/mesh-bbs
  '';

  meta = {
    description = "Minimal Meshtastic BBS + store-and-forward bot";
    homepage    = "https://github.com/nix-luckfox-builder";
  };
}
