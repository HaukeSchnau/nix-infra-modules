# The service controller on one VM: deploys, rollbacks, a failed `prepare` that keeps the old
# revision, the grant's refusals, owners, deletion with and without the database, isolation between
# services, a grant that shrinks under running services, an undecryptable secret, dumps, a reboot,
# and `fleet status`. `fleet-put` drives the API the way Fleet.Service does: PUT, then poll until
# the host reports the generation's outcome.
{
  pkgs,
  self,
}:
let
  node = pkgs.nodejs-slim_26;
  psql = "${pkgs.postgresql_18}/bin/psql";

  # A release's bundle. `ready` is what its health path answers, `exits` makes the server exit
  # cleanly at once, and `prepareFails` makes its migration fail.
  bundle =
    {
      revision,
      ready ? 200,
      exits ? false,
      prepareFails ? false,
    }:
    pkgs.runCommand "fleet-test-bundle-${revision}" { } ''
      mkdir -p $out/bin
      cat > $out/server.mjs <<'JS'
      import { createServer } from "node:http"
      import { readFileSync } from "node:fs"
      ${if exits then "process.exit(0)" else ""}
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
      case "''${1:-}" in
        connect)
          exec ${psql} "postgresql:///$2?host=/run/postgresql&user=$USER" -At -c "SELECT 1" ;;
        bind)
          exec ${node}/bin/node -e 'require("net").createServer().listen(Number(process.argv[1]), "127.0.0.1", () => console.log("bound")).on("error", (error) => { console.log("bind refused: " + error.code); process.exit(3) })' "$2" ;;
      esac
      echo "console of ${revision} as $USER: $*"
      ${psql} "$DATABASE_URL" -At -c "SELECT string_agg(DISTINCT revision, ',' ORDER BY revision) FROM releases"
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
    exits = bundle {
      revision = "5555555";
      exits = true;
    };
  };

  # The two sops-nix options the controller defaults to, without sops-nix itself.
  sopsNix =
    { lib, ... }:
    {
      options.sops = {
        defaultSopsFile = lib.mkOption { type = lib.types.path; };
        age.keyFile = lib.mkOption { type = lib.types.str; };
      };
    };

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

  nodes.machine =
    { lib, ... }:
    {
      imports = [
        self.nixosModules.services
        sopsNix
      ];
      virtualisation.memorySize = 2048;
      virtualisation.additionalPaths = [ node ] ++ builtins.attrValues bundles;
      environment.systemPackages = [
        fleetPut
        pkgs.curl
      ];
      # As with sops-nix: the SOPS file is a path in the repository, the key a file on the host.
      # The controller finds both through its defaults.
      sops.defaultSopsFile = ./test-secrets/secrets.yaml;
      sops.age.keyFile = "/etc/fleet-test/key.txt";
      environment.etc."fleet-test/key.txt" = {
        source = ./test-secrets/key.txt;
        mode = "0400";
      };
      vps.enable = true;
      vps.services.serviceController = {
        enable = true;
        grantKeyFile = "${pkgs.writeText "grant-key" "test-grant-key"}";
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
      # The same host after its grant shrank below what runs, and after it revoked a permission.
      specialisation.shrunk.configuration.vps.services.serviceController.grants.shop.memoryMax =
        lib.mkForce "256M";
      specialisation.revoked.configuration.vps.services.serviceController.grants.shop.public =
        lib.mkForce false;
    };

  testScript = ''
    import hashlib, hmac, json

    def token(grant):
        return hmac.new(b"test-grant-key", grant.encode(), hashlib.sha256).hexdigest()

    SHOP, BLOG = token("shop"), token("blog")
    BETA = {"stack": "Shop", "stage": "beta", "fqn": "Server"}
    PREVIEW = {"stack": "Shop", "stage": "pr-1", "fqn": "Server"}

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

    def put(name, body, grant_token=SHOP, owner=BETA, **extra):
        body = {**body, "owner": owner, **extra}
        machine.succeed("cat > /tmp/spec.json <<'JSON'\n" + json.dumps(body) + "\nJSON")
        result = json.loads(machine.succeed(f"fleet-put {name} /tmp/spec.json {grant_token}"))
        print(f"PUT {name}: {json.dumps(result)}")
        return result

    def call(method, path, body, grant_token=SHOP):
        machine.succeed("cat > /tmp/body.json <<'JSON'\n" + json.dumps(body) + "\nJSON")
        answer, status = machine.succeed(
            f"curl -s -w '\\n%{{http_code}}' -X {method} -H 'Authorization: Bearer {grant_token}' "
            f"--data-binary @/tmp/body.json http://127.0.0.1:18110/services/{path}"
        ).rsplit("\n", 1)
        return int(status), json.loads(answer)

    def plan(name, body, grant_token=SHOP):
        return call("POST", f"{name}/plan", body, grant_token)

    def sql(query):
        return machine.succeed(f"runuser -u postgres -- psql -At -c \"{query}\"").strip()

    def info():
        port = json.loads(machine.succeed("cat /var/lib/fleet/routes.json"))[0]["upstreamPort"]
        return json.loads(machine.succeed(f"curl -sf http://127.0.0.1:{port}/info"))

    def main_pid():
        return machine.succeed("systemctl show --property=MainPID --value fleet-service@shop-beta.service").strip()

    def restart_controller():
        machine.succeed("systemctl restart fleet-controller.service")
        machine.wait_for_open_port(18110)

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
        # The SOPS secret comes through the controller's default sopsFile, a path in the repository.
        assert running["apiKey"] == "sealed-value" and running["smtpPassword"] == "from-sops", running
        machine.succeed("ps -o user:32= -p $(systemctl show --property=MainPID --value fleet-service@shop-beta.service) | grep -x fleet-shop-beta")
        assert "sealed-value" not in machine.succeed("cat /var/lib/fleet/services/shop-beta/generations/*.json")
        routes = json.loads(machine.succeed("cat /var/lib/fleet/routes.json"))
        assert routes == [{"name": "shop-beta", "hostName": "beta.shop.example.net", "visibility": "public", "upstreamPort": 18300}], routes

    with subtest("each service is isolated: no swap, its own port, its own database with a connection limit"):
        assert machine.succeed("systemctl show --property=MemorySwapMax --value fleet-service@shop-beta.service").strip() == "0"
        assert sql("SELECT rolconnlimit FROM pg_roles WHERE rolname = 'fleet-shop-beta'") == "40"
        assert sql("SELECT has_database_privilege('public', 'fleet-shop-beta', 'CONNECT')") == "f"
        status, output = machine.execute("fleet console shop-beta bind 18450 2>&1")
        assert status == 3 and "bind refused: EPERM" in output, output

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

    with subtest("a revision whose process exits cleanly rolls back at once"):
        result = put("shop-beta", spec("${bundles.exits}"))
        assert result["outcome"] == "rolled-back" and result["reason"].startswith("the process exited"), result
        assert result["seconds"] < 8, result
        machine.wait_until_succeeds("curl -sf http://127.0.0.1:18300/ready")
        assert info()["revision"] == "2222222"

    with subtest("a failed prepare keeps the old revision running"):
        pid = main_pid()
        result = put("shop-beta", spec("${bundles.brokenMigration}"))
        assert result["outcome"] == "failed", result
        assert 'prepare exited with 3: migration 0002_homework failed: column "due" already exists' in result["reason"], result
        assert main_pid() == pid, "a failed prepare must not restart the service"
        assert info()["revision"] == "2222222"

    with subtest("the grant limits hostnames, visibility, secrets, memory and databases"):
        refusals = [
            ("shop-beta", spec("${bundles.second}", endpoint={"hostName": "www.example.net"}), SHOP, "shop may not claim www.example.net"),
            ("shop-beta", spec("${bundles.second}", secrets={"T": {"sops": "other/token"}}), SHOP, "secret T names a SOPS key outside projects/shop/, which shop may read"),
            ("shop-beta", spec("${bundles.second}", memory={"max": "2G"}), SHOP, "memory max 2G is above what is left of shop's 1G: its other services take 0M"),
            ("blog", spec("${bundles.second}", endpoint={"hostName": "blog.example.net", "visibility": "public"}, memory={}), BLOG, "blog may not be public"),
            ("blog", spec("${bundles.second}", endpoint=None, memory={}), BLOG, "blog may not have databases"),
        ]
        for name, body, grant_token, reason in refusals:
            status, answer = plan(name, body, grant_token)
            assert status == 422 and reason in answer["reasons"], (reason, answer)
            assert "other/token" not in json.dumps(answer), answer
        status, _ = plan("shop-beta", spec("${bundles.second}"), BLOG)
        assert status == 403, "a grant's token opens only its own services"

    with subtest("another owner can neither change nor delete a service, unless it adopts it"):
        result = put("shop-beta", spec("${bundles.second}"), owner=PREVIEW)
        assert result["status"] == 422 and result["body"]["reasons"] == ["shop-beta belongs to Server in stack Shop, stage beta; a stack takes it over only by adopting it"], result
        status, answer = call("DELETE", "shop-beta", {"owner": PREVIEW})
        assert status == 200 and answer["deleted"] is False, answer
        assert info()["revision"] == "2222222"
        assert put("shop-beta", spec("${bundles.second}"), owner=PREVIEW, adopt=True)["status"] == 200
        assert call("GET", "shop-beta", {})[1]["owner"] == PREVIEW
        assert put("shop-beta", spec("${bundles.second}"), owner=BETA, adopt=True)["status"] == 200

    with subtest("a preview's database is dumped and dropped with it, and its fence outlives it"):
        preview = spec("${bundles.second}", endpoint={"hostName": "pr-1.shop.example.net", "visibility": "tailnet"}, memory={"max": "256M"}, database={"dropOnDelete": True})
        result = put("shop-pr-1", preview, owner=PREVIEW, fence=30)
        assert result["outcome"] == "active", result
        status, answer = plan("shop-pr-2", spec("${bundles.second}", endpoint=None, memory={"max": "64M"}))
        assert status == 422 and "shop may run 2 services, and runs 2 others" in answer["reasons"], answer
        status, output = machine.execute("fleet console shop-pr-1 connect fleet-shop-beta 2>&1")
        assert status != 0 and "permission denied for database" in output, output
        assert sql("SELECT count(*) FROM pg_database WHERE datname = 'fleet-shop-pr-1'") == "1"
        status, answer = call("DELETE", "shop-pr-1", {"owner": PREVIEW, "fence": 30})
        assert status == 200 and answer["deleted"] is True, answer
        assert sql("SELECT count(*) FROM pg_database WHERE datname = 'fleet-shop-pr-1'") == "0"
        machine.succeed("${pkgs.postgresql_18}/bin/pg_restore --list /var/backup/fleet/deleted/fleet-shop-pr-1-*.dump | grep -q 'TABLE public releases'")
        machine.fail("systemctl is-active fleet-service@shop-pr-1.service")
        assert [route["name"] for route in json.loads(machine.succeed("cat /var/lib/fleet/routes.json"))] == ["shop-beta"]
        result = put("shop-pr-1", preview, owner=PREVIEW, fence=20)
        assert result["status"] == 409 and "stale" in result["body"]["error"], result

    with subtest("deleting a service keeps its database unless the spec says otherwise"):
        assert put("shop-pr-2", spec("${bundles.second}", endpoint=None, memory={"max": "256M"}), owner=PREVIEW)["outcome"] == "active"
        status, answer = call("DELETE", "shop-pr-2", {"owner": PREVIEW})
        assert status == 200 and answer["deleted"] is True, answer
        assert sql("SELECT count(*) FROM pg_database WHERE datname = 'fleet-shop-pr-2'") == "1"
        machine.fail("ls /var/backup/fleet/deleted/fleet-shop-pr-2-*")
        # The kept database stays its owner's: another stack takes the name only by adopting it.
        status, answer = call("GET", "shop-pr-2", {})
        assert status == 404 and answer["kept"] == {"owner": PREVIEW}, answer
        result = put("shop-pr-2", spec("${bundles.second}", endpoint=None, memory={"max": "256M"}, database={"dropOnDelete": True}))
        assert result["status"] == 422 and "a stack takes it over only by adopting it" in result["body"]["reasons"][0], result

    with subtest("a stale fence is refused"):
        assert put("shop-beta", spec("${bundles.second}"), fence=20)["status"] == 200
        result = put("shop-beta", spec("${bundles.second}"), fence=10)
        assert result["status"] == 409 and "stale" in result["body"]["error"], result

    with subtest("a grant that shrinks under a running service keeps it running and refuses its next PUT"):
        pid = main_pid()
        machine.succeed("/run/booted-system/specialisation/shrunk/bin/switch-to-configuration test")
        machine.wait_for_open_port(18110)
        assert main_pid() == pid
        violations = call("GET", "shop-beta", {})[1]["violations"]
        assert violations == ["memory max 512M is above what is left of shop's 256M: its other services take 0M"], violations
        assert "(over its grant)" in machine.succeed("fleet status")
        result = put("shop-beta", spec("${bundles.second}"))
        assert result["status"] == 422, result
        machine.succeed("/run/booted-system/bin/switch-to-configuration test")
        machine.wait_for_open_port(18110)
        assert main_pid() == pid
        assert call("GET", "shop-beta", {})[1]["violations"] == []

    with subtest("a grant that revokes a permission stops the service and drops its route until it allows it again"):
        machine.succeed("/run/booted-system/specialisation/revoked/bin/switch-to-configuration test")
        machine.wait_for_open_port(18110)
        machine.wait_until_fails("systemctl is-active fleet-service@shop-beta.service")
        assert json.loads(machine.succeed("cat /var/lib/fleet/routes.json")) == []
        assert call("GET", "shop-beta", {})[1]["stopped"] == {"by": "grant", "reason": "shop may not be public"}
        assert put("shop-beta", spec("${bundles.second}"))["status"] == 422
        machine.succeed("/run/booted-system/bin/switch-to-configuration test")
        machine.wait_for_open_port(18110)
        machine.wait_until_succeeds("curl -sf http://127.0.0.1:18300/ready")
        assert [route["name"] for route in json.loads(machine.succeed("cat /var/lib/fleet/routes.json"))] == ["shop-beta"]

    with subtest("an operator stops a service until its stack deploys it, and deletes one; only root may"):
        machine.succeed("curl -sf --unix-socket /run/fleet/controller.sock http://localhost/services/shop-beta")
        status, output = machine.execute("runuser -u nobody -- curl -sS --unix-socket /run/fleet/controller.sock http://localhost/services/shop-beta 2>&1")
        assert status == 7, output
        assert machine.succeed("stat -c '%a %U' /run/fleet /run/fleet/controller.sock").split("\n")[:2] == ["700 root", "600 root"]
        print(machine.succeed("fleet stop shop-beta"))
        machine.fail("systemctl is-active fleet-service@shop-beta.service")
        restart_controller()
        machine.fail("systemctl is-active fleet-service@shop-beta.service")
        assert json.loads(machine.succeed("cat /var/lib/fleet/routes.json")) == []
        assert "stopped" in machine.succeed("fleet status")
        # A deploy that fails rolls back to the previous generation without starting it.
        assert put("shop-beta", spec("${bundles.unhealthy}"))["outcome"] == "rolled-back"
        machine.fail("systemctl is-active fleet-service@shop-beta.service")
        assert put("shop-beta", spec("${bundles.second}"))["outcome"] == "active"
        assert info()["revision"] == "2222222"
        preview = spec("${bundles.second}", endpoint=None, memory={"max": "256M"}, database={"dropOnDelete": True})
        assert put("shop-pr-3", preview, owner=PREVIEW)["outcome"] == "active"
        status, answer = call("DELETE", "shop-pr-3", {})
        assert status == 400, "over TCP a deletion names its owner"
        print(machine.succeed("fleet delete shop-pr-3"))
        assert sql("SELECT count(*) FROM pg_database WHERE datname = 'fleet-shop-pr-3'") == "0"
        machine.succeed("ls /var/backup/fleet/deleted/fleet-shop-pr-3-*.dump")

    with subtest("a secret that can't be decrypted keeps the credentials the service has"):
        pid = main_pid()
        machine.succeed("mv /etc/fleet-test/key.txt /root/key.txt")
        restart_controller()
        machine.wait_until_succeeds("journalctl -u fleet-controller.service | grep -q 'shop-beta: keeps its credentials'")
        assert main_pid() == pid
        assert info()["smtpPassword"] == "from-sops"
        machine.succeed("mv /root/key.txt /etc/fleet-test/key.txt")
        restart_controller()

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
        # The rolled-back revisions' prepare stays applied, which is why migrations expand and contract.
        assert "console of 2222222 as fleet-shop-beta: check --verbose\n1111111,2222222,3333333,5555555" in console, console

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
