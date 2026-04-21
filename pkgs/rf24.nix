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

  # The RF24 CMakeLists.txt either explicitly declares the library SHARED
  # or sets BUILD_SHARED_LIBS=ON in a way that overrides the -D flag.
  # Either way, the musl ARM32 static toolchain cannot produce shared libs —
  # the C++ RTTI symbols in libstdc++.a use relocations that binutils rejects.
  #
  # Fix: replace every occurrence of " SHARED" with " STATIC" across all
  # CMakeLists.txt files in the tree (catches both uppercase and lowercase
  # library names), then pass an initial cmake cache file to force the flag.
  postPatch = ''
    # Force every library target to be STATIC — the musl ARM32 toolchain
    # cannot link C++ RTTI from libstdc++.a into a shared object.
    find . -name "CMakeLists.txt" | xargs sed -i 's/ SHARED/ STATIC/g'

    # Disable CPack packaging — it looks for dpkg/rpmbuild which are absent
    # in the Nix sandbox and causes configure to abort.
    find . \( -name "CMakeLists.txt" -o -name "*.cmake" \) | \
      xargs sed -i '/include(CPack)/d'

    # Write a cmake initial-cache file that wins over any CACHE FORCE in the
    # project's own CMakeLists.txt (cmake -C is processed before any cmake_minimum_required).
    cat > init-cache.cmake << 'EOF'
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(PACK OFF CACHE BOOL "" FORCE)
EOF
  '';

  cmakeFlags = [
    "-DCMAKE_POLICY_VERSION_MINIMUM=3.5"
    "-DRF24_DRIVER=SPIDEV"
    "-DBUILD_SHARED_LIBS=OFF"
    "-DPACK=OFF"
    # -C path is relative to where cmake is invoked (the build dir),
    # so ../init-cache.cmake reaches the file we wrote in the source tree.
    "-C../init-cache.cmake"
  ];

  meta = {
    description = "nRF24L01+ driver library for Linux (SPI)";
    homepage    = "https://github.com/nRF24/RF24";
  };
}
