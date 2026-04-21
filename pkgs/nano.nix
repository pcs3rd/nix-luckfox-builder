# nano — terminal text editor (static ARM build)
#
# Uses nixpkgs' pkgsStatic.nano so we don't need to manage source hashes.
# Adds vt100 and linux terminfo entries next to the binary so nano can find
# them without a full /usr/share/terminfo tree on the target.
#
# To include in the rootfs, add to configuration.nix:
#   packages = with localPkgs; [ sysinfo htop nano ];

{ pkgs }:

pkgs.pkgsStatic.nano.overrideAttrs (old: {
  postInstall = (old.postInstall or "") + ''
    mkdir -p $out/etc/terminfo/v $out/etc/terminfo/l
    cp ${pkgs.ncurses}/share/terminfo/v/vt100 $out/etc/terminfo/v/
    cp ${pkgs.ncurses}/share/terminfo/l/linux $out/etc/terminfo/l/
  '';
})
