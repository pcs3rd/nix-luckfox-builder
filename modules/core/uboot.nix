
{ pkgs, config, lib, ... }:

let cfg = config.boot.uboot;

in {
  config.system.build.uboot = pkgs.runCommand "uboot" {} ''
    mkdir -p $out

    ${lib.optionalString (cfg.spl != null) ''
      cp ${cfg.spl} $out/SPL
    ''}

    ${lib.optionalString (cfg.package != null) ''
      cp ${cfg.package} $out/u-boot.bin
    ''}

    cat > $out/uboot-env.txt << EOF
${lib.concatStringsSep "\n" (lib.mapAttrsToList (k: v: "${k}=${v}") cfg.env)}
EOF
  '';
}
