{
  fleet.services = {
    caddy = {
      enable = true;
      virtualHosts = {
        "admin.example.net" = {
          backend.port = 3000;
          tailscaleOnly = true;
        };
        "www.example.net" = {
          backend.port = 8080;
          tailscaleOnly = false;
        };
      };
    };

    # The shared container runtime that services' containers join.
    podman.enable = true;
  };
}
