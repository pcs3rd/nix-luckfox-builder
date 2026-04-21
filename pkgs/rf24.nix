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

  # RF24's CMakeLists.txt hardcodes add_library(rf24 SHARED …).
  # The musl ARM32 static toolchain cannot produce shared libs — C++ RTTI
  # symbols in libstdc++.a use relocations that binutils-arm rejects.
  # Two passes:
  #   1. On any add_library line mentioning rf24, flip SHARED → STATIC.
  #   2. Drop set_target_properties calls that set SOVERSION/VERSION (those
  #      properties only make sense for shared libs and cause cmake to try
  #      to create versioned .so symlinks even on a STATIC target).
  postPatch = ''
    sed -i '/add_library.*rf24/s/SHARED/STATIC/g'  CMakeLists.txt
    sed -i '/SOVERSION\|set_target_properties.*VERSION/d' CMakeLists.txt
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
