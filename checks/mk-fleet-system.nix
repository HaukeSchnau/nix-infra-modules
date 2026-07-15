{
  lib,
  self,
  system,
}:
name: extraModules:
lib.nixosSystem {
  inherit system;
  modules = [
    self.nixosModules.fleet
    {
      networking.hostName = name;
      boot.isContainer = true;
      system.stateVersion = "25.05";
      vps = {
        enable = true;
        baseDomain = "example.net";
        caddy.acmeEmail = "admin@example.net";
      };
    }
  ]
  ++ extraModules;
}
