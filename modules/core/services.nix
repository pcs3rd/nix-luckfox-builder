
{ lib, ... }:

{
  options.services.definitions = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule {
      options = {
        enable = lib.mkEnableOption "";
        run = lib.mkOption { type = lib.types.lines; };
      };
    });
    default = {};
  };
}
