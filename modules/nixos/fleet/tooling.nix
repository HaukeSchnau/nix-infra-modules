{
  config,
  lib,
  pkgs,
  ...
}:
let
  fleet = config.fleet;
  generatedInventory = import ../inventory/generated-inventory.nix { inherit lib; };
  inventoryRows = generatedInventory.formatInventoryRows fleet.generated.services;
  healthUnitArgs = lib.concatStringsSep " " (
    builtins.map lib.escapeShellArg fleet.generated.healthUnits
  );
in
{
  imports = [ ./generated-contract.nix ];

  options.fleet.tooling.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Install generated fleet inventory and health-check commands.";
  };

  config = lib.mkIf (fleet.enable && fleet.tooling.enable) {
    environment.systemPackages = [
      (pkgs.writeShellScriptBin "fleet-services" ''
                    printf '%-16s %-22s %-16s %-36s %s\n' "SERVICE" "DISPLAY" "CATEGORY" "DOMAIN" "HEALTH_UNITS"
                    printf '%-16s %-22s %-16s %-36s %s\n' "-------" "-------" "--------" "------" "------------"

                    while IFS=$'\t' read -r service display category domain units; do
                      [ -z "$service" ] && continue
                      printf '%-16s %-22s %-16s %-36s %s\n' "$service" "$display" "$category" "$domain" "$units"
                    done <<'VPS_INVENTORY'
        ${inventoryRows}
        VPS_INVENTORY
      '')

      (pkgs.writeShellScriptBin "fleet-health-check" ''
        failed=0
        units=( ${healthUnitArgs} )

        if [ ''${#units[@]} -eq 0 ]; then
          echo "No health units defined for enabled VPS services."
          exit 0
        fi

        for unit in "''${units[@]}"; do
          if systemctl is-active --quiet "$unit"; then
            printf '[ok] %s\n' "$unit"
          else
            printf '[fail] %s\n' "$unit"
            failed=1
          fi
        done

        exit "$failed"
      '')
    ];
  };
}
