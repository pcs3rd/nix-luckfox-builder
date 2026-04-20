{ ... }:

{
  device = {
    name = "pico-mini-b";

    # kernel + DTB are hardware-specific, not user config
    kernel = ../kernel/zImage;
    dtb = ../kernel/pico-mini-b.dtb;
  };

  boot = {
    console = "ttyS0,115200";

    # kernel command line baseline for this board
    cmdline = "console=ttyS0 root=/dev/mmcblk0p1 rw rootfstype=ext4";
  };

  networking = {
    interface = "eth0";
  };

  # optional but common in real BSPs
  hardware = {
    cpu = "rv1106";   # or rv1103 depending on your Luckfox variant
  };
}