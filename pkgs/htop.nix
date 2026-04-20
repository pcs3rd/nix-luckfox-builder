# Example custom package: a small static C utility that prints system info.


{ lib, stdenv, fetchFromGitHub, ncurses, pkg-config, autoreconfHook }:

pkgs.pkgsStatic.stdenv.mkDerivation {
  pname   = "htop";
  version = "3.5.0";

  # Single-file project — point src directly at the .c file.
  src = fetchFromGitHub {
    "owner" = "htop-dev";
    "repo" = "htop";
    "rev" = "dd9d7b100faa8ae57ec20be32d6353952b15eeec";
    "hash" = "sha256-gydXIExIdsTbCQnyqlMf9h77hzPqihDr5FLw1pzSiWg=";
  };

  nativeBuildInputs = [
    autoreconfHook
    pkg-config
  ];

  buildInputs = [
    ncurses
  ];

  configureFlags = [
    "--enable-unicode"
  ];
  meta.description = "htop";
};


