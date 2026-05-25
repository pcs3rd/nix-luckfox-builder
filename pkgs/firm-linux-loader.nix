# firm_linux_loader — Luma3DS payload that loads a Linux kernel from the SD card.
#
# This is a pre-built FIRM binary from the linux-3ds project.  It is placed on
# the 3DS SD card as a Luma3DS chainloader payload:
#
#   /luma/payloads/firm_linux_loader.firm
#
# At boot, hold [START] to enter the Luma3DS chainloader, then select
# "firm_linux_loader".  It reads from /linux/ on the SD card:
#
#   /linux/zImage           — Linux kernel (ARM zImage)
#   /linux/initramfs.cpio.gz — initramfs (our busybox rootfs)
#   /linux/cmdline.txt      — kernel command line (one line, no newline required)
#
# Source: https://github.com/linux-3ds/firm_linux_loader/releases
#
# ── Updating ──────────────────────────────────────────────────────────────────
#
# 1. Find the latest release at:
#      https://github.com/linux-3ds/firm_linux_loader/releases
#
# 2. Get the new hash:
#      nix-prefetch-url https://github.com/linux-3ds/firm_linux_loader/releases/download/<tag>/firm_linux_loader.firm
#
# 3. Update url and sha256 below.

{ pkgs }:

pkgs.fetchurl {
  # Pin to a specific release tag for reproducibility.
  # v2.1 is the latest stable release at the time of this writing.
  # Check https://github.com/linux-3ds/firm_linux_loader/releases for newer ones.
  url    = "https://github.com/linux-3ds/firm_linux_loader/releases/download/v2.1/firm_linux_loader.firm";

  # FIXME ── replace with the real hash before building:
  #   nix-prefetch-url https://github.com/linux-3ds/firm_linux_loader/releases/download/v2.1/firm_linux_loader.firm
  sha256 = "sha256-yJh374j0TBCbZhkm+AGlbPQg9jcqMQ+6U6ThMLjVgq8=";
}
