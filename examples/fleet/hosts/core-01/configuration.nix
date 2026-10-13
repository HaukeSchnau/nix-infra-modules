{ nixosLib, ... }:
{
  imports = [
    (nixosLib.nixFlakeService {
      name = "demo";
      domain = "demo.example.net";
      public = false;
      port = 18080;
      package = "default";
      executable = "demo-server";
      source = {
        url = "git+https://git.example.net/example/demo-app.git";
        branch = "main";
      };
      health.paths = [ "/" ];
    })
  ];

  vps.services = {
    caddy = {
      enable = true;
      virtualHosts."admin.example.net" = {
        backend.port = 3000;
        tailscaleOnly = true;
      };
    };

    appDeployments.enable = true;
  };

  vps.appDeployments.webhook.enable = false;
}
