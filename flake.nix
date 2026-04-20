{
  description = "Luckfox NixOS-style firmware system";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
  let
    system      = "x86_64-darwin";   # macOS host
    linuxSystem = "x86_64-linux";    # Linux builder (for kernel + image builds)

    # ── Package sets ─────────────────────────────────────────────────────────

    # Host packages: plain macOS packages, no crossSystem.
    # Used for the QEMU runner and other host-side tooling.
    hostPkgs = import nixpkgs { inherit system; };

    # Cross-compilation target: ARMv7 musl (Luckfox / RV1103).
    # Build-side derivations (runCommand etc.) execute on macOS.
    pkgs = import nixpkgs {
      inherit system;
      crossSystem = {
        config = "armv7l-unknown-linux-musleabihf";
      };
    };

    # ARM packages for the QEMU test kernel.
    # BUILD = x86_64-linux (requires a Linux builder or the NixOS cache).
    # TARGET = armv7l hard-float (glibc — fine for kernel; libc doesn't matter).
    linuxPkgs = import nixpkgs {
      system      = linuxSystem;
      crossSystem = nixpkgs.lib.systems.examples.armv7l-hf-multiplatform;
    };

    lib = pkgs.lib;

    mkSystem = import ./lib/mkSystem.nix { inherit pkgs lib; };

    # ── System definitions ───────────────────────────────────────────────────

    # Real hardware target (Luckfox Pico Mini B)
    picoMiniB = mkSystem {
      configuration = ./configuration.nix;
    };

    # QEMU test target (generic ARMv7 virt machine)
    picoMiniB-qemu = mkSystem {
      configuration = ./configurations/qemu-test.nix;
    };

    # Self-expanding flashable SD image
    picoMiniB-sdimage = mkSystem {
      configuration = ./configurations/sdimage.nix;
    };

    # ARM kernel for QEMU (fetched from the NixOS binary cache or Linux builder)
    qemuKernel = linuxPkgs.linuxPackages_latest.kernel;

    # QEMU runner script (executes on macOS)
    qemu-test = hostPkgs.writeShellApplication {
      name = "qemu-test-luckfox";

      runtimeInputs = [ hostPkgs.qemu ];

      text = ''
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  Luckfox Pico Mini B — QEMU virt (ARMv7 Cortex-A7)"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  Serial console below (Ctrl-A X to exit QEMU)"
        echo "  SSH: ssh root@localhost -p 2222"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""

        exec qemu-system-arm \
          -M virt \
          -cpu cortex-a7 \
          -m 256M \
          -kernel ${qemuKernel}/zImage \
          -initrd ${picoMiniB-qemu.config.system.build.initramfs} \
          -append "${picoMiniB-qemu.config.boot.cmdline}" \
          -nographic \
          -netdev user,id=net0,hostfwd=tcp::2222-:22 \
          -device virtio-net-device,netdev=net0 \
          -device virtio-rng-device
      '';
    };

  in {

    ########################################
    # Real hardware outputs
    ########################################
    packages.${system}.pico-mini-b =
      picoMiniB.config.system.build.firmware;

    packages.${system}.rootfs =
      picoMiniB.config.system.build.rootfs;

    packages.${system}.uboot =
      picoMiniB.config.system.build.uboot;

    # Legacy SD image (Linux-only, uses losetup/mount)
    packages.${system}.sdImage =
      picoMiniB.config.system.build.image;

    # Flashable self-expanding SD image (macOS-compatible build)
    packages.${system}.sdImage-flashable =
      picoMiniB-sdimage.config.system.build.sdImage;

    ########################################
    # QEMU test outputs
    ########################################

    # The initramfs alone (useful for inspection)
    packages.${system}.qemu-initramfs =
      picoMiniB-qemu.config.system.build.initramfs;

    # The QEMU runner script
    packages.${system}.qemu-test = qemu-test;

    # `nix run .#qemu-test` convenience
    apps.${system}.qemu-test = {
      type    = "app";
      program = "${qemu-test}/bin/qemu-test-luckfox";
    };

    ########################################
    # Defaults
    ########################################
    defaultPackage.${system} =
      picoMiniB.config.system.build.firmware;

    ########################################
    # Dev shell
    ########################################
    devShells.${system}.default = hostPkgs.mkShell {
      buildInputs = [
        hostPkgs.nixpkgs-fmt
        hostPkgs.qemu
      ];
    };
  };
}
