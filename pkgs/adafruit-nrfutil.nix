# adafruit-nrfutil — serial DFU tool for nRF52840 (Adafruit bootloader)
#
# Built from PyPI since this package is not in the nixpkgs python package set.
#
# ── Updating the hash ────────────────────────────────────────────────────────
# If the build fails with a hash mismatch, run:
#   nix-prefetch-url --unpack \
#     https://files.pythonhosted.org/packages/source/a/adafruit-nrfutil/adafruit-nrfutil-0.5.3.post17.tar.gz
# and replace NRFUTIL_SHA256 below.
#
# ── Usage on device ──────────────────────────────────────────────────────────
#   mcu bootloader   # double-tap reset → enters Adafruit DFU bootloader
#   adafruit-nrfutil dfu serial -pkg firmware-heltec-t114-x.x.x.zip \
#                               -p /dev/ttyS1 -b 115200

{ pkgs }:

let
  lib    = pkgs.lib;
  python = pkgs.python3;

  NRFUTIL_VERSION = "0.5.3.post16";
  NRFUTIL_SHA256  = "sha256-iStzYacZ9JRSN9qMz3VOlRPbMvViiFJ4WuoQjc0lAJM=";
  # ↑ placeholder — build once with this value; Nix will print the real hash.

  # intelhex is also not in all nixpkgs versions — build it from PyPI too.
  INTELHEX_VERSION = "2.3.0";
  INTELHEX_SHA256  = "sha256-iStzYacZ9JRSN9qMz3VOlRPbMvViiFJ4WuoQjc0lAJM=";

  intelhex-pkg = python.pkgs.buildPythonPackage rec {
    pname   = "intelhex";
    version = INTELHEX_VERSION;
    format  = "setuptools";
    src = python.pkgs.fetchPypi {
      inherit pname version;
      sha256 = INTELHEX_SHA256;
    };
    doCheck = false;
  };

  nrfutil-pkg = python.pkgs.buildPythonPackage rec {
    pname   = "adafruit-nrfutil";
    version = NRFUTIL_VERSION;
    format  = "setuptools";
    src = python.pkgs.fetchPypi {
      inherit pname version;
      sha256 = NRFUTIL_SHA256;
    };
    propagatedBuildInputs = with python.pkgs; [
      click
      pyserial
      tqdm
      cryptography
      intelhex-pkg
    ];
    doCheck = false;
  };

  deps = [ nrfutil-pkg intelhex-pkg ] ++ (with python.pkgs; [
    click pyserial tqdm cryptography
  ]);

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
  version = NRFUTIL_VERSION;

  dontUnpack = true;
  nativeBuildInputs = [ pkgs.buildPackages.patchelf ];
  dontBuild  = true;
  dontFixup  = true;

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
        while read -r so; do patchelf --set-rpath "/lib" "$so" 2>/dev/null || true; done
    done

    # ── Bundled site-packages ─────────────────────────────────────────────
    cp -rLT ${bundledLibs} $out/opt/adafruit-nrfutil/lib/
    find "$out/opt/adafruit-nrfutil/lib" -maxdepth 3 \
      \( -name 'test' -o -name 'tests' \) -type d \
      -exec rm -rf {} + 2>/dev/null || true

    # ── Python binary ─────────────────────────────────────────────────────
    mkdir -p $out/bin $out/lib
    realPython=$(find ${python}/bin -name '.python*-wrapped' | head -1)
    [ -z "$realPython" ] && realPython=$(readlink -f ${python}/bin/python3)
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
      patchelf --print-needed "$elf" 2>/dev/null | while read -r libname; do
        [ -f "$out/lib/$libname" ] && continue
        found=$(find -L \
          ${python} ${pkgs.zlib} ${pkgs.libffi} ${pkgs.openssl.out} \
          ${pkgs.sqlite} ${pkgs.bzip2} ${pkgs.xz} ${pkgs.ncurses} \
          ${pkgs.expat} ${pkgs.readline} ${pkgs.stdenv.cc.cc.lib} \
          -name "$libname" -type f 2>/dev/null | head -1)
        if [ -n "$found" ] && [ -f "$found" ]; then
          install -Dm755 "$found" "$out/lib/$libname"
          patchelf --set-rpath "/lib" "$out/lib/$libname" 2>/dev/null || true
          copy_needed "$found"
        fi
      done
    }
    copy_needed "$realPython"
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
