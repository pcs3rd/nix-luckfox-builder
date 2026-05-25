# Nintendo 3DS system configuration.
#
# This is the single place to customise what runs on Linux-3DS.
# After editing, rebuild and copy to SD card:
#
#   nix build .#nintendo-3ds-sdcard
#   cp -r result/* /Volumes/NO\ NAME/    # macOS
#   cp -r result/* /mnt/sdcard/          # Linux
#
# Then reboot the 3DS: hold [START] → Luma chainloader → firm_linux_loader.
#
# ── What works on linux-3ds ───────────────────────────────────────────────────
#
#   ✓ Framebuffer console (top screen — shows kernel log and getty)
#   ✓ SD card access (/dev/mmcblk0)
#   ✓ WiFi (BCM43362/BCM4334 — requires proprietary firmware in /lib/firmware)
#   ✓ SSH over WiFi (once networking is up)
#   ✓ Both screens (bottom screen shows a basic virtual keyboard in linux-3ds)
#   ✗ Hardware 3D / GPU (not supported — display is framebuffer only)
#   ✗ Cameras, NFC, IR — driver support varies by kernel version

{ pkgs, buildDate ? "unknown", ... }:

{
  # ── Hardware support ─────────────────────────────────────────────────────────
  # Sets kernel, console, boot cmdline, hostname, and disables Rockchip features.
  nintendo3ds.support = true;

  # ── System ───────────────────────────────────────────────────────────────────

  # Compressed RAM swap — especially helpful on Old 3DS with only 128 MB.
  system.zram = {
    enable    = true;
    size      = "48M";      # compresses ~3:1 → ~144 MB effective swap
    algorithm = "lz4";
  };

  # ── Services ─────────────────────────────────────────────────────────────────

  # Serial/framebuffer console login.
  # tty0 is set automatically by 3ds-board.nix (framebuffer console).
  services.getty.enable = true;

  # SSH daemon (dropbear, static build).
  # Requires WiFi to be up; see networking section below.
  services.ssh.enable = true;

  # ── Networking ────────────────────────────────────────────────────────────────
  # DHCP on the WiFi interface.  The interface name depends on the kernel/driver:
  # typically wlan0 for BCM43362/BCM4334.
  # Note: WiFi firmware blobs must be present in the rootfs at /lib/firmware/ for
  # the wireless driver to initialise.  Add them via packages below.
  networking.dhcp.enable  = true;
  networking.interface    = "wlan0";

  # ── Users ────────────────────────────────────────────────────────────────────
  # Generate a new hash with:  openssl passwd -6 yourpassword
  # The default "!" locks root (no password login — access via on-screen keyboard).
  users.root.hashedPassword = "!";

  # ── Login banner / motd ───────────────────────────────────────────────────────
  # Overrides the defaults set by 3ds-board.nix if you want something custom.
  # Leave commented to use the board defaults.
  # system.banner = ''Nintendo 3DS — Linux  (\l)  |  Built ${buildDate}'';
  # system.motd   = ''Have fun!'';

  # ── Extra packages ────────────────────────────────────────────────────────────
  # Static binaries are preferred — they need no dynamic linker.
  # For WiFi firmware:
  #   packages = [ (pkgs.fetchurl { url = "..."; sha256 = "..."; }) ];
  # For utilities:
  packages = [];
}
