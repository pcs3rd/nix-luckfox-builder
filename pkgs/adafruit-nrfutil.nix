# adafruit-nrfutil — serial DFU tool for nRF52840 (Adafruit bootloader)
#
# Used to upload Meshtastic firmware to the Heltec T114 (nRF52840) over
# UART when USB is unavailable.  Workflow:
#
#   1. Wire Luckfox UART TX/RX to T114 RX/TX + shared GND.
#   2. Wire reset MOSFET to T114 RESET (GPIO 47, resetPin in mcu module).
#   3. Enter bootloader:  mcu bootloader
#   4. Upload firmware:   adafruit-nrfutil dfu serial -pkg firmware.zip -p /dev/ttySx -b 115200
#
# The firmware .zip is produced by the Meshtastic build system (or downloaded
# from the Meshtastic GitHub releases as "firmware-heltec-t114-*.zip").
#
# Packaging follows the same PYTHONHOME bundling strategy as meshtastic-cli.nix:
# copy Python stdlib + site-packages into /opt/adafruit-nrfutil so the binary
# works on the musl rootfs without a system Python installation.

{ pkgs }:

let
  lib = pkgs.lib;

  python = pkgs.python3;

  deps = with python.pkgs; [
    adafruit-nrfutil   # core DFU tool
    click              # CLI framework (dependency)
    pyserial           # serial port access
    tqdm               # progress bars
    intelhex           # Intel HEX file parsing
    cryptography       # signing/verification support
  ];

  bundledLibs = pkgs.runCommand "adafruit-nrfutil-site-packages" {} ''
    mkdir -p $out

    copy_sp() {
      local pkg="$1"
      for sp in "$pkg"/lib/python*/site-packages; do
        [ -d "$sp" ] || continue
        cp -rLT "$sp" "$out" 2>/dev/null || true
      done
    }

    ${lib.concatMapStrings (d: "copy_sp \"${d}\"\n") deps}

    ${lib.concatMapStrings (d:
      lib.concatMapStrings (t: "copy_sp \"${t}\"\n")
        (d.propagatedBuildInputs or [])
    ) deps}
  '';

in

pkgs.stdenv.mkDerivation {
  pname   = "adafruit-nrfutil";
  version = python.pkgs.adafruit-nrfutil.version;

  dontUnpack = true;

  nativeBuildInputs = [ pkgs.buildPackages.patchelf ];

  dontBuild = true;
  dontFixup = true;

  installPhase = ''
    # ── Python standard library ───────────────────────────────────────────
    mkdir -p $out/opt/adafruit-nrfutil/lib
    for pyLibDir in ${python}/lib/python*/; do
      pyVer=$(basename "$pyLibDir")
      mkdir -p "$out/opt/adafruit-nrfutil/lib/$pyVer"
      cp -rLT "$pyLibDir" "$out/opt/adafruit-nrfutil/lib/$pyVer"

      for trimDir in test unittest tkinter idlelib turtledemo lib2to3 ensurepip distutils venv; do
        rm -rf "$out/opt/adafruit-nrfutil/lib/$pyVer/$trimDir" || true
      done
      find "$out/opt/adafruit-nrfutil/lib/$pyVer" \
        -name '__pycache__' -prune -exec rm -rf {} \; 2>/dev/null || true

      find "$out/opt/adafruit-nrfutil/lib/$pyVer" -name '*.so*' -type f | \
        while read -r so; do
          patchelf --set-rpath "/lib" "$so" 2>/dev/null || true
        done
    done

    # ── Bundled site-packages ─────────────────────────────────────────────
    cp -rLT ${bundledLibs} $out/opt/adafruit-nrfutil/lib/

    find "$out/opt/adafruit-nrfutil/lib" -maxdepth 3 \
      \( -name 'test' -o -name 'tests' \) -type d \
      -exec rm -rf {} + 2>/dev/null || true

    # ── Python binary ─────────────────────────────────────────────────────
    mkdir -p $out/bin $out/lib

    realPython=$(find ${python}/bin -name '.python*-wrapped' | head -1)
    if [ -z "$realPython" ]; then
      realPython=$(readlink -f ${python}/bin/python3)
    fi

    install -Dm755 "$realPython" $out/bin/python3.bin

    interp=$(patchelf --print-interpreter "$realPython" 2>/dev/null || true)
    if [ -n "$interp" ] && [ -f "$interp" ]; then
      interpName=$(basename "$interp")
      install -Dm755 "$interp" "$out/lib/$interpName"
      patchelf --set-interpreter "/lib/$interpName" $out/bin/python3.bin
      patchelf --set-rpath        "/lib"             $out/bin/python3.bin
    fi

    # ── Shared library bundling ───────────────────────────────────────────
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
    cat > $out/bin/adafruit-nrfutil << 'LAUNCHER'
#!/bin/sh
export PYTHONHOME=/opt/adafruit-nrfutil
export PYTHONPATH=/opt/adafruit-nrfutil/lib
exec /bin/python3.bin -m nordicsemi "$@"
LAUNCHER
    chmod +x $out/bin/adafruit-nrfutil
  '';

  meta = {
    description = "Serial DFU tool for nRF52840 with Adafruit bootloader";
    homepage    = "https://github.com/adafruit/Adafruit_nRF52_nrfutil";
  };
}
