{ ... }:

{
  # DHCP is handled entirely in modules/core/networking.nix (service definition)
  # and modules/core/rootfs.nix (udhcpc invocation in inittab).
  # This file is intentionally empty; it is kept for potential future
  # networking-layer overrides.
}
