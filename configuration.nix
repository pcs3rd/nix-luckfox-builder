{ pkgs, ... }:

let
  localPkgs = import ./pkgs { inherit pkgs; };
in

{
  imports = [
    ./hardware/pico-mini-b.nix
  ];

  # Extra packages — add your own derivations from pkgs/ here.
  packages = with localPkgs; [
    sysinfo
    htop
  ];

  services."meshing-around".enable = true;
  services.ssh.enable = true;
  services.getty.enable = true;

  networking = {
    dhcp.enable = true;
    hostname = "luckfox";
  };

  boot.uboot = {
    enable  = true;
    spl     = "${localPkgs.uboot}/SPL";
    package = "${localPkgs.uboot}/u-boot.img";   # Rockchip build produces u-boot.img (FIT image)
  };

  rockchip.enable = true;

  # Root password — generate a new hash with: openssl passwd -6 yourpassword
  # The default "!" locks the account entirely (no login without a hash set).
  users.root.hashedPassword = "$6$vW4NFpymQUO5omMq$Z1vcrtaS7bawg02BETzqGTpy35wWgqPMBeFKua6KyETDPUlEVvEldJ8EiR931L1UXnLMlBb/PgGhbnPnVo1/81"; # is `1234`
}
