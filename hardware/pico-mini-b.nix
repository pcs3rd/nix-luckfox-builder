# Hardware profile for the Luckfox Pico Mini B.
#
# Place your Luckfox SDK build outputs here before building:
#   hardware/kernel/zImage
#   hardware/kernel/pico-mini-b.dtb
#
# Until those files are present, kernel and dtb default to null and the SD
# image step will be skipped (rootfs + uboot bundles still build fine).

{ ... }:

{
  device = {
    name   = "pico-mini-b";
    # Uncomment once you have the SDK kernel outputs:
    # kernel = ./kernel/zImage;
    # dtb    = ./kernel/pico-mini-b.dtb;
  };
}
