
{
  description = "Luckfox full firmware pipeline (Rockchip NAND/eMMC layout + U-Boot mode A)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

{
  outputs = { nixpkgs, self }:
  let
    pkgs = import nixpkgs {
      system = "x86_64-linux";
      crossSystem.config = "armv7l-unknown-linux-musleabihf";
    };

    lib = pkgs.lib;

    mkSystem = import ./lib/mkSystem.nix { inherit pkgs lib; };

    system = mkSystem {
      configuration = ./configurations/configuration.nix;
    };

  in {
    packages.x86_64-linux.default =
      system.config.system.build.firmware;
  };
}
}
