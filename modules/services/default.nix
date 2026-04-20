# Service module registry.
#
# Import this single file instead of listing each service module individually
# in mkSystem.nix.  All services default to disabled — enable them in your
# configuration.nix.
#
# To add a new service:
#   1. Create modules/services/myservice.nix (or .service)
#   2. Add it to the imports list below.

{ ... }:

{
  imports = [
    ./ssh.nix
    ./getty.nix
    ./meshing-around.nix
    ./hello.nix
  ];
}
