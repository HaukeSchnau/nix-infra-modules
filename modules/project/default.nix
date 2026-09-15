# Shared application requirements and release policy, independent of devenv.
{ config, lib, ... }:
let
  inherit (lib) mkOption types;
  cfg = config.project;
  omitNull = lib.filterAttrs (_: value: value != null);
  clean =
    value:
    if builtins.isAttrs value then
      lib.mapAttrs (_: clean) (omitNull value)
    else if builtins.isList value then
      map clean value
    else
      value;
  semanticName = types.strMatching "^[A-Za-z0-9_.-]+$";
  nullable =
    type:
    mkOption {
      type = types.nullOr type;
      default = null;
    };
  environmentType = types.attrsOf (
    types.either types.str (
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
    )
  );
  environment = lib.mapAttrs (_: value: if builtins.isAttrs value then omitNull value else value);
  environmentOption = mkOption {
    type = environmentType;
    default = { };
  };
  requirementType = types.submodule {
    options = {
      kind = mkOption {
        type = types.enum [
          "postgresql"
          "directory"
          "secret"
        ];
      };
      description = mkOption {
        type = types.str;
        default = "";
      };
      required = mkOption {
        type = types.bool;
        default = true;
      };
      realizations = mkOption {
        type = types.listOf (
          types.enum [
            "development"
            "release"
          ]
        );
        default = [
          "development"
          "release"
        ];
      };
      majorVersion = nullable types.ints.positive;
      majorVersions = nullable (types.listOf types.ints.positive);
      package = nullable types.package;
      dataDirectory = nullable types.str;
      path = nullable types.str;
      persistent = nullable types.bool;
      generate = nullable (
        types.submodule {
          options.bytes = mkOption {
            type = types.ints.between 16 1024;
            default = 32;
          };
        }
      );
    };
  };
  requirements = lib.mapAttrs (
    name: value:
    let
      declared = omitNull (builtins.removeAttrs value [ "package" ]);
      major =
        if value.package == null then null else lib.toInt (lib.versions.major value.package.version);
    in
    if major == null then
      declared
    else
      assert lib.assertMsg (
        value.kind == "postgresql"
        && (value.majorVersion == null || value.majorVersion == major)
        && (value.majorVersions == null || builtins.elem major value.majorVersions)
      ) "project.requirements.${name}: the PostgreSQL package must satisfy majorVersion";
      declared // lib.optionalAttrs (value.majorVersions == null) { majorVersion = major; }
  ) cfg.requirements;
in
{
  options.project = {
    name = nullable (types.strMatching "^[a-z0-9][a-z0-9-]{0,62}$");
    requirements = mkOption {
      type = types.attrsOf requirementType;
      default = { };
    };
    parameters = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            type = mkOption {
              type = types.enum [
                "string"
                "integer"
                "number"
                "boolean"
              ];
              default = "string";
            };
            description = mkOption {
              type = types.str;
              default = "";
            };
            required = nullable types.bool;
            default = nullable (
              types.oneOf [
                types.str
                types.int
                types.float
                types.bool
              ]
            );
          };
        }
      );
      default = { };
    };
    environment = environmentOption;
    release = nullable (import ./release-type.nix { inherit lib; });
    releaseEnvironment = mkOption {
      type = types.submodule {
        options.common = environmentOption;
        options.actions = mkOption {
          type = types.attrsOf environmentType;
          default = { };
        };
      };
      default = { };
    };
    declaration = mkOption {
      type = types.attrs;
      readOnly = true;
      internal = true;
    };
  };
  config.project.declaration = {
    schemaVersion = 4;
    project = cfg.name;
    inherit requirements;
    parameters = lib.mapAttrs (_: omitNull) cfg.parameters;
    release = clean cfg.release;
    environment = lib.optionalAttrs (cfg.release != null) {
      release = {
        common = environment cfg.releaseEnvironment.common;
        actions = lib.mapAttrs (_: environment) cfg.releaseEnvironment.actions;
      };
    };
  };
}
