{
  description = "Luckfox NixOS-style firmware system";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
  let
    lib = nixpkgs.lib;

    # Systems this flake produces outputs for.
    supportedSystems = [
      "aarch64-darwin"   # Apple Silicon Mac
      "x86_64-darwin"    # Intel Mac
      "x86_64-linux"     # Linux workstation / CI
      "aarch64-linux"    # Linux ARM (e.g. Raspberry Pi, Asahi)
    ];

    outputsFor = system:
    let
      # ── Linux builder for the QEMU kernel ──────────────────────────────────
      #
      # The Linux kernel cannot be compiled on macOS, so Darwin hosts delegate
      # to a Linux builder of matching architecture.  Linux hosts build natively.
      #
      #   aarch64-darwin → aarch64-linux  (nix-darwin Linux builder)
      #   x86_64-darwin  → x86_64-linux   (remote builder required)
      #   *-linux        → system itself   (native)
      linuxSystem =
        if   system == "aarch64-darwin" then "aarch64-linux"
        else if system == "x86_64-darwin"  then "x86_64-linux"
        else system;

      # ARM packages for the QEMU test kernel.
      # BUILD = linuxSystem.  TARGET = armv7l hard-float.
      # Use the LTS series — more likely to be in cache.nixos.org.
      linuxPkgs = import nixpkgs {
        system      = linuxSystem;
        crossSystem = lib.systems.examples.armv7l-hf-multiplatform;
      };

      qemuKernel = linuxPkgs.linuxPackages.kernel;

      # ── Host packages (no crossSystem) ─────────────────────────────────────
      hostPkgs = import nixpkgs { inherit system; };

      # ── Cross-compilation packages: build on host, target ARMv7 musl ───────
      pkgs = import nixpkgs {
        inherit system;
        crossSystem = { config = "armv7l-unknown-linux-musleabihf"; };
      };

      # ── Cross-compilation packages for Pine64 Ox64 (BL808 RV64 musl) ────────
      #
      # The BL808's Linux core is an RV64GCV (C906) @ 480 MHz.  We target
      # riscv64-unknown-linux-musl, the same musl-first strategy as ARMv7.
      #
      # NOTE: riscv64 packages in nixpkgs-unstable are less aggressively cached
      # than ARM.  Expect longer first-time build times on a cold Nix store.
      pkgsRv64 = import nixpkgs {
        inherit system;
        crossSystem = { config = "riscv64-unknown-linux-musl"; };
        overlays = [
          (final: prev: {
            # ── Tcl cross-compilation fix ───────────────────────────────────
            # When cross-compiling from macOS, Tcl's configure incorrectly
            # stamps -DMAC_OSX_TCL=1 into config.h and enables the macOS
            # compat/mkstemp.c shim.  That shim is missing #include <string.h>
            # (upstream bug), causing a hard build error on riscv64-musl:
            #   mkstemp.c: error: implicit declaration of function 'strlen'
            # Patch in the missing include so the build completes.
            tcl = prev.tcl.overrideAttrs (old: {
              postPatch = (old.postPatch or "") + ''
                sed -i 's|#include <unistd.h>|#include <unistd.h>\n#include <string.h>|' \
                  compat/mkstemp.c
              '';
            });
          })
        ];
      };

      mkSystem   = import ./lib/mkSystem.nix { inherit pkgs;    lib = pkgs.lib;    };
      mkSystemRv = import ./lib/mkSystem.nix { pkgs = pkgsRv64; lib = pkgsRv64.lib; };

      # ── System evaluations ──────────────────────────────────────────────────
      picoMiniB         = mkSystem   { configuration = ./configuration.nix;             };
      picoMiniB-qemu    = mkSystem   { configuration = ./configurations/qemu-test.nix;  };
      picoMiniB-vm      = mkSystem   { configuration = ./configurations/qemu-vm.nix;    };
      picoMiniB-sdimage = mkSystem   { configuration = ./configurations/sdimage.nix;    };
      picoMiniB-ab      = mkSystem   { configuration = ./configurations/sdimage-ab.nix; };

      # Pine64 Ox64 — RISC-V 64-bit (BL808 C906 core)
      # Build: nix build .#packages.<system>.ox64
      # See hardware/ox64.nix for kernel/dtb setup instructions.
      ox64 = mkSystemRv { configuration = ./configurations/ox64.nix; };

      # ── QEMU runner (initramfs) ──────────────────────────────────────────────
      qemu-test = hostPkgs.writeShellApplication {
        name = "qemu-test-luckfox";

        runtimeInputs = [ hostPkgs.qemu hostPkgs.python3 ];

        text = ''
          # Pick a free ephemeral port for SSH forwarding so we never
          # collide with whatever else is already running on the host.
          SSH_PORT=$(python3 -c \
            "import socket; s=socket.socket(); s.bind((\"\",0)); \
             print(s.getsockname()[1]); s.close()")

          echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
          echo "  Luckfox Pico Mini B — QEMU virt (ARMv7 Cortex-A7)"
          echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
          echo "  Serial console below (Ctrl-A X to exit QEMU)"
          echo "  SSH: ssh root@localhost -p $SSH_PORT"
          echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
          echo ""

          exec qemu-system-arm \
            -M virt \
            -cpu cortex-a7 \
            -m 512M \
            -kernel ${qemuKernel}/zImage \
            -initrd ${picoMiniB-qemu.config.system.build.initramfs} \
            -append "${picoMiniB-qemu.config.boot.cmdline}" \
            -nographic \
            -netdev "user,id=net0,hostfwd=tcp::''${SSH_PORT}-:22" \
            -device virtio-net-device,netdev=net0 \
            -device virtio-rng-device
        '';
      };

      # ── Importable QCOW2 disk image ─────────────────────────────────────────
      #
      # Builds an ext4 filesystem from the rootfs tree using mke2fs -d
      # (no mount required — works inside the Nix sandbox) then converts
      # to compressed QCOW2 for compact distribution.
      qemu-vm-disk = hostPkgs.runCommand "luckfox-vm.qcow2" {
        nativeBuildInputs = with hostPkgs; [ e2fsprogs qemu ];
      } ''
        echo "=== populating ext4 image from rootfs ==="
        # 512 MiB is generous for this rootfs; adjust if you add large packages.
        truncate -s 512M rootfs.img
        mkfs.ext4 -L rootfs \
          -d ${picoMiniB-vm.config.system.build.rootfs} \
          rootfs.img

        echo "=== converting to compressed QCOW2 ==="
        qemu-img convert -f raw -O qcow2 -c rootfs.img $out
        echo "=== done: $(du -sh $out | cut -f1) on disk ==="
      '';

      # ── Self-contained VM bundle ──────────────────────────────────────────────
      #
      # A directory containing:
      #   luckfox.qcow2  — the root disk (writable copy required — see run.sh)
      #   zImage         — the ARM kernel
      #   run.sh         — portable launch script (copies disk on first run)
      #
      # Usage:
      #   cp -r $(nix build .#qemu-vm-bundle --print-out-paths) ~/luckfox-vm
      #   chmod -R u+w ~/luckfox-vm        # make writable
      #   ~/luckfox-vm/run.sh
      #
      # Or just: nix run .#qemu-vm
      qemu-vm-bundle = hostPkgs.runCommand "luckfox-vm-bundle" {} ''
        mkdir -p $out
        cp ${qemu-vm-disk}       $out/luckfox.qcow2
        cp ${qemuKernel}/zImage  $out/zImage

        cat > $out/run.sh << 'RUNEOF'
#!/bin/sh
# Luckfox Pico Mini B — QEMU VM launcher
# Copy this whole directory somewhere writable before running.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
DISK="$DIR/luckfox.qcow2"
KERNEL="$DIR/zImage"
SSH_PORT="''${SSH_PORT:-2222}"

if [ ! -w "$DISK" ]; then
  echo "ERROR: $DISK is read-only." >&2
  echo "Copy the bundle directory to a writable location first:" >&2
  echo "  cp -rL <bundle-path> ~/luckfox-vm && chmod -R u+w ~/luckfox-vm" >&2
  exit 1
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Luckfox Pico Mini B — QEMU virt (ARMv7 / 512 MB)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Serial console below  (Ctrl-A X to quit QEMU)"
echo "  SSH: ssh root@localhost -p $SSH_PORT"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

exec qemu-system-arm \
  -M virt \
  -cpu cortex-a7 \
  -m 512M \
  -kernel "$KERNEL" \
  -append "console=ttyAMA0 root=/dev/vda rw init=/sbin/init panic=1" \
  -drive  "file=$DISK,format=qcow2,if=virtio" \
  -nographic \
  -netdev "user,id=net0,hostfwd=tcp::''${SSH_PORT}-:22" \
  -device virtio-net-device,netdev=net0 \
  -device virtio-rng-device
RUNEOF
        chmod +x $out/run.sh
      '';

      # ── QEMU VM app (uses ephemeral overlay so Nix store disk stays pristine) ─
      qemu-vm = hostPkgs.writeShellApplication {
        name = "qemu-vm-luckfox";
        runtimeInputs = with hostPkgs; [ qemu python3 ];
        text = ''
          SSH_PORT=$(python3 -c \
            "import socket; s=socket.socket(); s.bind((\"\",0)); \
             print(s.getsockname()[1]); s.close()")

          # The Nix store disk is read-only; layer a writable QCOW2 overlay.
          OVERLAY=$(mktemp /tmp/luckfox-vm.XXXXXX.qcow2)
          qemu-img create -f qcow2 \
            -b ${qemu-vm-disk} -F qcow2 "$OVERLAY" > /dev/null
          cleanup() { rm -f "$OVERLAY"; }
          trap cleanup EXIT

          echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
          echo "  Luckfox Pico Mini B — QEMU VM (ARMv7 / 512 MB)"
          echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
          echo "  Serial console below  (Ctrl-A X to quit)"
          echo "  SSH: ssh root@localhost -p $SSH_PORT"
          echo "  Disk changes are ephemeral (overlay deleted on exit)"
          echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

          exec qemu-system-arm \
            -M virt \
            -cpu cortex-a7 \
            -m 512M \
            -kernel ${qemuKernel}/zImage \
            -append "console=ttyAMA0 root=/dev/vda rw init=/sbin/init panic=1" \
            -drive  "file=$OVERLAY,format=qcow2,if=virtio" \
            -nographic \
            -netdev "user,id=net0,hostfwd=tcp::''${SSH_PORT}-:22" \
            -device virtio-net-device,netdev=net0 \
            -device virtio-rng-device
        '';
      };

      # ── QEMU runner (disk image + ephemeral QCOW2 overlay) ───────────────────
      #
      # Boots the rootfs.img as a virtio-blk device.  A temporary QCOW2 overlay
      # is created on top of the (read-only) Nix store image so any writes made
      # inside QEMU are captured in the overlay only.  The overlay is deleted
      # automatically when QEMU exits, giving a clean slate every run.
      #
      # Usage:  nix run .#qemu-overlay
      #         ssh root@localhost -p <printed port>
      qemu-overlay = hostPkgs.writeShellApplication {
        name = "qemu-overlay-luckfox";

        runtimeInputs = [ hostPkgs.qemu hostPkgs.qemu-utils hostPkgs.python3 ];

        text = ''
          ROOTFS="${picoMiniB.config.system.build.firmware}/rootfs.img"

          # Create a temporary QCOW2 overlay backed by the Nix-built rootfs.
          # The overlay starts at ~200 KB and only grows with actual writes.
          OVERLAY=$(mktemp /tmp/luckfox-overlay.XXXXXX.qcow2)
          qemu-img create -f qcow2 -b "$ROOTFS" -F raw "$OVERLAY"

          # Ensure the overlay is removed however the script exits.
          cleanup() { rm -f "$OVERLAY"; echo "Overlay removed."; }
          trap cleanup EXIT

          SSH_PORT=$(python3 -c \
            "import socket; s=socket.socket(); s.bind((\"\",0)); \
             print(s.getsockname()[1]); s.close()")

          echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
          echo "  Luckfox — QEMU virt, disk image + ephemeral overlay"
          echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
          echo "  Serial console below (Ctrl-A X to exit QEMU)"
          echo "  SSH:     ssh root@localhost -p $SSH_PORT"
          echo "  Overlay: $OVERLAY  (deleted on exit)"
          echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
          echo ""

          # Do NOT use 'exec' here — the shell must stay alive so the
          # EXIT trap fires after QEMU finishes and removes the overlay.
          qemu-system-arm \
            -M virt \
            -cpu cortex-a7 \
            -m 512M \
            -kernel ${qemuKernel}/zImage \
            -append "console=ttyAMA0 root=/dev/vda rw init=/sbin/init panic=1" \
            -drive file="$OVERLAY",format=qcow2,if=virtio \
            -nographic \
            -netdev "user,id=net0,hostfwd=tcp::''${SSH_PORT}-:22" \
            -device virtio-net-device,netdev=net0 \
            -device virtio-rng-device
        '';
      };

    in {
      packages = {
        # Real hardware outputs
        pico-mini-b       = picoMiniB.config.system.build.firmware;
        rootfs            = picoMiniB.config.system.build.rootfs;
        uboot             = picoMiniB.config.system.build.uboot;
        sdImage           = picoMiniB.config.system.build.image;
        sdImage-flashable = picoMiniB-sdimage.config.system.build.sdImage;

        # A/B rootfs outputs (zero-downtime SSH upgrades)
        # Flash sdImage-ab to a card, then use rootfsPartition for subsequent upgrades:
        #   nix build .#sdImage-ab && dd if=result/sd-flashable.img of=/dev/sdX bs=4M
        #   nix build .#rootfsPartition && ssh root@luckfox upgrade < result/rootfs.ext4
        sdImage-ab            = picoMiniB-ab.config.system.build.sdImage;
        rootfsPartition       = picoMiniB-ab.config.system.build.rootfsPartition;
        slotSelectInitramfs   = picoMiniB-ab.config.system.build.slotSelectInitramfs;

        # QEMU test outputs — Linux hosts only.
        # Building the ARM kernel requires a Linux build environment; Darwin
        # hosts need a configured nix-darwin Linux builder to use these.
        # On Darwin without a builder, omit them rather than failing the whole
        # flake evaluation.
      } // lib.optionalAttrs (lib.hasSuffix "-linux" system) {
        qemu-initramfs    = picoMiniB-qemu.config.system.build.initramfs;
        qemu-test         = qemu-test;
        qemu-overlay      = qemu-overlay;
        qemu-vm-disk      = qemu-vm-disk;
        qemu-vm-bundle    = qemu-vm-bundle;
        qemu-vm           = qemu-vm;

        # Pine64 Ox64 (BL808 RV64 musl) — see configurations/ox64.nix
        # Fill in BUILDROOT_SHA256 in pkgs/ox64-firmware.nix before building.
        ox64-firmware     = import ./pkgs/ox64-firmware.nix { pkgs = hostPkgs; };
        ox64-rootfs       = ox64.config.system.build.rootfs;
        ox64-image        = ox64.config.system.build.image;
        # Full 2-partition SD image (FAT32 boot + ext4 rootfs).
        # Flash directly: dd if=result/ox64-sdcard.img of=/dev/sdX bs=4M status=progress
        ox64-sd-image     = ox64.config.system.build.ox64SdImage;
      };

      apps = lib.optionalAttrs (lib.hasSuffix "-linux" system) {
        qemu-test = {
          type    = "app";
          program = "${qemu-test}/bin/qemu-test-luckfox";
        };
        qemu-overlay = {
          type    = "app";
          program = "${qemu-overlay}/bin/qemu-overlay-luckfox";
        };
        qemu-vm = {
          type    = "app";
          program = "${qemu-vm}/bin/qemu-vm-luckfox";
        };
      };

      defaultPackage = picoMiniB.config.system.build.firmware;

      devShells.default = hostPkgs.mkShell {
        buildInputs = [ hostPkgs.nixpkgs-fmt hostPkgs.qemu ];
      };
    };

    allOutputs = lib.genAttrs supportedSystems outputsFor;

  in {
    packages       = lib.mapAttrs (_: o: o.packages)       allOutputs;
    apps           = lib.mapAttrs (_: o: o.apps)           allOutputs;
    defaultPackage = lib.mapAttrs (_: o: o.defaultPackage) allOutputs;
    devShells      = lib.mapAttrs (_: o: o.devShells)      allOutputs;
  };
}
