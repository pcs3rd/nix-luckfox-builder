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

      # Override the QEMU ARM kernel for the squashfs + overlayfs A/B scheme.
      #
      # Adds CONFIG_OVERLAY_FS (absent from the default armv7l defconfig) and
      # strips drivers/subsystems that a QEMU virt machine never uses, reducing
      # build time and the kernel image size.
      #
      # What this machine needs:
      #   - ARM virt platform + PL011 UART (ttyAMA0)
      #   - virtio-blk (/dev/vda), virtio-net (eth0), virtio-rng
      #   - ext4 (boot + persist), squashfs + lz4 (slots), overlayfs, tmpfs
      #   - TCP/IP stack for SSH (dropbear uses ChaCha20 + Ed25519)
      qemuKernel = (linuxPkgs.linuxPackages.extend (self: super: {
        kernel = super.kernel.override {
          structuredExtraConfig = with lib.kernel; {
            # ── Required additions ──────────────────────────────────────────
            OVERLAY_FS      = yes;   # overlayfs for writable rootfs layer
            SQUASHFS_LZ4    = yes;   # lz4 decompression for slot partitions

            # ── Subsystems never present on QEMU virt ───────────────────────
            # All disabled with mkForce so common-config.nix can't override us.
            # USB: QEMU virt has no USB controller (gadget disabled in config)
            USB_SUPPORT     = lib.mkForce no;
            USB             = lib.mkForce no;
            # Sound: no audio device or need
            SOUND           = lib.mkForce no;
            SND             = lib.mkForce no;
            # Bluetooth: no BT hardware
            BT              = lib.mkForce no;
            # Wireless / WLAN: virtio-net covers networking
            WIRELESS        = lib.mkForce no;
            WLAN            = lib.mkForce no;
            # Framebuffer / DRM: serial console only (ttyAMA0), no display
            FB              = lib.mkForce no;
            DRM             = lib.mkForce no;
            VGA_CONSOLE     = lib.mkForce no;
            # PCMCIA / CardBus: not present on virt machine
            PCCARD          = lib.mkForce no;
            # InfiniBand: not needed
            INFINIBAND      = lib.mkForce no;
            # Industrial I/O: no sensors
            IIO             = lib.mkForce no;

            # ── Unneeded filesystems ────────────────────────────────────────
            # Keep: ext4, squashfs, overlayfs, tmpfs, proc, sysfs, devtmpfs
            BTRFS_FS        = lib.mkForce no;
            XFS_FS          = lib.mkForce no;
            JFS_FS          = lib.mkForce no;
            REISERFS_FS     = lib.mkForce no;
            OCFS2_FS        = lib.mkForce no;
            GFS2_FS         = lib.mkForce no;
            NFS_FS          = lib.mkForce no;
            NFSD            = lib.mkForce no;
            CIFS            = lib.mkForce no;
            CEPH_FS         = lib.mkForce no;
            FUSE_FS         = lib.mkForce no;   # remove if you need FUSE tools
            NTFS_FS         = lib.mkForce no;

            # ── virtio-rng: built-in so the RNG has entropy before any modules ──
            # If this is =m (modular), the virtio-rng device exists but the
            # driver isn't loaded in early init.  Some crypto subsystems block
            # waiting for the RNG to be seeded.  Force =y to avoid the stall.
            HW_RANDOM_VIRTIO = yes;

            # ── MMC / SDIO: not present on QEMU virt (disk is virtio-blk) ──────
            # The multi-platform nixpkgs kernel enables MMC by default.
            # mmc_rescan probes for controllers that don't exist in QEMU virt,
            # times out, and can retry many times — each timeout ~100ms on
            # native hardware becomes ~90 seconds in TCG emulation.
            MMC             = lib.mkForce no;

            # ── PCI: not used — all QEMU virtio devices are virtio-mmio ─────────
            # QEMU -M virt exposes a PCIe root complex in the device tree.
            # The kernel scans all PCI bus/device/function slots looking for
            # devices — thousands of MMIO reads in TCG, each one taking orders
            # of magnitude longer than on real hardware.
            # Our virtio-blk, virtio-net, and virtio-rng are -device virtio-*-device
            # (mmio transport), not -device virtio-*-pci.  PCI is entirely unused.
            PCI             = lib.mkForce no;

            # ── Crypto subsystem self-tests ─────────────────────────────────
            # Every registered cipher/hash/AEAD algorithm runs a test suite
            # during do_initcalls().  With dozens of algorithms registered in
            # the multi-platform config, this adds many seconds of real-hardware
            # time — multiplied by TCG slowdown into many minutes.
            CRYPTO_MANAGER_DISABLE_TESTS = yes;

            # ── Kernel debug / tracing overhead ────────────────────────────
            FTRACE          = lib.mkForce no;
            KPROBES         = lib.mkForce no;
            PERF_EVENTS     = lib.mkForce no;
          };
        };
      })).kernel;

      # ── Host packages (no crossSystem) ─────────────────────────────────────
      hostPkgs = import nixpkgs { inherit system; };

      # ── Cross-compilation packages: build on host, target ARMv7 musl ───────
      pkgs = import nixpkgs {
        inherit system;
        crossSystem = { config = "armv7l-unknown-linux-musleabihf"; };
      };

      mkSystem   = import ./lib/mkSystem.nix {
        inherit pkgs;
        lib      = pkgs.lib;
        # Format self.lastModifiedDate (YYYYMMDDHHmmss) → YYYY-MM-DD.
        # Falls back to "unknown" for dirty trees where lastModifiedDate is absent.
        buildDate =
          let d = self.lastModifiedDate or "00000000000000";
          in "${builtins.substring 0 4 d}-${builtins.substring 4 2 d}-${builtins.substring 6 2 d}";
      };

      # ── System evaluations ──────────────────────────────────────────────────
      picoMiniB         = mkSystem   { configuration = ./configuration.nix;             };
      picoMiniB-qemu    = mkSystem   { configuration = ./configurations/qemu-test.nix;  };
      # ── QEMU A/B system evaluation ─────────────────────────────────────────
      #
      # Uses the same sdimage.nix SD image builder as real hardware — the only
      # QEMU-specific differences are:
      #   • device.kernel → qemuKernel (ARM cross-compiled Linux from nixpkgs)
      #   • boot.uboot.enable = false  (U-Boot is provided via -bios, not embedded)
      #   • rockchip.enable  = false   (no Rockchip SPL/idbloader blobs)
      #
      # sdimage.nix generates boot.scr (U-Boot distro boot script) in partition 1.
      # U-Boot reads the raw slot indicator byte from sector 1, sets root=LABEL=…,
      # and loads the kernel from partition 1 — no initramfs needed for slot select.
      picoMiniB-qemu-ab = mkSystem {
        configuration = [
          ./configurations/qemu-ab.nix
          {
            # Supply the QEMU ARM kernel so sdimage.nix copies it into partition 1.
            device.kernel = "${qemuKernel}/zImage";
          }
        ];
      };
      picoMiniB-vm      = mkSystem   { configuration = ./configurations/qemu-vm.nix;    };
      # Unified SD image: A/B squashfs layout when system.abRootfs.enable = true
      # (the default in configuration.nix), single ext4 partition otherwise.
      # The partition layout is determined entirely inside configurations/sdimage.nix
      # and modules/core/sdimage.nix — no separate -ab configuration needed.
      picoMiniB-sdimage = mkSystem   { configuration = ./configurations/sdimage.nix;    };

      # ── SPI NOR image ──────────────────────────────────────────────────────────
      #
      # 8 MiB blank image with the SPL written at offset 0x8000 (the Rockchip
      # boot ROM always reads from this offset on SPI NOR).  Flash this to the
      # onboard SPI flash so the board boots from SD card without holding BOOT.
      spiImage =
        let uboot = picoMiniB.config.system.build.uboot;
        in hostPkgs.runCommand "luckfox-spi.img" {} ''
          mkdir -p $out
          # 8 MiB blank image (matches the onboard Winbond W25Q64 / similar)
          dd if=/dev/zero of=$out/spi.img bs=1M count=8 2>/dev/null
          # SPL at byte offset 0x8000 (sector 64 × 512 B — same as SD card)
          dd if=${uboot}/SPL of=$out/spi.img \
            bs=1 seek=$((0x8000)) conv=notrunc 2>/dev/null
          echo "SPI image: $(du -sh $out/spi.img | cut -f1)"
          echo "SPL size:  $(du -sh ${uboot}/SPL  | cut -f1)"
        '';

      # ── Flash bundle ────────────────────────────────────────────────────────────
      #
      # Collects everything needed to flash the board into one output directory:
      #
      #   rv1106_miniloader.bin — Rockchip USB download loader for `rkdeveloptool db`
      #                           (initialises DRAM over USB; never written to storage)
      #   SPL                   — U-Boot idbloader written into spi.img and sd-flashable.img
      #                           (NOT for rkdeveloptool db — different format)
      #   spi.img               — 8 MiB SPI NOR image for `rkdeveloptool wf`
      #   sd-flashable.img      — full SD card image for `dd`
      #
      # Usage:
      #   nix build .#flash-bundle
      #   # Flash SPI NOR (maskrom mode — hold BOOT, plug USB):
      #   rkdeveloptool db result/rv1106_miniloader.bin
      #   rkdeveloptool ef
      #   rkdeveloptool wf result/spi.img
      #   rkdeveloptool rd
      #   # Flash SD card:
      #   sudo dd if=result/sd-flashable.img of=/dev/sdX bs=4M status=progress
      flashBundle = hostPkgs.runCommand "luckfox-flash-bundle" {} ''
        mkdir -p $out
        cp ${picoMiniB.config.system.build.uboot}/SPL              $out/SPL
        cp ${picoMiniB.config.system.build.uboot}/rv1106_miniloader.bin \
                                                                   $out/rv1106_miniloader.bin
        cp ${spiImage}/spi.img                                     $out/spi.img
        cp ${picoMiniB-sdimage.config.system.build.sdImage}/sd-flashable.img \
                                                                   $out/sd-flashable.img
      '';

      # ── QEMU test disk (read-only ext4 image of the rootfs) ─────────────────
      qemu-test-disk = hostPkgs.runCommand "luckfox-test.img" {
        nativeBuildInputs = [ hostPkgs.e2fsprogs ];
      } ''
        truncate -s 512M $out
        mkfs.ext4 \
          -d ${picoMiniB-qemu.config.system.build.rootfs} \
          -L rootfs \
          -E lazy_itable_init=0,lazy_journal_init=0 \
          $out
      '';

      # ── QEMU runner (read-only virtio-blk disk) ──────────────────────────────
      #
      # The rootfs is served as a raw ext4 image on a read-only virtio-blk
      # device (/dev/vda).  No initramfs — the kernel mounts the disk directly.
      # This is closer to real hardware (eMMC/SD read-only rootfs) than the old
      # initramfs approach, and exercises the virtio-blk path explicitly.
      qemu-test = hostPkgs.writeShellApplication {
        name = "qemu-test-luckfox";

        runtimeInputs = [ hostPkgs.qemu hostPkgs.python3 ];

        text = ''
          SSH_PORT=$(python3 -c \
            "import socket; s=socket.socket(); s.bind((\"\",0)); \
             print(s.getsockname()[1]); s.close()")

          echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
          echo "  Luckfox Pico Mini B — QEMU virt (ARMv7 Cortex-A7)"
          echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
          echo "  Serial console below (Ctrl-A X to exit QEMU)"
          echo "  SSH: ssh root@localhost -p ''${SSH_PORT}"
          echo "  Rootfs: read-only virtio-blk (/dev/vda)"
          echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

          exec qemu-system-arm \
            -M virt \
            -cpu cortex-a7 \
            -smp 1 \
            -m 64M \
            -kernel ${qemuKernel}/zImage \
            -append "${picoMiniB-qemu.config.boot.cmdline}" \
            -drive "file=${qemu-test-disk},format=raw,if=virtio,readonly=on" \
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
echo "  Luckfox Pico Mini B — QEMU virt (ARMv7 / 64 MB)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Serial console below  (Ctrl-A X to quit QEMU)"
echo "  SSH: ssh root@localhost -p $SSH_PORT"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

exec qemu-system-arm \
  -M virt \
  -cpu cortex-a7 \
  -smp 1 \
  -m 64M \
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
          echo "  Luckfox Pico Mini B — QEMU VM (ARMv7 / 64 MB)"
          echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
          echo "  Serial console below  (Ctrl-A X to quit)"
          echo "  SSH: ssh root@localhost -p $SSH_PORT"
          echo "  Disk changes are ephemeral (overlay deleted on exit)"
          echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

          exec qemu-system-arm \
            -M virt \
            -cpu cortex-a7 \
            -smp 1 \
            -m 64M \
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
            -smp 1 \
            -m 64M \
            -kernel ${qemuKernel}/zImage \
            -append "console=ttyAMA0 root=/dev/vda rw init=/sbin/init panic=1" \
            -drive file="$OVERLAY",format=qcow2,if=virtio \
            -nographic \
            -netdev "user,id=net0,hostfwd=tcp::''${SSH_PORT}-:22" \
            -device virtio-net-device,netdev=net0 \
            -device virtio-rng-device
        '';
      };

      # ── QEMU A/B disk image ─────────────────────────────────────────────────
      #
      # The unified SD image built by sdimage.nix — same builder as real hardware.
      # 4-partition layout:
      #   p1: ext4 "boot"    — kernel + initramfs + boot.scr
      #   p2: squashfs       — slot A rootfs (read-only)
      #   p3: squashfs       — slot B rootfs (read-only)
      #   p4: ext4 "persist" — overlayfs upper/work dirs
      #
      # U-Boot (via -bios) loads boot.scr from p1, which loads kernel + initramfs.
      # The initramfs reads the slot indicator byte, mounts the active squashfs slot,
      # and sets up overlayfs on the persist partition before switch_root.
      qemu-ab-disk = picoMiniB-qemu-ab.config.system.build.sdImage;

      # Standalone squashfs image for the upgrade workflow — same derivation as the
      # real-hardware rootfsPartition so QEMU tests validate the production image.
      #   nix build .#qemu-ab-rootfs
      #   ssh root@localhost -p <port> upgrade < result/rootfs.squashfs
      qemu-ab-rootfs = picoMiniB-sdimage.config.system.build.rootfsPartition;

      # ── QEMU A/B launcher (U-Boot firmware) ─────────────────────────────────
      #
      # U-Boot initializes, scans the virtio disk, finds boot.scr in partition 1
      # (ext4 "boot"), and loads the kernel + slot-select initramfs.  The initramfs
      # reads the raw slot indicator byte (sector 1), mounts the active squashfs
      # slot (p2 or p3) via overlayfs on the persist partition (p4), then
      # switch_root's into the overlay.
      #
      # /bin/upgrade and /bin/slot in the rootfs manage slot switching by writing
      # to the raw disk byte, exactly as on real hardware.
      qemu-ab = hostPkgs.writeShellApplication {
        name = "qemu-ab-luckfox";
        runtimeInputs = with hostPkgs; [ qemu python3 ];
        text = ''
          SSH_PORT=$(python3 -c \
            "import socket; s=socket.socket(); s.bind((\"\",0)); \
             print(s.getsockname()[1]); s.close()")

          # Persistent overlay — survives across QEMU runs so slot changes and
          # rootfs upgrades accumulate.  Pass --reset to start fresh from slot A.
          OVERLAY="$HOME/.cache/luckfox-ab.qcow2"
          mkdir -p "$(dirname "$OVERLAY")"

          if [ "''${1:-}" = "--reset" ] || [ ! -f "$OVERLAY" ]; then
            echo "qemu-ab: (re)creating overlay at $OVERLAY"
            qemu-img create -f qcow2 \
              -b ${qemu-ab-disk}/sd-flashable.img \
              -F raw "$OVERLAY" > /dev/null
          else
            echo "qemu-ab: reusing existing overlay at $OVERLAY"
            echo "         (pass --reset to start fresh from slot A)"
          fi

          echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
          echo "  Luckfox Pico Mini B — QEMU A/B rootfs test (ARMv7 / 128 MB)"
          echo "  Boot: U-Boot (-bios) → boot.scr → slot indicator → root=LABEL=…"
          echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
          echo "  Serial console below  (Ctrl-A X to quit QEMU)"
          echo "  SSH: ssh root@localhost -p ''${SSH_PORT}"
          echo ""
          echo "  Test A/B upgrade:"
          echo "    nix build .#qemu-ab-rootfs"
          echo "    ssh root@localhost -p ''${SSH_PORT} upgrade < result/rootfs.squashfs"
          echo ""
          echo "  Slot changes and upgrades persist in: $OVERLAY"
          echo "  Run with --reset to wipe the overlay and start from slot A"
          echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

          qemu-system-arm \
            -M virt \
            -cpu cortex-a7 \
            -smp 1 \
            -m 128M \
            -bios ${hostPkgs.pkgsCross.armv7l-hf-multiplatform.ubootQemuArm}/u-boot.bin \
            -drive "file=$OVERLAY,format=qcow2,if=virtio" \
            -nographic \
            -netdev "user,id=net0,hostfwd=tcp::''${SSH_PORT}-:22" \
            -device virtio-net-device,netdev=net0 \
            -object rng-random,id=rng0,filename=/dev/urandom \
            -device virtio-rng-device,rng=rng0
        '';
      };

      # ── QEMU A/B launcher with KVM acceleration ──────────────────────────────
      #
      # Identical to qemu-ab but adds -enable-kvm for hardware-accelerated
      # emulation on Linux hosts with KVM support (/dev/kvm must be accessible).
      # Boot time drops from minutes (TCG) to a few seconds (KVM).
      #
      # KVM requires:
      #   - Linux host with the kvm_intel or kvm_amd kernel module loaded
      #   - User in the 'kvm' group (or /dev/kvm accessible)
      #   - NOT available on macOS / Windows / inside most VMs
      #
      # Usage:  nix run .#qemu-ab-kvm
      #         nix run .#qemu-ab-kvm -- --reset
      qemu-ab-kvm = hostPkgs.writeShellApplication {
        name = "qemu-ab-kvm-luckfox";
        runtimeInputs = with hostPkgs; [ qemu python3 ];
        text = ''
          # KVM can only accelerate guests whose ISA matches the host.
          # qemu-system-arm + -enable-kvm requires an ARM or AArch64 host;
          # on x86_64, /dev/kvm exists but accelerates only x86 guests.
          HOST_ARCH=$(uname -m)
          case "$HOST_ARCH" in
            aarch64|armv7l|armv8l) : ;;   # ARM host — KVM can accelerate ARM guests
            *)
              echo "qemu-ab-kvm: KVM cannot accelerate ARM guests on a $HOST_ARCH host." >&2
              echo "  KVM is ISA-specific: only ARM/AArch64 hosts can KVM-accelerate ARM VMs." >&2
              echo "  Use software emulation instead:  nix run .#qemu-ab" >&2
              exit 1
              ;;
          esac

          if [ ! -e /dev/kvm ]; then
            echo "qemu-ab-kvm: /dev/kvm not found." >&2
            echo "  Load kvm or kvm_host and ensure your user is in the kvm group." >&2
            exit 1
          fi

          SSH_PORT=$(python3 -c \
            "import socket; s=socket.socket(); s.bind((\"\",0)); \
             print(s.getsockname()[1]); s.close()")

          # Shares the same persistent overlay as qemu-ab so slot state is
          # preserved regardless of which runner you use.
          OVERLAY="$HOME/.cache/luckfox-ab.qcow2"
          mkdir -p "$(dirname "$OVERLAY")"

          if [ "''${1:-}" = "--reset" ] || [ ! -f "$OVERLAY" ]; then
            echo "qemu-ab-kvm: (re)creating overlay at $OVERLAY"
            qemu-img create -f qcow2 \
              -b ${qemu-ab-disk}/sd-flashable.img \
              -F raw "$OVERLAY" > /dev/null
          else
            echo "qemu-ab-kvm: reusing existing overlay at $OVERLAY"
            echo "             (pass --reset to start fresh from slot A)"
          fi

          echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
          echo "  Luckfox Pico Mini B — QEMU A/B + KVM (ARMv7 / 128 MB)"
          echo "  Boot: U-Boot (-bios) → boot.scr → slot indicator → overlayfs"
          echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
          echo "  Serial console below  (Ctrl-A X to quit QEMU)"
          echo "  SSH: ssh root@localhost -p ''${SSH_PORT}"
          echo ""
          echo "  Test A/B upgrade:"
          echo "    nix build .#qemu-ab-rootfs"
          echo "    ssh root@localhost -p ''${SSH_PORT} upgrade < result/rootfs.squashfs"
          echo ""
          echo "  Slot changes and upgrades persist in: $OVERLAY"
          echo "  Run with --reset to wipe the overlay and start from slot A"
          echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

          qemu-system-arm \
            -M virt \
            -cpu cortex-a7 \
            -enable-kvm \
            -smp 1 \
            -m 128M \
            -bios ${hostPkgs.pkgsCross.armv7l-hf-multiplatform.ubootQemuArm}/u-boot.bin \
            -drive "file=$OVERLAY,format=qcow2,if=virtio" \
            -nographic \
            -netdev "user,id=net0,hostfwd=tcp::''${SSH_PORT}-:22" \
            -device virtio-net-device,netdev=net0 \
            -object rng-random,id=rng0,filename=/dev/urandom \
            -device virtio-rng-device,rng=rng0
        '';
      };

    in {
      packages = {
        # Real hardware outputs
        pico-mini-b       = picoMiniB.config.system.build.firmware;
        rootfs            = picoMiniB.config.system.build.rootfs;
        uboot             = picoMiniB.config.system.build.uboot;

        # Raw 8 MiB SPI NOR image — flash to the onboard SPI flash so the board
        # boots from SD card without holding BOOT.  See flash-bundle for a single
        # target that collects SPL + spi.img + sd-flashable.img together.
        spi-image    = spiImage;

        # Everything needed to flash the board in one output directory:
        #   rv1106_miniloader.bin — Rockchip USB loader for `rkdeveloptool db`
        #   spi.img               — SPI NOR image for `rkdeveloptool wf`
        #   sd-flashable.img      — full SD card image for `dd`
        #   SPL                   — U-Boot idbloader (embedded in the above; for reference)
        flash-bundle = flashBundle;
        # Kernel built from SDK source (zImage + DTBs + modules).
        # Inspect result/dtbs/ to find the correct DTB name for hardware/pico-mini-b.nix.
        luckfox-kernel    = import ./pkgs/luckfox-kernel.nix { inherit pkgs; };
        sdImage           = picoMiniB.config.system.build.image;

        # Full flashable SD card image — partition layout determined by
        # system.abRootfs.enable (set in configuration.nix):
        #
        #   true  → 4-partition A/B squashfs layout (default)
        #   false → single ext4 partition
        #
        # Flash:   dd if=result/sd-flashable.img of=/dev/sdX bs=4M status=progress
        # Upgrade: nix build .#rootfsPartition
        #          ssh root@luckfox upgrade < result/rootfs.squashfs
        sdImage-flashable     = picoMiniB-sdimage.config.system.build.sdImage;
        rootfsPartition       = picoMiniB-sdimage.config.system.build.rootfsPartition;
        slotSelectInitramfs   = picoMiniB-sdimage.config.system.build.slotSelectInitramfs;

        # QEMU test outputs — Linux hosts only.
        # Building the ARM kernel requires a Linux build environment; Darwin
        # hosts need a configured nix-darwin Linux builder to use these.
        # On Darwin without a builder, omit them rather than failing the whole
        # flake evaluation.
      } // lib.optionalAttrs (lib.hasSuffix "-linux" system) {
        qemu-test-disk    = qemu-test-disk;
        qemu-test         = qemu-test;
        qemu-overlay      = qemu-overlay;
        qemu-vm-disk      = qemu-vm-disk;
        qemu-vm-bundle    = qemu-vm-bundle;
        qemu-vm           = qemu-vm;

        # A/B rootfs QEMU test — squashfs + overlayfs boot path in a VM.
        # nix run .#qemu-ab                     — launch the VM (TCG, works everywhere)
        # nix run .#qemu-ab-kvm                 — KVM-accelerated (Linux + /dev/kvm only)
        # nix build .#qemu-ab-disk              — the raw A/B disk image
        # nix build .#qemu-ab-rootfs            — standalone squashfs for upgrade testing
        qemu-ab           = qemu-ab;
        qemu-ab-kvm       = qemu-ab-kvm;
        qemu-ab-disk      = qemu-ab-disk;
        qemu-ab-rootfs    = qemu-ab-rootfs;
      };

      apps = lib.optionalAttrs (lib.hasSuffix "-linux" system) {
        qemu-test = {
          type    = "app";
          program = "${qemu-test}/bin/qemu-test-luckfox";
          meta.description = "Run the Luckfox rootfs in QEMU (read-only virtio-blk disk)";
        };
        qemu-overlay = {
          type    = "app";
          program = "${qemu-overlay}/bin/qemu-overlay-luckfox";
          meta.description = "Run the Luckfox rootfs in QEMU with an ephemeral QCOW2 overlay";
        };
        qemu-vm = {
          type    = "app";
          program = "${qemu-vm}/bin/qemu-vm-luckfox";
          meta.description = "Run the Luckfox rootfs as a persistent QEMU VM";
        };
        qemu-ab = {
          type    = "app";
          program = "${qemu-ab}/bin/qemu-ab-luckfox";
          meta.description = "Run the A/B squashfs rootfs in QEMU via U-Boot (TCG, all hosts)";
        };
        qemu-ab-kvm = {
          type    = "app";
          program = "${qemu-ab-kvm}/bin/qemu-ab-kvm-luckfox";
          meta.description = "Run the A/B squashfs rootfs in QEMU via U-Boot with KVM acceleration (Linux ARM hosts only)";
        };
      };

      devShells.default = hostPkgs.mkShell {
        buildInputs = [ hostPkgs.nixpkgs-fmt hostPkgs.qemu ];
      };

      # packages.default replaces the deprecated defaultPackage output.
      # Set inside outputsFor so the per-system packages attrset is complete.
      packages-default = picoMiniB.config.system.build.firmware;
    };

    allOutputs = lib.genAttrs supportedSystems outputsFor;

  in {
    packages  = lib.mapAttrs (_: o: o.packages // { default = o.packages-default; }) allOutputs;
    apps      = lib.mapAttrs (_: o: o.apps)      allOutputs;
    devShells = lib.mapAttrs (_: o: o.devShells) allOutputs;

    # checks.<system>.* derivations are BUILT (not just evaluated) by `nix flake check`.
    # Alias the packages that matter most so CI / nix flake check always validates them.
    # Linux-only: the kernel and SD image require a Linux build host.
    checks = lib.mapAttrs (system: o:
      lib.optionalAttrs (lib.hasSuffix "-linux" system) {
        rootfs            = o.packages.rootfs;
        sdImage-flashable = o.packages.sdImage-flashable;
      }
    ) allOutputs;
  };
}
