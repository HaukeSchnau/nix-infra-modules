{
  config,
  lib,
  ...
}:
{
  options.fleet = {
    enable = lib.mkEnableOption "small-fleet infrastructure modules";

    baseDomain = lib.mkOption {
      type = lib.types.str;
      default = "example.net";
      example = "example.net";
      description = "Base domain used by fleet modules and examples.";
    };

    caddy.acmeEmail = lib.mkOption {
      type = lib.types.str;
      default = "admin@example.net";
      description = "ACME account email used by Caddy.";
    };
  };

  config = lib.mkIf config.fleet.enable {
    assertions = [
      {
        assertion = config.fleet.baseDomain != "";
        message = "fleet.baseDomain must not be empty when fleet.enable = true.";
      }
    ];
  };
}
