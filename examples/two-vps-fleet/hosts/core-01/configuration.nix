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
      internalIngress.enable = true;
      virtualHosts."admin.example.net" = {
        upstream = "127.0.0.1:3000";
        tailscaleOnly = true;
      };
    };

    appDeployments.enable = true;
  };

  vps.appDeployments.webhook.enable = false;

  vps.generated.edgeIngress.tcpForwardRanges.demo = {
    listen = {
      from = 22000;
      to = 22002;
    };
    upstream = {
      from = 32000;
      to = 32002;
    };
  };
}
