
{ pkgs }:

pkgs.pkgsStatic.stdenv.mkDerivation {
  pname   = "sysinfo";
  version = "1.0";

  # Single-file project — point src directly at the .c file.
  src = ./sysinfo.c;

  # No build system — compile directly with $CC.
  # -static is implied by pkgsStatic but explicit here for clarity.
  unpackPhase = ''
    cp $src sysinfo.c
  '';

  buildPhase = ''
    $CC -static -O2 -o sysinfo sysinfo.c
  '';

  installPhase = ''
    mkdir -p $out/bin
    cp sysinfo $out/bin/sysinfo
  '';

  meta.description = "Minimal /proc system-info tool for Luckfox";
}
