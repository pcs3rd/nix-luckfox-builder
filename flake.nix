{
  description = "Luckfox NixOS-style firmware system";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
  let
    system = "x86_64-darwin"; # macOS host
    linuxSystem = "x86_64-linux"; # builder target (important for image builds)

    pkgs = import nixpkgs {
      system = system;

      # cross compile for Luckfox (ARMv7 musl)
      crossSystem = {
        config = "armv7l-unknown-linux-musleabihf";
      };
    };

    lib = pkgs.lib;

    mkSystem = import ./lib/mkSystem.nix {
      inherit pkgs lib;
    };

    # 🔧 Main system (from configuration.nix)
    picoMiniB = mkSystem {
      configuration = ./configuration.nix;
    };

  in {
    ########################################
    # Main firmware output
    ########################################
    packages.${system}.pico-mini-b =
      picoMiniB.config.system.build.firmware;

    ########################################
    # Debug / development outputs
    ########################################

    # Just rootfs (works on macOS)
    packages.${system}.rootfs =
      picoMiniB.config.system.build.rootfs;

    # U-Boot bundle (works on macOS)
    packages.${system}.uboot =
      picoMiniB.config.system.build.uboot;

    # SD image (Linux-only; may be stubbed on macOS)
    packages.${system}.sdImage =
      picoMiniB.config.system.build.image;

    ########################################
    # Default build
    ########################################
    defaultPackage.${system} =
      picoMiniB.config.system.build.firmware;

    ########################################
    # Dev shell (optional but very useful)
    ########################################
    devShells.${system}.default = pkgs.mkShell {
      buildInputs = [
        pkgs.git
        pkgs.nixpkgs-fmt
      ];
    };
  };
}