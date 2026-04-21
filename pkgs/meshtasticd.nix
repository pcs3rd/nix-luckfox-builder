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
  FIRMWARE_SHA256 = "sha256-FDDmEOYA9Fteu6BUU4r3dUdXdMX/4l/eacNAoB83t/o==";

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

  # Don't let the Nix cmake hook add an implicit ".." — we point cmake at the
  # source directory explicitly in configurePhase below.
  dontUseCmakeBuildDir = true;

  configurePhase = ''
    runHook preConfigure

    echo "=== source tree root ==="
    ls -1
    echo "=== CMakeLists.txt locations ==="
    find . -name "CMakeLists.txt" -maxdepth 4 | sort

    # Locate the CMakeLists.txt that owns the meshtasticd target.
    # Checked in order of likelihood across firmware repo versions:
    #   .                  (v2.5+ — cmake at repo root)
    #   ./linux            (some intermediate versions)
    #   ./portduino        (portduino abstraction layer only)
    CMAKE_SRC=""
    for candidate in . ./linux ./portduino ./cmake; do
      if [ -f "$candidate/CMakeLists.txt" ]; then
        CMAKE_SRC="$candidate"
        break
      fi
    done

    if [ -z "$CMAKE_SRC" ]; then
      echo "ERROR: could not find CMakeLists.txt in any expected location." >&2
      echo "Run:  nix log <drv>  and look for '=== CMakeLists.txt locations ===' above." >&2
      exit 1
    fi

    echo "=== using CMakeLists.txt in: $CMAKE_SRC ==="
    cmake -S "$CMAKE_SRC" -B _build \
      -DCMAKE_BUILD_TYPE=Release \
      -DTARGET_LINUX_PORTDUINO=1 \
      -DMESHTASTIC_EXCLUDE_BLUETOOTH=1 \
      -DMESHTASTIC_EXCLUDE_WIFI=1

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    cmake --build _build --target meshtasticd -j$NIX_BUILD_CORES
    runHook postBuild
  '';

  installPhase = ''
    mkdir -p $out/bin $out/etc/meshtasticd

    # Binary may land at _build/meshtasticd or _build/src/meshtasticd depending
    # on the CMake layout.  Find it wherever it ended up.
    bin=$(find _build -name "meshtasticd" -type f | head -1)
    if [ -z "$bin" ]; then
      echo "ERROR: meshtasticd binary not found after build" >&2
      find _build -name "*.elf" -o -name "meshtastic*" | head -20
      exit 1
    fi
    install -Dm755 "$bin" $out/bin/meshtasticd

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
