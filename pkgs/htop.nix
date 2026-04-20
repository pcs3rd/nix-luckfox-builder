{ pkgs }:

pkgs.pkgsStatic.stdenv.mkDerivation rec {
  pname = "htop";
  version = "3.5.0";

  src = pkgs.fetchFromGitHub {
    owner = "htop-dev";
    repo = "htop";
    rev = "dd9d7b100faa8ae57ec20be32d6353952b15eeec";
    hash = "sha256-gydXIExIdsTbCQnyqlMf9h77hzPqihDr5FLw1pzSiWg=";
  };

  nativeBuildInputs = [
    pkgs.autoreconfHook
    pkgs.pkg-config
  ];

  buildInputs = [
    pkgs.pkgsStatic.ncurses
  ];

  configureFlags = [
    "--enable-unicode"
  ];

  postInstall = ''
    mkdir -p $out/etc/terminfo/v
    mkdir -p $out/etc/terminfo/l
    cp ${pkgs.ncurses}/share/terminfo/v/vt100 $out/etc/terminfo/v/
    cp ${pkgs.ncurses}/share/terminfo/l/linux $out/etc/terminfo/l/
  '';

  meta = with pkgs.lib; {
    description = "Interactive process viewer";
    homepage = "https://htop.dev/";
    license = licenses.gpl2Only;
    platforms = platforms.linux;
  };
}