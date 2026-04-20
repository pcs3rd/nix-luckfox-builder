
{ pkgs, ... }:

{
  config.system.build.rootfs = pkgs.runCommand "rootfs" {} ''
    mkdir -p $out/{bin,etc,proc,sys,dev,root,sbin}

    cp ${pkgs.pkgsStatic.busybox}/bin/busybox $out/bin/
    chmod +x $out/bin/busybox

    for i in sh ls cat echo mount; do
      ln -s /bin/busybox $out/bin/$i
    done

    cat > $out/init << 'EOF'
exec /sbin/init
EOF
    chmod +x $out/init
  '';
}
