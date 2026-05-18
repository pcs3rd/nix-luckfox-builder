# shell.nix — development shell for nix-luckfox-builder
#
# Works on NixOS and any Linux host with Nix installed.
# Use with:
#   nix-shell          — classic nix-shell
#   nix develop        — flake devShell (same packages, defined in flake.nix)
#
# What's included:
#   nixpkgs-fmt    — format .nix files
#   git            — flake input tracking + dirty-tree detection
#   rkdeveloptool  — Rockchip USB flashing (maskrom mode)
#   picocom        — serial console for UART / USB-serial
#   qemu           — qemu-system-arm for A/B rootfs testing (Linux only)

{ pkgs ? import <nixpkgs> { config.allowUnfree = true; } }:

pkgs.mkShell {
  buildInputs = with pkgs; [
    # Nix tooling
    nixpkgs-fmt        # format .nix files: nixpkgs-fmt **/*.nix

    # Build helpers
    git                # required for flake input tracking + dirty-tree detection
    gnumake            # useful for manual kernel config inspection

    # Flashing
    rkdeveloptool      # Rockchip USB flashing tool (maskrom mode)
    #                    Usage: rkdeveloptool db rv1106_miniloader.bin
    #                           rkdeveloptool wl 0 sd-flashable.img
    #                           rkdeveloptool rd

    # Serial console
    picocom            # picocom -b 115200 /dev/ttyUSB0
    #                    Ctrl-A Ctrl-X to exit

    # QEMU ARM emulation for A/B rootfs testing
    qemu               # nix run .#qemu-ab
  ];

  shellHook = ''
    echo ""
    echo "  nix-luckfox-builder dev shell"
    echo ""
    echo "  Build targets:"
    echo "    nix build .#packages.x86_64-linux.sdImage-flashable   — full SD image"
    echo "    nix build .#packages.x86_64-linux.rootfsPartition      — rootfs only (SSH upgrade)"
    echo "    nix build .#packages.x86_64-linux.luckfox-kernel       — kernel + DTBs only"
    echo ""
    echo "  Flash SD card:"
    echo "    sudo dd if=result/sd-flashable.img of=/dev/sdX bs=4M status=progress"
    echo ""
    echo "  Upgrade over SSH (zero-downtime A/B):"
    echo "    SHA=\$(sha1sum result/rootfs.squashfs | awk '{print \$1}')"
    echo "    ssh root@luckfox upgrade --sha1 \"\$SHA\" < result/rootfs.squashfs"
    echo ""
    echo "  Serial console:"
    echo "    picocom -b 115200 /dev/ttyUSB0"
    echo ""
    echo "  QEMU A/B test (no hardware needed):"
    echo "    nix run .#packages.x86_64-linux.qemu-ab"
    echo ""
  '';
}
