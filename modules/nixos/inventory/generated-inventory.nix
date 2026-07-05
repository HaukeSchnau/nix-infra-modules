{ lib }:
let
  serviceDomain =
    {
      baseDomain,
      service,
    }:
    if service ? metadata && service.metadata.domain != null then
      service.metadata.domain
    else if service ? domain && service.domain != null then
      service.domain
    else if service ? subdomain && service.subdomain != null then
      "${service.subdomain}.${baseDomain}"
    else
      null;

  enabledServiceNames =
    services:
    lib.filter (
      name:
      let
        service = services.${name};
      in
      service ? enable && service.enable
    ) (lib.attrNames services);

  mkGeneratedService =
    {
      baseDomain,
      name,
      service,
    }:
    {
      inherit name;
      displayName = service.metadata.displayName;
      category = service.metadata.category;
      domain = serviceDomain {
        inherit baseDomain service;
      };
      healthUnits = service.metadata.health.units;
    };

  generatedServicesFor =
    {
      baseDomain,
      services,
    }:
    builtins.map (
      name:
      mkGeneratedService {
        inherit baseDomain name;
        service = services.${name};
      }
    ) (enabledServiceNames services);

  healthUnitsForServices =
    services: lib.unique (lib.concatMap (service: service.healthUnits) services);

  vpsConfigurations =
    configurations:
    lib.filterAttrs (
      _: hostConfig: hostConfig.config ? vps && hostConfig.config.vps.enable
    ) configurations;

  generatedServicesForConfigurations =
    configurations:
    lib.concatMap (hostConfig: hostConfig.config.vps.generated.services) (
      lib.attrValues (vpsConfigurations configurations)
    );

  healthUnitsForConfigurations =
    configurations: healthUnitsForServices (generatedServicesForConfigurations configurations);

  ingressRoutesForConfigurations =
    configurations:
    lib.concatMap (hostConfig: lib.attrValues hostConfig.config.vps.generated.ingressRoutes) (
      lib.attrValues (vpsConfigurations configurations)
    );

  ingressDomainsForConfigurations =
    configurations:
    lib.unique (
      lib.sort builtins.lessThan (
        builtins.map (route: route.hostName) (ingressRoutesForConfigurations configurations)
      )
    );

  privateIngressDomainsForConfigurations =
    configurations:
    lib.unique (
      lib.sort builtins.lessThan (
        builtins.map (route: route.hostName) (
          builtins.filter (route: route.tailscaleOnly) (ingressRoutesForConfigurations configurations)
        )
      )
    );

  publicIngressDomainsForConfigurations =
    configurations:
    lib.unique (
      lib.sort builtins.lessThan (
        builtins.map (route: route.hostName) (
          builtins.filter (route: !route.tailscaleOnly) (ingressRoutesForConfigurations configurations)
        )
      )
    );

  formatInventoryRow =
    service:
    "${service.name}\t${service.displayName}\t${service.category}\t${
      if service.domain == null then "-" else service.domain
    }\t${lib.concatStringsSep "," service.healthUnits}";

  formatInventoryRows =
    services: lib.concatStringsSep "\n" (builtins.map formatInventoryRow services);
in
{
  inherit
    enabledServiceNames
    formatInventoryRow
    formatInventoryRows
    generatedServicesFor
    generatedServicesForConfigurations
    healthUnitsForConfigurations
    healthUnitsForServices
    ingressDomainsForConfigurations
    ingressRoutesForConfigurations
    mkGeneratedService
    privateIngressDomainsForConfigurations
    publicIngressDomainsForConfigurations
    serviceDomain
    vpsConfigurations
    ;
}
