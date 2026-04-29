# shell.nix — brings in claude-code from sadjow/claude-code-nix
let
  claudeCodeNix = builtins.fetchTarball {
    url = "https://github.com/sadjow/claude-code-nix/archive/main.tar.gz";
    # Optional: pin the sha256 for reproducibility
    # sha256 = "sha256:...";
  };

  pkgs = import <nixpkgs> {
    system = builtins.currentSystem;
    config.allowUnfree = true;
  };

  claudeCode = (pkgs.callPackage "${claudeCodeNix}/package.nix" {});
in
pkgs.mkShell {
  packages = [
    claudeCode
    pkgs.rkdeveloptool
  ];

  shellHook = ''
    echo "Claude Code $(claude --version) ready"
  '';
}