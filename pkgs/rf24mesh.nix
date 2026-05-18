# RF24Mesh — dynamic addressing mesh layer for nRF24L01+
# Depends on RF24Network (which depends on RF24).
# https://github.com/nRF24/RF24Mesh

{ pkgs }:

let
  rf24        = import ./rf24.nix        { inherit pkgs; };
  rf24network = import ./rf24network.nix { inherit pkgs; };

  RF24MESH_REV    = "master";
  RF24MESH_SHA256 = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
  # Fill in with: nix-prefetch-github nRF24 RF24Mesh --rev master

in

pkgs.pkgsStatic.stdenv.mkDerivation {
  pname   = "rf24mesh";
  version = RF24MESH_REV;

  src = pkgs.fetchFromGitHub {
    owner  = "nRF24";
    repo   = "RF24Mesh";
    rev    = RF24MESH_REV;
    sha256 = RF24MESH_SHA256;
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
    "-Drf24network_DIR=${rf24network}/lib/cmake/RF24Network"
  ];

  meta = {
    description = "Dynamic addressing mesh layer for nRF24L01+";
    homepage    = "https://github.com/nRF24/RF24Mesh";
  };
}
