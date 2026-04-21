# RF24 — nRF24L01+ driver library for Linux (SPI)
#
# Source: https://github.com/nRF24/RF24
#
# Required by nrfnet.  Build with the SPIDEV driver (no WiringPi / pigpio).
#
# ── Fill in the source hash before building ──────────────────────────────────
#
#   nix-prefetch-github nRF24 RF24 --rev v1.4.10
#
# Replace RF24_REV and RF24_SHA256 below with the output.
#
# ─────────────────────────────────────────────────────────────────────────────

{ pkgs }:

let
  RF24_REV    = "436c9eae36a74effcda30cc15ce16d449a093b19";
  RF24_SHA256 = "sha256-ZlVsGjRmLjw3nBCIY3YmIHACXir4S6RUrBQopSqZtBA="; # ← run: nix-prefetch-github nRF24 RF24 --rev v1.4.10

in

pkgs.pkgsStatic.stdenv.mkDerivation {
  pname   = "rf24";
  version = RF24_REV;

  src = pkgs.fetchFromGitHub {
    owner  = "nRF24";
    repo   = "RF24";
    rev    = RF24_REV;
    sha256 = RF24_SHA256;
  };

  nativeBuildInputs = with pkgs.buildPackages; [
    cmake
    pkg-config
  ];

  # RF24's CMakeLists.txt uses add_library(rf24 SHARED …) even when
  # BUILD_SHARED_LIBS=OFF is set via a cmake flag, because the flag is
  # evaluated after the library target is declared.  Patch the source so
  # the target is always STATIC — required for the musl ARM32 static build
  # where C++ RTTI relocations in libstdc++.a are unsupported.
  postPatch = ''
    sed -i 's/add_library(\s*rf24\s*SHARED/add_library(rf24 STATIC/g' CMakeLists.txt
  '';

  cmakeFlags = [
    # Use the Linux SPIDEV driver — no WiringPi / pigpio / mraa dependency.
    "-DCMAKE_POLICY_VERSION_MINIMUM=3.5"
    "-DRF24_DRIVER=SPIDEV"
    "-DBUILD_SHARED_LIBS=OFF"
  ];

  meta = {
    description = "nRF24L01+ driver library for Linux (SPI)";
    homepage    = "https://github.com/nRF24/RF24";
  };
}
