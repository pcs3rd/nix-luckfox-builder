# Example custom package: a small static C utility that prints system info.


{ pkgs, fetchFromGitHub }:

pkgs.pkgsStatic.stdenv.mkDerivation {
  pname   = "htop";
  version = "3.5.0";

  # Single-file project — point src directly at the .c file.
  src = fetchFromGitHub {
    "owner": "htop-dev",
    "repo": "htop",
    "rev": "dd9d7b100faa8ae57ec20be32d6353952b15eeec",
    "hash": "sha256-gydXIExIdsTbCQnyqlMf9h77hzPqihDr5FLw1pzSiWg="
};

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
