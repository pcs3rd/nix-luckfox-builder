# nrfnet — tunnel TCP/IP over nRF24L01+ radios via TUN/TAP
#
# Source: https://github.com/aarossig/nrfnet
#
# To fill in the hash, run:
#   nix-prefetch-github aarossig nrfnet
# then replace NRFNET_REV and NRFNET_SHA256 below.

{ pkgs }:

let
  NRFNET_REV    = "934b34ef4dbb071a90680a3d4326c098b0d1557d";
  NRFNET_SHA256 = "sha256-vSCRrYAAk8PEf9v7r75L0SMVSY1NU7wFNcv8q9ElT48=";

  rf24 = import ./rf24.nix { inherit pkgs; };
in

pkgs.pkgsStatic.stdenv.mkDerivation {
  pname   = "nrfnet";
  version = "unstable-${builtins.substring 0 8 NRFNET_REV}";

  src = pkgs.fetchFromGitHub {
    owner  = "aarossig";
    repo   = "nrfnet";
    rev    = NRFNET_REV;
    sha256 = NRFNET_SHA256;
  };

  nativeBuildInputs = [
    pkgs.buildPackages.cmake
    pkgs.buildPackages.pkg-config
  ];

  buildInputs = [
    pkgs.pkgsStatic.tclap
    rf24
  ];

  # nrfnet's CMakeLists.txt declares cmake_minimum_required < 3.5, which CMake
  # 3.27+ rejects outright.  This flag tells CMake to apply 3.5 policies anyway
  # so the build proceeds without touching upstream source.
  cmakeFlags = [ "-DCMAKE_POLICY_VERSION_MINIMUM=3.5" ];

  installPhase = ''
    mkdir -p $out/bin
    cp nrfnet $out/bin/nrfnet
  '';

  meta = {
    description = "Tunnel TCP/IP over nRF24L01+ radios using Linux TUN/TAP";
    homepage    = "https://github.com/aarossig/nrfnet";
  };
}
