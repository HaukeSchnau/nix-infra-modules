{ lib, ... }:
{
  system.stateVersion = "26.05";

  boot.isContainer = true;

  networking.useDHCP = false;
  networking.firewall.enable = true;

  vps = {
    enable = true;
    baseDomain = "example.net";
    caddy.acmeEmail = "admin@example.net";
  };

  services.caddy.enable = lib.mkDefault false;
}
