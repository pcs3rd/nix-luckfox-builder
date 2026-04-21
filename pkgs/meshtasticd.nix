# meshtasticd — Meshtastic native Linux daemon
#
# Builds the Linux-native target from the meshtastic/firmware repo.
# meshtasticd connects to a LoRa radio (via SPI, serial, or USB) and
# provides a full Meshtastic node without any microcontroller involved.
#
# ── Fill in the source hash before building ──────────────────────────────────
#
#   nix-prefetch-github meshtastic firmware --rev 2.5.X
#
# Replace FIRMWARE_REV and FIRMWARE_SHA256 below with the output.
#
# ── Runtime config ────────────────────────────────────────────────────────────
#
# meshtasticd reads /etc/meshtasticd/config.yaml at startup.
# A template is installed at that path by this derivation.
# Edit it before flashing (or mount an overlay partition so writes persist).
#
# ── Dependencies ─────────────────────────────────────────────────────────────
#
# The Linux native build requires:
#   protobuf   — mesh packet serialisation
#   openssl    — AES-256-CTR channel encryption
#   yaml-cpp   — config.yaml parser
#   libbluetooth (optional) — Bluetooth companion app support
#
# ────────────────────────────────────────────────────────────────────────────

{ pkgs }:

let
  lib = pkgs.lib;

  # ── Pin these to the firmware release you want to run ──────────────────────
  # Run:  nix-prefetch-github meshtastic firmware --rev v2.5.X
  FIRMWARE_REV    = "d50caf231bd93ce45182bf20bcb4a070a15ee670";
  FIRMWARE_SHA256 = "sha256-NSsKxlFW5ai4j/blGrvEuAZVe5LsIe9fSDsFbTUdY0M=";

in

pkgs.stdenv.mkDerivation {
  pname   = "meshtasticd";
  version = "2.5-luckfox";

  src = pkgs.fetchFromGitHub {
    owner  = "meshtastic";
    repo   = "firmware";
    rev    = FIRMWARE_REV;
    sha256 = FIRMWARE_SHA256;
    # The firmware repo uses submodules for protobuf definitions and portduino.
    fetchSubmodules = true;
  };

  nativeBuildInputs = with pkgs.buildPackages; [
    cmake
    ninja
    pkg-config
    protobuf      # protoc compiler (runs on the build host)
  ];

  buildInputs = with pkgs; [
    protobuf      # libprotobuf for the target
    openssl
    yaml-cpp
    nlohmann_json # header-only; included via cmake find_package
  ];

  # The firmware repo's CMakeLists targets multiple platforms.
  # PORTDUINO selects the Linux-native (portduino abstraction layer) build.
  cmakeFlags = [
    "-DCMAKE_BUILD_TYPE=Release"
    "-DTARGET_LINUX_PORTDUINO=1"
    # Disable optional features that pull in large deps or don't apply here.
    "-DMESHTASTIC_EXCLUDE_BLUETOOTH=1"
    "-DMESHTASTIC_EXCLUDE_WIFI=1"
  ];

  # Build only the daemon binary, not the full test suite.
  buildPhase = ''
    cmake --build . --target meshtasticd -- -j$NIX_BUILD_CORES
  '';

  installPhase = ''
    mkdir -p $out/bin $out/etc/meshtasticd

    install -Dm755 meshtasticd $out/bin/meshtasticd

    # Install the default config template so the user can customise it.
    # The real config lives at /etc/meshtasticd/config.yaml on the target.
    if [ -f ../bin/config.yaml ]; then
      cp ../bin/config.yaml $out/etc/meshtasticd/config.yaml
    else
      # Emit a minimal functional config if the repo doesn't ship one.
      cat > $out/etc/meshtasticd/config.yaml << 'YAMLEOF'
# meshtasticd config — edit before flashing
# Full reference: https://meshtastic.org/docs/software/linux-native

Lora:
  Module: sx1262     # sx1262 | sx1276 | sx1278 | rf95
  CS: 7
  IRQ: 17
  Busy: 100
  Reset: 22
  # Region is set via the Meshtastic app or CLI after first boot
  # RegionCode: TBD

GPS:
  SerialPath: /dev/ttyS1   # remove if no GPS attached

Logging:
  LogLevel: warn   # trace | debug | info | warn | error
YAMLEOF
    fi
  '';

  meta = {
    description = "Meshtastic native Linux daemon (LoRa mesh networking)";
    homepage    = "https://meshtastic.org/docs/software/linux-native";
  };
}
