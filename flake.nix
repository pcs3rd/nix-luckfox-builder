{
  description = "Luckfox NixOS-style firmware system";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
  let
    lib = nixpkgs.lib;

    # Systems this flake produces outputs for.
    # Cross-compilation to ARMv7 musl works from both Intel and Apple Silicon Macs.
    darwinSystems = [ "aarch64-darwin" "x86_64-darwin" ];

    # Linux builder used for the QEMU kernel and any Linux-only derivations.
    linuxSystem = "x86_64-linux";

    # ARM packages for the QEMU test kernel.
    # BUILD = x86_64-linux (resolved from the NixOS binary cache or a Linux builder).
    # TARGET = armv7l hard-float (glibc is fine for the kernel).
    linuxPkgs = import nixpkgs {
      system      = linuxSystem;
      crossSystem = lib.systems.examples.armv7l-hf-multiplatform;
    };

    qemuKernel = linuxPkgs.linuxPackages_latest.kernel;

    # Build all per-system outputs for a given host system string.
    outputsFor = system:
    let
      # Host packages — plain macOS, no crossSystem.
      hostPkgs = import nixpkgs { inherit system; };

      # Cross-compilation packages: build on macOS, target ARMv7 musl.
      pkgs = import nixpkgs {
        inherit system;
        crossSystem = { config = "armv7l-unknown-linux-musleabihf"; };
      };

      mkSystem = import ./lib/mkSystem.nix { inherit pkgs; lib = pkgs.lib; };

      # ── System evaluations ─────────────────────────────────────────────────
      picoMiniB        = mkSystem { configuration = ./configuration.nix; };
      picoMiniB-qemu   = mkSystem { configuration = ./configurations/qemu-test.nix; };
      picoMiniB-sdimage = mkSystem { configuration = ./configurations/sdimage.nix; };

      # ── QEMU runner ────────────────────────────────────────────────────────
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
      packages = {
        ##################################
        # Real hardware outputs
        ##################################
        pico-mini-b       = picoMiniB.config.system.build.firmware;
        rootfs            = picoMiniB.config.system.build.rootfs;
        uboot             = picoMiniB.config.system.build.uboot;

        # Legacy SD image (Linux-only; requires losetup/mount via Linux builder)
        sdImage           = picoMiniB.config.system.build.image;

        # Flashable self-expanding SD image (macOS-compatible)
        sdImage-flashable = picoMiniB-sdimage.config.system.build.sdImage;

        ##################################
        # QEMU test outputs
        ##################################
        qemu-initramfs    = picoMiniB-qemu.config.system.build.initramfs;
        qemu-test         = qemu-test;
      };

      apps = {
        qemu-test = {
          type    = "app";
          program = "${qemu-test}/bin/qemu-test-luckfox";
        };
      };

      defaultPackage = picoMiniB.config.system.build.firmware;

      devShells.default = hostPkgs.mkShell {
        buildInputs = [
          hostPkgs.nixpkgs-fmt
          hostPkgs.qemu
        ];
      };
    };

    # Merge per-system outputs into the flake output attrsets.
    allOutputs = lib.genAttrs darwinSystems outputsFor;

  in {
    packages     = lib.mapAttrs (_: o: o.packages)     allOutputs;
    apps         = lib.mapAttrs (_: o: o.apps)         allOutputs;
    defaultPackage = lib.mapAttrs (_: o: o.defaultPackage) allOutputs;
    devShells    = lib.mapAttrs (_: o: o.devShells)    allOutputs;
  };
}
