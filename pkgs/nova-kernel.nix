# Linux kernel for the Luckfox Nova (Rockchip RK3308B, Cortex-A35 / AArch64).
#
# RK3308 is well-supported in mainline Linux since kernel 5.2.  We use the
# latest LTS series here.  The generic arm64 defconfig enables the drivers
# needed for RK3308: Cortex-A35 SMP, eMMC/SDIO, Ethernet, I2S, SPI, I2C, GPIO.
#
# ── DTB ───────────────────────────────────────────────────────────────────────
#
# As of kernel 6.6, the Luckfox Nova does not have an upstream DTS file.
# nova-kernel.nix ships a minimal out-of-tree DTS that describes the essentials:
# UART2 console (1500000 baud), eMMC on SDMMC0, Ethernet via MAC + PHY.
#
# TODO: upstream a proper DTS for the Luckfox Nova to the kernel.
#
# ── Hash placeholders ─────────────────────────────────────────────────────────
#
# The sha256 for the kernel tarball is left as lib.fakeHash.
# Fill it in by running:
#   nix-prefetch-url https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.6.30.tar.xz
#
# ─────────────────────────────────────────────────────────────────────────────

{ pkgs }:

let
  lib = pkgs.lib;

  LINUX_VERSION = "6.6.30";

  crossCompile = "${pkgs.stdenv.cc}/bin/${pkgs.stdenv.cc.targetPrefix}";
  hostCC       = "${pkgs.buildPackages.stdenv.cc}/bin/cc";

  # Minimal out-of-tree DTS for the Luckfox Nova.
  # Covers: UART2 console, eMMC (mmc@ff480000), Ethernet (gmac@ff4e0000).
  # Expand with I2C, SPI, I2S, GPIO as needed.
  novaDts = pkgs.writeText "rk3308-luckfox-nova.dts" ''
    // SPDX-License-Identifier: (GPL-2.0+ OR MIT)
    /dts-v1/;
    #include "rk3308.dtsi"

    / {
      model = "Luckfox Nova";
      compatible = "luckfox,nova", "rockchip,rk3308";

      aliases {
        serial2 = &uart2;
        mmc0    = &emmc;
      };

      chosen {
        stdout-path = "serial2:1500000n8";
      };

      memory@0 {
        device_type = "memory";
        /* 512 MiB — adjust if your Nova variant differs */
        reg = <0x0 0x00000000 0x0 0x20000000>;
      };
    };

    &uart2 {
      status = "okay";
    };

    &emmc {
      bus-width     = <8>;
      cap-mmc-highspeed;
      mmc-hs200-1_8v;
      non-removable;
      status        = "okay";
    };

    /* Ethernet — pinmux and PHY address may need tuning for your board */
    &gmac {
      phy-handle     = <&phy>;
      phy-mode       = "rmii";
      clock_in_out   = "output";
      status         = "okay";

      mdio {
        #address-cells = <1>;
        #size-cells    = <0>;

        phy: ethernet-phy@1 {
          compatible = "ethernet-phy-ieee802.3-c22";
          reg        = <1>;
        };
      };
    };
  '';

in pkgs.stdenv.mkDerivation {
  pname   = "linux-luckfox-nova";
  version = LINUX_VERSION;

  src = pkgs.fetchurl {
    url    = "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${LINUX_VERSION}.tar.xz";
    sha256 = lib.fakeHash;  # run: nix-prefetch-url <url>
  };

  nativeBuildInputs = with pkgs.buildPackages; [
    gnumake
    bison
    flex
    openssl
    perl
    bc
    elfutils          # needed for CONFIG_STACK_VALIDATION / objtool
    python3
    pkg-config
    dtc               # device tree compiler for out-of-tree DTS
  ];

  configurePhase = ''
    # Copy the out-of-tree Nova DTS into the RK3308 DTS directory so it
    # gets compiled alongside the in-tree Rockchip device trees.
    cp ${novaDts} arch/arm64/boot/dts/rockchip/rk3308-luckfox-nova.dts

    # Register the Nova DTS with the Makefile so it gets built.
    echo 'dtb-$(CONFIG_ARCH_ROCKCHIP) += rk3308-luckfox-nova.dtb' \
      >> arch/arm64/boot/dts/rockchip/Makefile

    make \
      ARCH=arm64 \
      CROSS_COMPILE=${crossCompile} \
      HOSTCC=${hostCC} \
      defconfig

    # Enable overlayfs for A/B rootfs support (not in arm64 defconfig by default).
    echo CONFIG_OVERLAY_FS=y >> .config
    make \
      ARCH=arm64 \
      CROSS_COMPILE=${crossCompile} \
      HOSTCC=${hostCC} \
      olddefconfig
  '';

  buildPhase = ''
    make -j$NIX_BUILD_CORES \
      ARCH=arm64 \
      CROSS_COMPILE=${crossCompile} \
      HOSTCC=${hostCC} \
      Image dtbs modules
  '';

  installPhase = ''
    mkdir -p $out/dtbs $out/lib/modules

    cp arch/arm64/boot/Image $out/

    # Copy all RK3308 DTBs — the Nova-specific one is among them.
    cp arch/arm64/boot/dts/rockchip/rk3308*.dtb $out/dtbs/ 2>/dev/null || true

    make \
      ARCH=arm64 \
      CROSS_COMPILE=${crossCompile} \
      INSTALL_MOD_PATH=$out \
      modules_install

    # Remove build/source symlinks that point outside $out (break the closure).
    find $out/lib/modules -maxdepth 2 \( -name build -o -name source \) \
      -type l -delete
  '';

  meta = {
    description = "Mainline Linux kernel for Luckfox Nova (RK3308B / AArch64)";
  };
}
