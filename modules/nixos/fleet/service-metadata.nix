{ lib }:
{
  mkOptions =
    {
      displayName,
      category,
      healthUnits ? [ ],
    }:
    {
      displayName = lib.mkOption {
        type = lib.types.str;
        default = displayName;
        description = "Human-friendly name used in generated VPS inventory output.";
      };

      category = lib.mkOption {
        type = lib.types.str;
        default = category;
        description = "Grouping label used by generated VPS inventory output.";
      };

      domain = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Primary domain shown in generated VPS inventory output.";
      };

      health.units = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = healthUnits;
        description = "Systemd units checked by the generated vps-health-check command.";
      };
    };
}
