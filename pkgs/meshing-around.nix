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
    # maidenhead — not in nixpkgs; bundled as maidenhead.py in installPhase
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

  nativeBuildInputs = [ pkgs.buildPackages.patchelf ];

  dontBuild  = true;
  dontFixup  = true;   # skip strip/patchelf — Python scripts + a foreign ELF

  installPhase = ''
    # ── Application source ────────────────────────────────────────────────
    mkdir -p $out/opt/meshing-around
    cp -r . $out/opt/meshing-around/

    # ── Python standard library ───────────────────────────────────────────
    # Python needs its stdlib (encodings, os, io, …) before it can do
    # anything.  The compiled-in prefix points to /nix/store/…, which
    # does not exist on the target.  Copy the stdlib and use PYTHONHOME
    # to redirect.  Layout:  /opt/meshing-around/lib/python3.X/  ← stdlib
    #                         /opt/meshing-around/lib/            ← site-pkgs
    # With PYTHONHOME=/opt/meshing-around, Python finds lib/python3.X/.
    mkdir -p $out/opt/meshing-around/lib
    for pyLibDir in ${python}/lib/python*/; do
      pyVer=$(basename "$pyLibDir")
      mkdir -p "$out/opt/meshing-around/lib/$pyVer"
      cp -rLT "$pyLibDir" "$out/opt/meshing-around/lib/$pyVer"

      # ── Trim heavyweight stdlib directories not needed by mesh_bot ─────────
      # These modules add 40-50 MB uncompressed and are never imported at runtime.
      #   test / unittest  — test suites
      #   tkinter          — Tk GUI bindings
      #   idlelib          — IDLE IDE
      #   turtledemo       — turtle graphics demos
      #   lib2to3          — Python 2→3 migration tool
      #   ensurepip        — pip bootstrapper (no pip on embedded target)
      #   distutils        — legacy build system
      #   venv             — virtual environment support
      for trimDir in test unittest tkinter idlelib turtledemo lib2to3 ensurepip distutils venv; do
        rm -rf "$out/opt/meshing-around/lib/$pyVer/$trimDir" || true
      done
      # Drop per-module __pycache__ dirs inside any remaining test directories.
      find "$out/opt/meshing-around/lib/$pyVer" \
        -name '__pycache__' -prune -exec rm -rf {} \; 2>/dev/null || true

      # Patch RPATH of every .so in the stdlib so dlopen finds /lib deps.
      find "$out/opt/meshing-around/lib/$pyVer" -name '*.so*' -type f | \
        while read -r so; do
          patchelf --set-rpath "/lib" "$so" 2>/dev/null || true
        done
    done

    # ── Bundled site-packages ─────────────────────────────────────────────
    cp -rLT ${bundledLibs} $out/opt/meshing-around/lib/

    # Trim test directories from bundled site-packages (~5-10 MB).
    find "$out/opt/meshing-around/lib" -maxdepth 3 \
      \( -name 'test' -o -name 'tests' \) -type d \
      -exec rm -rf {} + 2>/dev/null || true

    # ── maidenhead — not in nixpkgs; ship a minimal pure-Python implementation
    # Implements toMaiden(lat, lon) and toLoc(maiden) per the ITU-R M.1079 spec.
    cat > "$out/opt/meshing-around/lib/maidenhead.py" << 'MAIDENHEAD'
"""
Maidenhead grid locator — minimal pure-Python implementation.
Bundled by the Nix build because maidenhead is not in nixpkgs.
"""

__version__ = "1.0.0-nix-bundled"


def toMaiden(lat: float, lon: float, precision: int = 3) -> str:
    """Convert (latitude, longitude) to a Maidenhead grid locator string.

    precision controls the number of pairs of characters returned:
      1 → 2 chars  (field, e.g. "IO")
      2 → 4 chars  (square, e.g. "IO91")
      3 → 6 chars  (subsquare, e.g. "IO91wm")  ← default
      4 → 8 chars  (extended square)
    """
    if not -90 <= lat <= 90:
        raise ValueError(f"Latitude {lat} out of range -90..90")
    if not -180 <= lon <= 180:
        raise ValueError(f"Longitude {lon} out of range -180..180")

    lon += 180.0
    lat += 90.0

    maiden = (
        chr(ord("A") + int(lon / 20))
        + chr(ord("A") + int(lat / 10))
    )
    if precision < 2:
        return maiden

    maiden += str(int((lon % 20) / 2)) + str(int(lat % 10))
    if precision < 3:
        return maiden

    maiden += (
        chr(ord("a") + int((lon % 2) * 12))
        + chr(ord("a") + int((lat % 1) * 24))
    )
    if precision < 4:
        return maiden

    maiden += (
        str(int(((lon % 2) * 12 % 1) * 10))
        + str(int(((lat % 1) * 24 % 1) * 10))
    )
    return maiden


def toLoc(maiden: str) -> tuple:
    """Convert a Maidenhead grid locator to (latitude, longitude).

    Returns the centre of the smallest encoded grid cell.
    """
    maiden = maiden.strip().upper()
    n = len(maiden)
    if n < 2:
        raise ValueError(f"Grid square {maiden!r} is too short")

    lon = (ord(maiden[0]) - ord("A")) * 20.0 - 180.0
    lat = (ord(maiden[1]) - ord("A")) * 10.0 - 90.0

    if n >= 4:
        lon += int(maiden[2]) * 2.0
        lat += int(maiden[3]) * 1.0

    if n >= 6:
        lon += (ord(maiden[4]) - ord("A") + 0.5) * (2.0 / 24)
        lat += (ord(maiden[5]) - ord("A") + 0.5) * (1.0 / 24)
    elif n >= 4:
        lon += 1.0
        lat += 0.5
    else:
        lon += 10.0
        lat += 5.0

    if n >= 8:
        lon += (int(maiden[6]) + 0.5) * (2.0 / 240)
        lat += (int(maiden[7]) + 0.5) * (1.0 / 240)

    return lat, lon
MAIDENHEAD

    # ── Python interpreter + dynamic linker + shared libraries ───────────
    # nixpkgs wraps the real CPython ELF in a small makeBinaryWrapper shim
    # (~7 KB) that execs the real interpreter at an absolute /nix/store/…
    # path — which does not exist on the target.  Find the real ELF first.
    # For cross-compiled packages the wrapper may not exist; fall back to
    # the versioned binary (e.g. python3.12) which IS the real ELF.
    mkdir -p $out/bin $out/lib

    realPython=$(find ${python}/bin -name '.python*-wrapped' | head -1)
    if [ -z "$realPython" ]; then
      realPython=$(readlink -f ${python}/bin/python3)
    fi
    echo "=== using Python ELF: $realPython ==="

    # Install the real ELF as python3.bin, then create a /bin/python3 wrapper
    # that sets PYTHONHOME and PYTHONPATH before exec-ing it.
    # This means 'python3 script.py' works correctly regardless of how it is
    # invoked — directly from the shell, from a service script, or via exec().
    install -Dm755 "$realPython" $out/bin/python3.bin

    cat > $out/bin/python3 << 'PYWRAP'
#!/bin/sh
export PYTHONHOME=/opt/meshing-around
export PYTHONPATH=/opt/meshing-around/lib
exec /bin/python3.bin "$@"
PYWRAP
    chmod +x $out/bin/python3

    # Copy the ELF interpreter (musl dynamic linker, e.g. ld-musl-armhf.so.1)
    # and patch the copied binary to use /lib/<linker> on the target instead of
    # the hardcoded /nix/store/…/lib/<linker> path.  Without this the kernel
    # returns ENOENT ("not found") even though the binary file itself exists.
    interp=$(patchelf --print-interpreter "$realPython" 2>/dev/null || true)
    echo "=== ELF interpreter: $interp ==="
    if [ -n "$interp" ] && [ -f "$interp" ]; then
      interpName=$(basename "$interp")
      install -Dm755 "$interp" "$out/lib/$interpName"
      # Rewrite the interpreter path in the real ELF (not the wrapper script).
      patchelf --set-interpreter "/lib/$interpName" $out/bin/python3.bin
      # Also set RPATH so the musl linker finds our bundled shared libs in /lib.
      patchelf --set-rpath "/lib" $out/bin/python3.bin
    fi

    # ── Shared library bundling ──────────────────────────────────────────────
    #
    # copy_needed ELF
    #
    # For each DT_NEEDED entry in ELF:
    #   1. Read the ELF's own RPATH — these are the exact Nix store dirs the
    #      build system placed every dep in. No guessing required.
    #   2. Follow symlinks (libz.so.1 → libz.so.1.2.13) to get the real file.
    #   3. Fall back to a broad search across known packages if RPATH search
    #      fails (e.g. for gcc runtime libs that have no RPATH entry).
    #   4. Install into $out/lib/ and recurse on the ORIGINAL store path so
    #      we never read back the already-patched copy (which has RPATH=/lib).
    #
    # ALWAYS call this on the ORIGINAL nix store path, not on files already
    # copied to $out/lib/ (those have had RPATH replaced with /lib).
    copy_needed() {
      local elf="$1"
      local rpath
      rpath=$(patchelf --print-rpath "$elf" 2>/dev/null || true)

      patchelf --print-needed "$elf" 2>/dev/null | while read -r libname; do
        [ -f "$out/lib/$libname" ] && continue

        found=""

        # Primary: walk the RPATH dirs that the Nix build recorded
        for rdir in $(echo "$rpath" | tr ':' '\n'); do
          [ -z "$rdir" ] && continue
          candidate="$rdir/$libname"
          if [ -e "$candidate" ]; then
            found=$(readlink -f "$candidate" 2>/dev/null || echo "$candidate")
            break
          fi
        done

        # Fallback: broad search (catches gcc runtime, musl, etc.)
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
          # Recurse on the ORIGINAL store path so its RPATH is still intact
          copy_needed "$found"
        else
          echo "WARNING: could not find $libname (needed by $elf)" >&2
        fi
      done
    }

    echo "=== bundling shared libs for Python binary ==="
    copy_needed "$realPython"

    # Walk the ORIGINAL Nix store extension modules (RPATH still points to
    # store deps — not the copies in $out which already have RPATH=/lib).
    echo "=== bundling shared libs for C extension modules ==="
    for pyLibDir in ${python}/lib/python*/; do
      find -L "$pyLibDir" -name '*.so*' -type f | while read -r so; do
        copy_needed "$so"
      done
    done
    # Site-packages bundled from nixpkgs — same treatment
    find -L ${bundledLibs} -name '*.so*' -type f 2>/dev/null | while read -r so; do
      copy_needed "$so"
    done

    echo "=== lib contents ==="
    ls $out/lib/ || true

    # ── Launcher ─────────────────────────────────────────────────────────
    cat > $out/bin/meshing-around << 'LAUNCHER'
#!/bin/sh
# meshing-around launcher
# PYTHONHOME tells CPython where to find its standard library (lib/python3.X/).
# PYTHONPATH adds the bundled site-packages on top of that.
export PYTHONHOME=/opt/meshing-around
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
