# RF24Network — OSI layer 3 network driver for nRF24L01+
# Depends on RF24 (the base radio driver).
# https://github.com/nRF24/RF24Network

{ pkgs }:

let
  rf24 = import ./rf24.nix { inherit pkgs; };

  RF24NETWORK_REV    = "master";
  RF24NETWORK_SHA256 = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
  # Fill in with: nix-prefetch-github nRF24 RF24Network --rev master

in

pkgs.pkgsStatic.stdenv.mkDerivation {
  pname   = "rf24network";
  version = RF24NETWORK_REV;

  src = pkgs.fetchFromGitHub {
    owner  = "nRF24";
    repo   = "RF24Network";
    rev    = RF24NETWORK_REV;
    sha256 = RF24NETWORK_SHA256;
  };

  nativeBuildInputs = with pkgs.buildPackages; [ cmake pkg-config ];

  postPatch = ''
    find . -name "CMakeLists.txt" | xargs sed -i 's/ SHARED/ STATIC/g'
    find . \( -name "CMakeLists.txt" -o -name "*.cmake" \) | \
      xargs sed -i '/include(CPack)/d'
  '';

  cmakeFlags = [
    "-DCMAKE_POLICY_VERSION_MINIMUM=3.5"
    "-DRF24_DRIVER=SPIDEV"
    "-DBUILD_SHARED_LIBS=OFF"
    "-DPACK=OFF"
    "-Drf24_DIR=${rf24}/lib/cmake/RF24"
  ];

  meta = {
    description = "OSI layer 3 network driver for nRF24L01+";
    homepage    = "https://github.com/nRF24/RF24Network";
  };
}
