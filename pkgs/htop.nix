{ lib
, pkgs
, fetchFromGitHub
, ncurses
, pkg-config
, autoreconfHook
}:

pkgs.pkgsStatic.stdenv.mkDerivation rec {
  pname = "htop";
  version = "3.5.0";

  src = fetchFromGitHub {
    owner = "htop-dev";
    repo = "htop";
    rev = "dd9d7b100faa8ae57ec20be32d6353952b15eeec";
    hash = "sha256-gydXIExIdsTbCQnyqlMf9h77hzPqihDr5FLw1pzSiWg=";
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

  meta = with lib; {
    description = "Interactive process viewer";
    homepage = "https://htop.dev/";
    license = licenses.gpl2Only;
    platforms = platforms.linux;
  };
}