# The service controller on one VM: a deploy, a rollback after a failed health check, a failed
# `prepare` that keeps the old revision, refusals, a preview's deletion, dumps, a reboot, and
# `fleet status`. `fleet-put` drives the API the way Fleet.Service does: PUT, then poll until the
# host reports the generation's outcome.
{
  pkgs,
  self,
}:
let
  node = pkgs.nodejs-slim_26;
  psql = "${pkgs.postgresql_18}/bin/psql";

  # A release's bundle. `ready` is what its health path answers; `prepareFails` makes its
  # migration fail.
  bundle =
    {
      revision,
      ready ? 200,
      prepareFails ? false,
    }:
    pkgs.runCommand "fleet-test-bundle-${revision}" { } ''
      mkdir -p $out/bin
      cat > $out/server.mjs <<'JS'
      import { createServer } from "node:http"
      import { readFileSync } from "node:fs"
      const file = (variable) => readFileSync(process.env[variable], "utf8")
      createServer((request, response) => {
        if (request.url === "/ready") {
          response.writeHead(${toString ready}).end(JSON.stringify({ revision: "${revision}" }))
        } else if (request.url === "/info") {
          response.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({
            revision: "${revision}",
            user: process.env.USER,
            argv: process.argv.slice(2),
            tricky: process.env.TRICKY,
            apiKey: file("API_KEY_FILE"),
            smtpPassword: file("SMTP_PASSWORD_FILE"),
            database: process.env.DATABASE_URL,
          }))
        } else {
          response.writeHead(404).end()
        }
      }).listen(Number(process.env.PORT), process.env.HOST, () => console.log("${revision} listens on " + process.env.PORT))
      JS
      cat > $out/bin/prepare <<'SH'
      #!${pkgs.runtimeShell}
      set -eu
      ${
        if prepareFails then
          ''
            echo "migration 0002_homework failed: column \"due\" already exists" >&2
            exit 3
          ''
        else
          ''
            ${psql} "$DATABASE_URL" -v ON_ERROR_STOP=1 -q \
              -c "CREATE TABLE IF NOT EXISTS releases (revision text)" \
              -c "INSERT INTO releases VALUES ('${revision}')"
            echo "migrated to ${revision}"
          ''
      }
      SH
      cat > $out/bin/console <<'SH'
      #!${pkgs.runtimeShell}
      echo "console of ${revision} as $USER: $*"
      ${psql} "$DATABASE_URL" -At -c "SELECT string_agg(revision, ',') FROM releases"
      SH
      chmod +x $out/bin/*
    '';
  bundles = {
    first = bundle { revision = "1111111"; };
    second = bundle { revision = "2222222"; };
    unhealthy = bundle {
      revision = "3333333";
      ready = 503;
    };
    brokenMigration = bundle {
      revision = "4444444";
      prepareFails = true;
    };
  };

  # A test-only age key and a SOPS file encrypted for it.
  secrets =
    pkgs.runCommand "fleet-test-secrets"
      {
        nativeBuildInputs = [
          pkgs.age
          pkgs.sops
        ];
      }
      ''
        mkdir $out
        export HOME=$TMPDIR
        age-keygen -o $out/key.txt
        cat > plain.yaml <<'YAML'
        projects:
          shop:
            smtp-password: from-sops
        other:
          token: not-for-shop
        YAML
        sops --encrypt --age "$(age-keygen -y $out/key.txt)" --input-type yaml --output-type yaml plain.yaml > $out/secrets.yaml
      '';

  fleetPut = pkgs.writeScriptBin "fleet-put" ''
    #!${pkgs.python3}/bin/python3
    """fleet-put <service> <spec.json> <token>: PUT a spec and wait for its outcome, as Fleet.Service does."""
    import json, sys, time, urllib.error, urllib.request

    def call(method, url, token, body=None):
        data = None if body is None else json.dumps(body).encode()
        request = urllib.request.Request(url, data=data, method=method, headers={"Authorization": f"Bearer {token}"})
        try:
            with urllib.request.urlopen(request) as response:
                return response.status, json.load(response)
        except urllib.error.HTTPError as error:
            return error.code, json.load(error)

    name, path, token = sys.argv[1:4]
    url = f"http://127.0.0.1:18110/services/{name}"
    started = time.monotonic()
    status, body = call("PUT", url, token, json.load(open(path)))
    result = {"status": status, "body": body}
    if status == 202:
        while True:
            time.sleep(0.25)
            _, service = call("GET", url, token)
            entry = next(entry for entry in service["deploys"] if entry["generation"] == body["generation"])
            if entry["outcome"] != "deploying":
                result.update(outcome=entry["outcome"], reason=entry["reason"])
                break
    result["seconds"] = round(time.monotonic() - started, 3)
    print(json.dumps(result))
  '';
in
pkgs.testers.runNixOSTest {
  name = "service-controller";

  nodes.machine = {
    imports = [ self.nixosModules.services ];
    virtualisation.memorySize = 2048;
    virtualisation.additionalPaths = [ node ] ++ builtins.attrValues bundles;
    environment.systemPackages = [
      fleetPut
      pkgs.curl
      pkgs.jq
    ];
    vps.enable = true;
    vps.services.serviceController = {
      enable = true;
      grantKeyFile = "${pkgs.writeText "grant-key" "test-grant-key"}";
      ageKeyFile = "${secrets}/key.txt";
      sopsFile = "${secrets}/secrets.yaml";
      postgresql.package = pkgs.postgresql_18;
      addresses.ipv4 = "203.0.113.10";
      firewallInterfaces = [ ];
      grants = {
        shop = {
          hostNames = [ "*.shop.example.net" ];
          public = true;
          services = 2;
          memoryMax = "1G";
          secretPrefixes = [ "projects/shop/" ];
          databases = true;
        };
        blog.hostNames = [ "blog.example.net" ];
      };
    };
  };

  testScript = ''
    import hashlib, hmac, json

    def token(grant):
        return hmac.new(b"test-grant-key", grant.encode(), hashlib.sha256).hexdigest()

    SHOP, BLOG = token("shop"), token("blog")

    def spec(bundle, **fields):
        return {
            "release": {"revision": bundle.split("-")[-1], "paths": {"bundle": bundle, "node": "${node}"}},
            "command": ["{node}/bin/node", "{bundle}/server.mjs", "serve", '100% "quoted" $HOME'],
            "prepare": ["{bundle}/bin/prepare"],
            "console": ["{bundle}/bin/console"],
            "endpoint": {"hostName": "beta.shop.example.net", "visibility": "public"},
            "health": {"path": "/ready", "timeoutSec": 10},
            "database": {"majorVersion": 18},
            "env": {"TRICKY": 'a "b" %c $d \\e'},
            "secrets": {"API_KEY": {"value": "sealed-value"}, "SMTP_PASSWORD": {"sops": "projects/shop/smtp-password"}},
            "memory": {"max": "512M"},
            **fields,
        }

    def put(name, body, grant_token=SHOP):
        machine.succeed("cat > /tmp/spec.json <<'JSON'\n" + json.dumps(body) + "\nJSON")
        result = json.loads(machine.succeed(f"fleet-put {name} /tmp/spec.json {grant_token}"))
        print(f"PUT {name}: {json.dumps(result)}")
        return result

    def plan(name, body, grant_token=SHOP):
        machine.succeed("cat > /tmp/spec.json <<'JSON'\n" + json.dumps(body) + "\nJSON")
        answer, status = machine.succeed(
            f"curl -s -w '\\n%{{http_code}}' -X POST -H 'Authorization: Bearer {grant_token}' "
            f"--data-binary @/tmp/spec.json http://127.0.0.1:18110/services/{name}/plan"
        ).rsplit("\n", 1)
        return int(status), json.loads(answer)

    def info():
        port = json.loads(machine.succeed("cat /var/lib/fleet/routes.json"))[0]["upstreamPort"]
        return json.loads(machine.succeed(f"curl -sf http://127.0.0.1:{port}/info"))

    def main_pid():
        return machine.succeed("systemctl show --property=MainPID --value fleet-service@shop-beta.service").strip()

    timings = {}
    machine.wait_for_unit("fleet-controller.service")
    machine.wait_for_open_port(18110)

    with subtest("a service deploys with its paths, environment, secrets and database"):
        result = put("shop-beta", spec("${bundles.first}"))
        assert result["outcome"] == "active", result
        timings["first deploy"] = result["seconds"]
        running = info()
        assert running["revision"] == "1111111", running
        assert running["user"] == "fleet-shop-beta", running
        assert running["argv"] == ["serve", '100% "quoted" $HOME'], running
        assert running["tricky"] == 'a "b" %c $d \\e', running
        assert running["apiKey"] == "sealed-value" and running["smtpPassword"] == "from-sops", running
        machine.succeed("ps -o user:32= -p $(systemctl show --property=MainPID --value fleet-service@shop-beta.service) | grep -x fleet-shop-beta")
        assert "sealed-value" not in machine.succeed("cat /var/lib/fleet/services/shop-beta/generations/*.json")
        route = json.loads(machine.succeed("cat /var/lib/fleet/routes.json"))[0]
        assert route["hostName"] == "beta.shop.example.net" and route["visibility"] == "public", route
        machine.succeed(f"grep -x 'reverse_proxy 127.0.0.1:{route['upstreamPort']}' {route['site']}")

    with subtest("an unchanged spec changes nothing"):
        pid = main_pid()
        result = put("shop-beta", spec("${bundles.first}"))
        assert result["status"] == 200 and result["body"]["changed"] is False, result
        assert main_pid() == pid
        timings["unchanged"] = result["seconds"]
        assert result["seconds"] < 2, result

    with subtest("the dry run shows what a new revision changes"):
        status, answer = plan("shop-beta", spec("${bundles.second}"))
        assert status == 200 and answer["changes"] == ["release"], answer
        assert info()["revision"] == "1111111"

    with subtest("a new revision deploys"):
        result = put("shop-beta", spec("${bundles.second}"))
        assert result["outcome"] == "active", result
        timings["new revision"] = result["seconds"]
        assert result["seconds"] < 15, result
        assert info()["revision"] == "2222222"

    with subtest("a revision whose health check fails rolls back"):
        result = put("shop-beta", spec("${bundles.unhealthy}"))
        assert result["outcome"] == "rolled-back", result
        assert result["reason"] == "/ready did not answer 200 within 10s, last status 503; the process wrote: 3333333 listens on 18300", result
        timings["rollback"] = result["seconds"]
        machine.wait_until_succeeds("curl -sf http://127.0.0.1:18300/ready")
        assert info()["revision"] == "2222222"

    with subtest("a failed prepare keeps the old revision running"):
        pid = main_pid()
        result = put("shop-beta", spec("${bundles.brokenMigration}"))
        assert result["outcome"] == "failed", result
        assert 'prepare exited with 3: migration 0002_homework failed: column "due" already exists' in result["reason"], result
        assert main_pid() == pid, "a failed prepare must not restart the service"
        assert info()["revision"] == "2222222"

    with subtest("the grant limits hostnames, visibility, secrets, memory, count and databases"):
        refusals = [
            ("shop-beta", spec("${bundles.second}", endpoint={"hostName": "www.example.net"}), SHOP, "shop may not claim www.example.net"),
            ("shop-beta", spec("${bundles.second}", secrets={"T": {"sops": "other/token"}}), SHOP, "secret T may not read other/token; shop reads keys under projects/shop/"),
            ("shop-beta", spec("${bundles.second}", memory={"max": "2G"}), SHOP, "memory max 2G is above what is left of shop's 1G: its other services take 0M"),
            ("blog", spec("${bundles.second}", endpoint={"hostName": "blog.example.net", "visibility": "public"}, memory={}), BLOG, "blog may not be public"),
            ("blog", spec("${bundles.second}", endpoint=None, memory={}), BLOG, "blog may not have databases"),
        ]
        for name, body, grant_token, reason in refusals:
            status, answer = plan(name, body, grant_token)
            assert status == 422 and reason in answer["reasons"], (reason, answer)
        status, _ = plan("shop-beta", spec("${bundles.second}"), BLOG)
        assert status == 403, "a grant's token opens only its own services"

    with subtest("a preview gets its own database, and deleting it drops the database"):
        preview = spec("${bundles.second}", endpoint={"hostName": "pr-1.shop.example.net", "visibility": "tailnet"}, memory={"max": "256M"})
        result = put("shop-pr-1", preview)
        assert result["outcome"] == "active", result
        status, answer = plan("shop-pr-2", spec("${bundles.second}", endpoint=None, memory={"max": "64M"}))
        assert status == 422 and "shop may run 2 services, and runs 2 others" in answer["reasons"], answer
        machine.succeed("runuser -u postgres -- psql -At -c \"SELECT 1 FROM pg_database WHERE datname = 'fleet-shop-pr-1'\" | grep -x 1")
        machine.succeed(f"curl -sf -X DELETE -H 'Authorization: Bearer {SHOP}' http://127.0.0.1:18110/services/shop-pr-1")
        machine.succeed("runuser -u postgres -- psql -At -c \"SELECT count(*) FROM pg_database WHERE datname = 'fleet-shop-pr-1'\" | grep -x 0")
        machine.fail("systemctl is-active fleet-service@shop-pr-1.service")
        assert [route["name"] for route in json.loads(machine.succeed("cat /var/lib/fleet/routes.json"))] == ["shop-beta"]

    with subtest("a stale fence is refused"):
        assert put("shop-beta", {**spec("${bundles.second}"), "fence": 20})["status"] == 200
        result = put("shop-beta", {**spec("${bundles.second}"), "fence": 10})
        assert result["status"] == 409 and "stale" in result["body"]["error"], result

    with subtest("the databases are dumped"):
        machine.succeed("systemctl start fleet-dump.service")
        machine.succeed("${pkgs.postgresql_18}/bin/pg_restore --list /var/backup/fleet/fleet-shop-beta.dump | grep -q 'TABLE public releases'")

    with subtest("the fleet command shows the services, their logs and their console"):
        print(machine.succeed("fleet status"))
        detail = machine.succeed("fleet status shop-beta")
        print(detail)
        assert "rolled-back" in detail and "0002_homework" in detail, detail
        machine.succeed("fleet logs shop-beta --lines 5 --no-pager")
        console = machine.succeed("fleet console shop-beta check --verbose")
        print(console)
        # The rolled-back revision's prepare stays applied, which is why migrations expand and contract.
        assert "console of 2222222 as fleet-shop-beta: check --verbose\n1111111,2222222,3333333" in console, console

    with subtest("a reboot brings the services back"):
        machine.shutdown()
        machine.start()
        machine.wait_for_unit("fleet-controller.service")
        machine.wait_until_succeeds("curl -sf http://127.0.0.1:18300/ready", timeout=60)
        running = info()
        assert running["revision"] == "2222222" and running["apiKey"] == "sealed-value" and running["smtpPassword"] == "from-sops", running

    print("timings: " + json.dumps(timings))
  '';
}
