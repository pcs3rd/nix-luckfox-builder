# nrfnet — tunnel TCP/IP over nRF24L01+ radios via TUN/TAP
#
# Source: https://github.com/aarossig/nrfnet
#
# To fill in the hash, run:
#   nix-prefetch-github aarossig nrfnet
# then replace NRFNET_REV and NRFNET_SHA256 below.
#
# spiDev: which /dev/spidevB.C to use.  RF24 SPIDEV maps CSN = B*10 + C, so:
#   { bus = 0; cs = 0; }  →  CSN = 0   →  /dev/spidev0.0
#   { bus = 1; cs = 0; }  →  CSN = 10  →  /dev/spidev1.0  (default — spi1 on RV1103)
#
# The Luckfox Pico Mini A exposes spi1 on its GPIO header; the DTS patch in
# luckfox-kernel.nix enables it with a rockchip,spidev child, which the kernel
# enumerates as /dev/spidev1.0.  Override spiDev if your board differs.

{ pkgs, spiDev ? { bus = 1; cs = 0; } }:

let
  NRFNET_REV    = "934b34ef4dbb071a90680a3d4326c098b0d1557d";
  NRFNET_SHA256 = "sha256-vSCRrYAAk8PEf9v7r75L0SMVSY1NU7wFNcv8q9ElT48=";

  rf24   = import ./rf24.nix { inherit pkgs; };
  # RF24 SPIDEV CSN encodes the spidev path: CSN = bus*10 + cs
  csnPin = spiDev.bus * 10 + spiDev.cs;
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

  # Patch the hardcoded CSN=0 in radio_transport.cc so RF24 opens the correct
  # /dev/spidevB.C device.  nrfnet has no --csn_pin argument; the value is
  # baked into the RF24 constructor call: RF24(ce_pin, csn).
  # RF24 SPIDEV interprets csn as bus*10+cs, so csn=10 → /dev/spidev1.0.
  postPatch = ''
    echo "nrfnet: patching RF24 CSN to ${toString csnPin} (/dev/spidev${toString spiDev.bus}.${toString spiDev.cs})"

    # Locate radio_transport.cc — the path varies between revisions.
    RF24_SRC=$(find . -name "radio_transport.cc" | head -1)
    if [ -z "$RF24_SRC" ]; then
      echo "ERROR: radio_transport.cc not found — source tree layout:" >&2
      find . -name "*.cc" | head -20 >&2
      exit 1
    fi
    echo "nrfnet: found radio_transport.cc at $RF24_SRC"

    sed -i 's/make_unique<RF24>(config_.ce_pin(), 0)/make_unique<RF24>(config_.ce_pin(), ${toString csnPin})/' \
      "$RF24_SRC"

    # Verify the substitution landed — fail loudly if the line changed upstream.
    if grep -q 'make_unique<RF24>(config_.ce_pin(), ${toString csnPin})' "$RF24_SRC"; then
      echo "nrfnet: CSN patch applied successfully"
    else
      echo "nrfnet: WARNING — CSN patch did not match; dumping RF24 constructor lines for diagnosis:" >&2
      grep -n 'RF24\|make_unique' "$RF24_SRC" >&2 || true
      echo "nrfnet: continuing build — RF24 will use default CSN=0 (/dev/spidev0.0)" >&2
    fi
  '';

  # nrfnet's CMakeLists.txt declares cmake_minimum_required < 3.5, which CMake
  # 3.27+ rejects outright.  This flag tells CMake to apply 3.5 policies anyway
  # so the build proceeds without touching upstream source.
  cmakeFlags = [ "-DCMAKE_POLICY_VERSION_MINIMUM=3.5" ];

  installPhase = ''
    mkdir -p $out/bin
    # The cmake target is named "nerfnet" (the project's internal name).
    # Install it as "nrfnet" so the service script and users find it at /bin/nrfnet.
    cp nerfnet/net/nerfnet $out/bin/nrfnet
  '';

  meta = {
    description = "Tunnel TCP/IP over nRF24L01+ radios using Linux TUN/TAP";
    homepage    = "https://github.com/aarossig/nrfnet";
  };
}
