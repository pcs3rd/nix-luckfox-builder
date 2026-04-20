{ pkgs, config, lib, ... }:

{
  # Bundle all build outputs into a single firmware directory.
  # This is what flake.nix exposes as packages.*.pico-mini-b and defaultPackage.
  config.system.build.firmware = pkgs.runCommand "firmware" {} ''
    mkdir -p $out

    # ── U-Boot / loader ───────────────────────────────────────────────────
    cp -r ${config.system.build.uboot}/. $out/

    # ── Rockchip parameter + layout ───────────────────────────────────────
    ${lib.optionalString config.rockchip.enable ''
      cp -r ${config.system.build.rockchip}/. $out/
    ''}

    # ── Root filesystem tarball ───────────────────────────────────────────
    tar -czf $out/rootfs.tar.gz -C ${config.system.build.rootfs} .

    # ── Manifest ─────────────────────────────────────────────────────────
    cat > $out/manifest.txt << EOF
device:   ${config.device.name}
hostname: ${config.networking.hostname}
built:    $(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF
  '';
}
