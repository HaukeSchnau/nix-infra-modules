# Option types shared by the Project authoring modules. The normalizer relies
# on these types, so it only checks cross-references and derived rules.
{ lib }:
let
  inherit (lib) mkOption types;
  nullable =
    type:
    mkOption {
      type = types.nullOr type;
      default = null;
    };
in
rec {
  inherit nullable;

  # Workload, endpoint, command and job names become unit and host name parts.
  name = types.strMatching "^[a-z0-9][a-z0-9-]{0,62}$";
  semanticName = types.strMatching "^[A-Za-z0-9_.-]+$";

  # A value is a literal string or exactly one reference to runtime context.
  environmentReference = types.either types.str (
    types.submodule {
      options = {
        binding = nullable semanticName;
        endpoint = nullable semanticName;
        parameter = nullable semanticName;
        secret = nullable semanticName;
        path = nullable (
          types.enum [
            "checkout"
            "state"
            "cache"
            "runtime"
          ]
        );
        instance = nullable (types.enum [ "id" ]);
        field = nullable types.str;
        append = nullable types.str;
      };
    }
  );
  environment = types.attrsOf environmentReference;

  # Health checks whose unset fields fall back to `inherited`, field by field.
  healthInheriting =
    inherited:
    let
      field =
        name: type:
        mkOption {
          type = types.nullOr type;
          default = inherited.${name} or null;
        };
    in
    types.submodule {
      options = {
        paths = field "paths" (types.listOf types.str);
        startupTimeoutSec = field "startupTimeoutSec" types.ints.positive;
        intervalSec = field "intervalSec" types.ints.positive;
        requestTimeoutSec = field "requestTimeoutSec" types.ints.positive;
      };
    };
  health = healthInheriting { };

  # Drops unset optional values so the normalizer can apply its defaults.
  clean =
    value:
    if builtins.isAttrs value && !lib.isDerivation value then
      lib.mapAttrs (_: clean) (lib.filterAttrs (_: item: item != null) value)
    else if builtins.isList value then
      map clean value
    else
      value;
}
