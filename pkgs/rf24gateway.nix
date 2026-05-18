# RF24Gateway — TUN/TAP IP gateway for nRF24 mesh networks
#
# Builds the RF24Gateway library plus a minimal launcher binary (/bin/rf24gateway).
# The gateway node (node ID 0) bridges the nRF24 mesh to a Linux TUN interface,
# allowing standard IP traffic to flow across the radio link.
#
# Usage on device:
#   rf24gateway --ce_pin 62 --channel 1
#
# Options:
#   --ce_pin N     GPIO number for the nRF24 CE pin (default: 62 = GPIO1_C6)
#   --channel N    RF channel 0-125 (default: 1)
#   --node_id N    Mesh node ID; 0 = master/gateway (default: 0)
#   --ip ADDR      IP address for the tun interface (default: 10.0.0.1)
#   --mask MASK    Subnet mask (default: 255.255.255.0)
#
# After start, configure IP on the tun interface manually (if not using the
# services.rf24gateway module which does it automatically):
#   ip addr add 10.0.0.1/24 dev tun_rf24
#   ip link set tun_rf24 up
#
# https://github.com/nRF24/RF24Gateway

{ pkgs }:

let
  rf24        = import ./rf24.nix        { inherit pkgs; };
  rf24network = import ./rf24network.nix { inherit pkgs; };
  rf24mesh    = import ./rf24mesh.nix    { inherit pkgs; };

  RF24GW_REV    = "master";
  RF24GW_SHA256 = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
  # Fill in with: nix-prefetch-github nRF24 RF24Gateway --rev master

  # Minimal C++ launcher — no ncurses dependency.
  # Parses --ce_pin, --channel, --node_id, --ip, --mask from argv.
  # Starts the gateway, then loops calling gw.update() until SIGTERM/SIGINT.
  launcherSrc = pkgs.writeText "rf24gateway-main.cpp" ''
    #include <RF24Gateway.h>
    #include <cstdio>
    #include <cstdlib>
    #include <cstring>
    #include <unistd.h>
    #include <signal.h>
    #include <sys/socket.h>
    #include <sys/ioctl.h>
    #include <net/if.h>
    #include <arpa/inet.h>
    #include <linux/if_tun.h>

    static volatile bool g_running = true;
    static void on_signal(int) { g_running = false; }

    static int arg_int(int argc, char** argv, const char* flag, int def) {
        for (int i = 1; i + 1 < argc; ++i)
            if (strcmp(argv[i], flag) == 0) return atoi(argv[i+1]);
        return def;
    }
    static const char* arg_str(int argc, char** argv, const char* flag, const char* def) {
        for (int i = 1; i + 1 < argc; ++i)
            if (strcmp(argv[i], flag) == 0) return argv[i+1];
        return def;
    }

    int main(int argc, char** argv) {
        int         ce_pin   = arg_int(argc, argv, "--ce_pin",  62);
        int         channel  = arg_int(argc, argv, "--channel", 1);
        int         node_id  = arg_int(argc, argv, "--node_id", 0);
        const char* ip_str   = arg_str(argc, argv, "--ip",      "10.0.0.1");
        const char* mask_str = arg_str(argc, argv, "--mask",    "255.255.255.0");

        signal(SIGINT,  on_signal);
        signal(SIGTERM, on_signal);

        // CSN = 0 → /dev/spidev0.0 (symlinked to /dev/spidev1.0 by spidev-alias service)
        RF24        radio(ce_pin, 0);
        RF24Network network(radio);
        RF24Mesh    mesh(radio, network);
        RF24Gateway gw(radio, network, mesh);

        printf("rf24gateway: ce_pin=%d channel=%d node_id=%d ip=%s/%s\n",
               ce_pin, channel, node_id, ip_str, mask_str);

        if (!gw.begin(node_id, channel)) {
            fprintf(stderr, "rf24gateway: begin() failed — check SPI wiring and /dev/net/tun\n");
            return 1;
        }

        printf("rf24gateway: started — tun interface ready\n");

        while (g_running) {
            gw.update(true);
            usleep(2000);
        }

        printf("rf24gateway: shutting down\n");
        return 0;
    }
  '';

in

pkgs.pkgsStatic.stdenv.mkDerivation {
  pname   = "rf24gateway";
  version = RF24GW_REV;

  src = pkgs.fetchFromGitHub {
    owner  = "nRF24";
    repo   = "RF24Gateway";
    rev    = RF24GW_REV;
    sha256 = RF24GW_SHA256;
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
    "-Drf24mesh_DIR=${rf24mesh}/lib/cmake/RF24Mesh"
  ];

  # After building the library, compile the launcher binary against it.
  postInstall = ''
    echo "Building rf24gateway launcher..."
    $CXX -O2 -std=c++17 \
      -I${rf24}/include/RF24 \
      -I${rf24network}/include/RF24Network \
      -I${rf24mesh}/include/RF24Mesh \
      -I$out/include/RF24Gateway \
      ${launcherSrc} \
      -L${rf24}/lib -lRF24 \
      -L${rf24network}/lib -lRF24Network \
      -L${rf24mesh}/lib -lRF24Mesh \
      -L$out/lib -lRF24Gateway \
      -o $out/bin/rf24gateway
  '';

  meta = {
    description = "TUN/TAP IP gateway for nRF24 mesh networks";
    homepage    = "https://github.com/nRF24/RF24Gateway";
  };
}
