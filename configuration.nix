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

  # Vendor kernel modules — required for CONFIG_ZRAM=m and any other =m driver.
  # Uncomment once you have verified the luckfox-kernel-modules build succeeds:
  #   nix build .#packages.aarch64-darwin.pico-mini-b  (triggers the build)
  #
  # device.kernelModulesPath = "${localPkgs.luckfox-kernel-modules}/lib/modules";
  # Compressed RAM swap — gives ~96 MB of effective swap on a 64 MB board.
  # lz4 is fast enough that even a Cortex-A7 barely notices the overhead.
  system.zram = {
    enable    = true;
    size      = "32M";
    algorithm = "lz4";
  };

  services.nrfnet = {
    enable    = false;
    role      = "primary";      # or "secondary"
    spiDevice = "/dev/spidev0.0";
    channel   = 42;
  };
  services."meshing-around".enable = true;
  services.ssh.enable = false;
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
