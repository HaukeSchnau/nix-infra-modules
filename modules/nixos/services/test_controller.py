import hashlib
import hmac
import json
import socket
import tempfile
import threading
import unittest
from pathlib import Path
from unittest import mock

import controller as fleet
from controller import Refused, check, grant_of, unit_quote

BUNDLE = "/nix/store/" + "a" * 32 + "-bundle"
NODE = "/nix/store/" + "b" * 32 + "-nodejs-26.4.0"
POSTGRES = {"major": 18, "free": 200, "connectionLimit": 40}
GRANT = {
    "hostNames": ["*.shop.example.net"],
    "public": False,
    "services": 2,
    "memoryMax": "1G",
    "secretPrefixes": ["projects/shop/"],
    "databases": True,
}


def spec(**fields):
    return {
        "release": {"revision": "abc1234", "paths": {"bundle": BUNDLE, "node": NODE}},
        "command": ["{node}/bin/node", "{bundle}/server.mjs"],
        "health": {"path": "/ready"},
        "memory": {"max": "512M"},
        **fields,
    }


def reasons(value, others=(), claimed=None, grant=GRANT, grant_name="shop", postgres=POSTGRES):
    try:
        check(f"{grant_name}-beta", grant_name, grant, value, list(others), claimed or {}, postgres)
    except Refused as refused:
        return refused.reasons
    return []


class Grants(unittest.TestCase):
    def test_a_service_belongs_to_the_grant_it_is_named_after(self):
        grants = {"shop": GRANT, "blog": GRANT}
        self.assertEqual(grant_of("shop", grants)[0], "shop")
        self.assertEqual(grant_of("shop-pr-12", grants)[0], "shop")
        self.assertEqual(grant_of("shopping", grants), (None, None))

    def test_a_valid_spec_is_kept_with_its_defaults(self):
        kept = check("shop-beta", "shop", GRANT, spec(database={}), [], {}, POSTGRES)
        self.assertEqual(kept["health"], {"path": "/ready", "timeoutSec": 60})
        self.assertEqual(kept["database"], {"env": "DATABASE_URL", "dropOnDelete": False, "connections": 40})
        self.assertIsNone(kept["prepare"])

    def test_hostnames_stay_within_the_grant_and_are_not_shared(self):
        self.assertIn("shop may not claim shop.example.net", reasons(spec(endpoint={"hostName": "shop.example.net"})))
        self.assertIn(
            "beta.shop.example.net belongs to the service shop-prod",
            reasons(spec(endpoint={"hostName": "beta.shop.example.net"}), claimed={"beta.shop.example.net": "shop-prod"}),
        )
        self.assertIn("shop may not be public", reasons(spec(endpoint={"hostName": "beta.shop.example.net", "visibility": "public"})))

    def test_secrets_read_only_keys_under_the_grant_prefixes(self):
        self.assertEqual(reasons(spec(secrets={"API_KEY": {"sops": "projects/shop/api-key"}, "OTHER": {"value": "x"}})), [])
        self.assertIn(
            "secret API_KEY names a SOPS key outside projects/shop/, which shop may read",
            reasons(spec(secrets={"API_KEY": {"sops": "projects/blog/key"}})),
        )
        self.assertIn("secret API_KEY has an empty value or a NUL", reasons(spec(secrets={"API_KEY": {"value": ""}})))

    def test_refusals_never_quote_a_secret(self):
        refused = reasons(spec(secrets={
            "A": {"sops": "hunter2-value"},
            "B": {"sops": "not a key/with spaces"},
            "C": "plain-string-secret",
            "D": {"value": "x", "sops": "two-sources-secret"},
        }))
        self.assertEqual(len(refused), 4, refused)
        for secret in ("hunter2-value", "not a key", "plain-string-secret", "two-sources-secret"):
            self.assertFalse(any(secret in reason for reason in refused), refused)

    def test_services_share_the_grant_memory_and_count(self):
        self.assertIn("memory max 768M is above what is left of shop's 1G: its other services take 512M", reasons(spec(memory={"max": "768M"}), others=[spec()]))
        self.assertIn("shop shares 1G between its services, so each sets memory max", reasons(spec(memory={})))
        self.assertIn("shop may run 2 services, and runs 2 others", reasons(spec(memory={"max": "1M"}), others=[spec(memory={"max": "1M"})] * 2))

    def test_commands_start_in_a_release_path(self):
        self.assertIn("command names {web}, which is not one of the release's paths", reasons(spec(command=["{web}/bin/server"])))
        self.assertIn(
            "command starts with a file in one of the release's paths, such as {bundle}/bin/server",
            reasons(spec(command=["/bin/sh", "-c", "evil"])),
        )

    def test_the_host_sets_its_own_variables(self):
        self.assertEqual(
            reasons(spec(database={}, secrets={"API_KEY": {"value": "x"}}, env={"PORT": "1", "DATABASE_URL": "x", "API_KEY_FILE": "x"})),
            ["env may not set API_KEY_FILE, which the host sets", "env may not set DATABASE_URL, which the host sets", "env may not set PORT, which the host sets"],
        )

    def test_databases_need_the_grant_the_major_version_and_connections(self):
        self.assertIn("blog may not have databases", reasons(spec(database={}), grant={**GRANT, "databases": False}, grant_name="blog"))
        self.assertIn("the service needs PostgreSQL 17, and this host runs 18", reasons(spec(database={"majorVersion": 17})))
        self.assertIn(
            "the database asks for 40 connections, and this host's PostgreSQL has 30 left",
            reasons(spec(database={}), postgres={**POSTGRES, "free": 30}),
        )
        self.assertEqual(reasons(spec(database={"connections": 30}), postgres={**POSTGRES, "free": 30}), [])

    def test_revocations_are_told_apart_from_capacity(self):
        try:
            check("shop-beta", "shop", {**GRANT, "public": False, "services": 1}, spec(
                endpoint={"hostName": "beta.shop.example.net", "visibility": "public"},
                secrets={"K": {"sops": "projects/other/k"}},
            ), [spec()], {}, POSTGRES)
        except Refused as refused:
            self.assertEqual(refused.revoked, ["shop may not be public", "secret K names a SOPS key outside projects/shop/, which shop may read"])
            self.assertIn("shop may run 1 services, and runs 1 others", refused.reasons)


class Host(unittest.TestCase):
    """The controller against a state directory in /tmp, with systemd and PostgreSQL stubbed."""

    def setUp(self):
        directory = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: __import__("shutil").rmtree(directory, ignore_errors=True))
        fleet.CONFIG.clear()
        fleet.CONFIG.update({
            "stateDir": str(directory / "state"),
            "runtimeDir": str(directory / "run"),
            "unitsDir": str(directory / "units"),
            "gcrootsDir": str(directory / "gcroots"),
            "routesFile": str(directory / "state" / "routes.json"),
            "backupDir": str(directory / "backup"),
            "portRange": {"from": 18300, "to": 18399},
            "addresses": {"ipv4": None, "ipv6": None},
            "postgresql": None,
            "grants": {"shop": dict(GRANT)},
        })
        self.calls = []
        self.state = ("active", "running")
        for name, stub in {
            "systemctl": lambda *args, check=True: self.calls.append(args),
            "unit_state": lambda name: self.state,
        }.items():
            patcher = mock.patch.object(fleet, name, stub)
            patcher.start()
            self.addCleanup(patcher.stop)
        self.controller = fleet.Controller()

    def put(self, name, value, owner=None, healthy=True, **extra):
        """A PUT whose deploy runs at once, with the deploy's host work stubbed."""
        body = {**value, "owner": owner or {"stack": "Shop", "stage": "beta", "fqn": "Server"}, **extra}
        with mock.patch.object(fleet.threading, "Thread") as thread:
            status, _ = self.controller.put(name, body)
        if status == 202:
            _, record, plain = thread.call_args.kwargs["args"]
            stubs = {
                "realize": lambda *_: None, "ensure_database": lambda *_: None, "secret_values": lambda *_: {},
                "prepare": lambda *_: None, "cutover": lambda *_: None, "invocation": lambda _: "",
                "healthy": lambda *_: None if healthy else "unhealthy",
            }
            with mock.patch.multiple(fleet, **stubs):
                self.controller.deploy(name, record, plain)
        return fleet.deploys(name)[0]["outcome"] if fleet.deploys(name) else status

    def generation(self, name, generation, value, active=False):
        record = {"generation": generation, "spec": check(name, "shop", {**GRANT, "public": True, "services": 9, "memoryMax": "9G"}, value, [], {}, POSTGRES, stored=True)}
        fleet.write_atomic(fleet.service_dir(name) / "generations" / f"{generation}.json", fleet.dumps(record))
        if active:
            fleet.write_atomic(fleet.service_dir(name) / "active", f"{generation}\n")
        return record

    def test_a_deploying_service_counts_both_generations(self):
        self.generation("shop", 1, spec(memory={"max": "768M"}, endpoint={"hostName": "a.shop.example.net"}), active=True)
        self.generation("shop", 2, spec(memory={"max": "256M"}, endpoint={"hostName": "b.shop.example.net"}))
        with self.assertRaises(Refused) as refused:
            self.controller.check("shop-pr-1", spec(memory={"max": "768M"}, endpoint={"hostName": "a.shop.example.net"}))
        self.assertIn("a.shop.example.net belongs to the service shop", refused.exception.reasons)
        self.assertIn("memory max 768M is above what is left of shop's 1G: its other services take 768M", refused.exception.reasons)

    def test_restore_keeps_services_running_when_the_grant_shrinks(self):
        self.generation("shop", 1, spec(), active=True)
        self.generation("shop-pr-1", 1, spec(), active=True)
        fleet.CONFIG["grants"] = {"shop": {**GRANT, "services": 1, "memoryMax": "768M"}}
        with mock.patch.object(fleet, "secret_values", lambda spec, plain=None: {}):
            self.controller.restore()
        self.assertFalse([call for call in self.calls if call[0] == "stop" and call[1].startswith("fleet-service@")], self.calls)
        self.assertIn("shop may run 1 services, and runs 1 others", fleet.violations("shop"))
        self.assertTrue(fleet.violations("shop-pr-1"))

    def test_restore_keeps_credentials_when_a_secret_cannot_be_decrypted(self):
        record = self.generation("shop", 1, spec(secrets={"SMTP_PASSWORD": {"sops": "projects/shop/smtp"}}), active=True)
        fleet.write_credentials("shop", 1, {"SMTP_PASSWORD": "old"})
        fleet.write_dropin("shop", record)

        def broken(key):
            raise fleet.Failed(f"{key} can't be decrypted from this host's secrets")

        with mock.patch.object(fleet, "decrypt", broken):
            self.assertEqual(self.controller.restore(), 1)
        self.assertEqual((fleet.credentials_dir("shop", 1) / "SMTP_PASSWORD").read_text(), "old")
        self.assertFalse([call for call in self.calls if call[0] in ("stop", "restart")], self.calls)

    def test_a_failure_after_the_cutover_restores_the_previous_generation(self):
        previous = self.generation("shop", 1, spec(), active=True)
        candidate = self.generation("shop", 2, spec(release={"revision": "def5678", "paths": {"bundle": BUNDLE, "node": NODE}}))
        cutovers = []

        def cutover(name, record):
            cutovers.append(record["generation"])
            if record["generation"] == 2:
                raise RuntimeError("daemon-reload timed out")

        stubs = {"realize": lambda *_: None, "secret_values": lambda *_: {}, "prepare": lambda *_: None, "cutover": cutover}
        with mock.patch.multiple(fleet, **stubs):
            self.controller.busy.add("shop")
            self.controller.deploy("shop", candidate, {})
        self.assertEqual(cutovers, [2, previous["generation"]])
        outcome = fleet.deploys("shop")[0]
        self.assertEqual((outcome["outcome"], outcome["reason"]), ("rolled-back", "the controller failed after the cutover: daemon-reload timed out"))
        self.assertEqual(fleet.active_generation("shop"), 1)

    def test_a_reply_that_is_not_http_is_unhealthy(self):
        server = socket.socket()
        server.bind(("127.0.0.1", 0))
        server.listen(1)
        self.addCleanup(server.close)

        def answer():
            connection, _ = server.accept()
            connection.recv(1024)
            connection.sendall(b"garbage\r\n\r\n")
            connection.close()

        threading.Thread(target=answer, daemon=True).start()
        self.assertIn("BadStatusLine", fleet.probe(f"http://127.0.0.1:{server.getsockname()[1]}/ready"))

    def test_a_fence_outlives_the_deletion(self):
        self.generation("shop-pr-1", 1, spec(), active=True)
        self.controller.fence("shop-pr-1", 50)
        self.assertTrue(self.controller.delete("shop-pr-1", None, None)["deleted"])
        with self.assertRaises(fleet.Stale):
            self.controller.fence("shop-pr-1", 49)

    def test_a_database_is_dropped_only_when_every_accepted_spec_says_so(self):
        fleet.CONFIG["postgresql"] = {"major": 18, "free": 200, "connectionLimit": 40, "maxConnections": 210}
        dropped = []
        prod = {"stack": "Shop", "stage": "prod", "fqn": "Server"}
        preview = {"stack": "Shop", "stage": "pr-12", "fqn": "Server"}
        with mock.patch.object(fleet, "drop_database", dropped.append):
            # A preview whose first deploy never went healthy still drops the database it created.
            self.assertEqual(self.put("shop-pr-12", spec(database={"dropOnDelete": True}), owner=preview, healthy=False), "failed")
            self.controller.delete("shop-pr-12", None, preview)
            # Prod adopted by a stack that asks for dropOnDelete keeps its database.
            self.assertEqual(self.put("shop", spec(database={}), owner=prod), "active")
            self.assertEqual(self.put("shop", spec(database={"dropOnDelete": True}), owner=preview, adopt=True), "active")
            self.assertFalse(self.controller.delete("shop", None, preview)["databaseDropped"])
        self.assertEqual(dropped, ["shop-pr-12"])

    def test_restore_stops_a_service_whose_grant_revokes_a_permission(self):
        public = spec(endpoint={"hostName": "www.shop.example.net", "visibility": "public"})
        self.generation("shop", 1, public, active=True)
        fleet.CONFIG["grants"]["shop"] = {**GRANT, "public": False, "hostNames": []}
        with mock.patch.object(fleet, "secret_values", lambda *_: {}):
            self.controller.restore()
            self.assertIn(("stop", "fleet-service@shop.service"), self.calls)
            self.assertEqual(json.loads(Path(fleet.CONFIG["routesFile"]).read_text()), [])
            self.assertEqual(fleet.stopped("shop")["by"], "grant")
            fleet.CONFIG["grants"] = {}
            self.calls.clear()
            self.controller.restore()
            self.assertIn(("stop", "fleet-service@shop.service"), self.calls)
            fleet.CONFIG["grants"] = {"shop": {**GRANT, "public": True}}
            self.calls.clear()
            self.state = ("inactive", "dead")
            self.controller.restore()
        self.assertIsNone(fleet.stopped("shop"))
        self.assertIn(("restart", "fleet-service@shop.service"), self.calls)
        self.assertEqual(len(json.loads(Path(fleet.CONFIG["routesFile"]).read_text())), 1)

    def test_an_operator_stop_holds_until_the_next_deploy(self):
        self.assertEqual(self.put("shop", spec(endpoint={"hostName": "a.shop.example.net"})), "active")
        self.controller.stop("shop")
        self.assertIn(("stop", "fleet-service@shop.service"), self.calls)
        self.state = ("inactive", "dead")
        self.calls.clear()
        with mock.patch.object(fleet, "secret_values", lambda *_: {}):
            self.controller.restore()
        self.assertFalse([call for call in self.calls if call[0] in ("start", "restart")], self.calls)
        self.assertEqual(json.loads(Path(fleet.CONFIG["routesFile"]).read_text()), [])
        self.assertEqual(self.put("shop", spec(endpoint={"hostName": "a.shop.example.net"})), "active")
        self.assertIsNone(fleet.stopped("shop"))

    def test_a_rollback_that_fails_too_is_broken_not_rolled_back(self):
        self.assertEqual(self.put("shop", spec()), "active")

        def cutover(*_):
            raise RuntimeError("daemon-reload timed out")

        with mock.patch.object(fleet, "threading") as threading:
            self.controller.put("shop", {**spec(release={"revision": "def5678", "paths": {"bundle": BUNDLE, "node": NODE}}), "owner": {"stack": "Shop", "stage": "beta", "fqn": "Server"}})
        _, record, plain = threading.Thread.call_args.kwargs["args"]
        stubs = {"realize": lambda *_: None, "secret_values": lambda *_: {}, "prepare": lambda *_: None, "cutover": cutover}
        with mock.patch.multiple(fleet, **stubs):
            self.controller.deploy("shop", record, plain)
        outcome = fleet.deploys("shop")[0]
        self.assertEqual(outcome["outcome"], "broken")
        self.assertTrue(outcome["reason"].endswith("restoring the previous generation failed too: daemon-reload timed out"), outcome)

    def test_another_owner_deletes_nothing(self):
        self.generation("shop-beta", 1, spec(), active=True)
        beta = {"stack": "Shop", "stage": "beta", "fqn": "Server"}
        fleet.write_atomic(fleet.service_dir("shop-beta") / "owner.json", fleet.dumps(beta))
        result = self.controller.delete("shop-beta", None, {**beta, "stage": "pr-12"})
        self.assertFalse(result["deleted"])
        self.assertTrue(fleet.service_dir("shop-beta").is_dir())
        self.assertFalse(self.calls)

    def test_an_empty_token_authorizes_nothing(self):
        directory = Path(fleet.CONFIG["stateDir"])
        directory.mkdir(parents=True, exist_ok=True)
        (directory / "token").write_text("\n")
        (directory / "key").write_text("")
        fleet.CONFIG.update({"tokenFile": str(directory / "token"), "grantKeyFile": str(directory / "key")})
        self.assertFalse(fleet.authorized("Bearer ", "shop-beta"))
        self.assertFalse(fleet.authorized("Bearer " + hmac.new(b"", b"shop", hashlib.sha256).hexdigest(), "shop-beta"))
        (directory / "key").write_text("key")
        self.assertTrue(fleet.authorized("Bearer " + hmac.new(b"key", b"shop", hashlib.sha256).hexdigest(), "shop-beta"))


class Quoting(unittest.TestCase):
    def test_unit_words_keep_quotes_percent_signs_and_dollars(self):
        self.assertEqual(unit_quote('a "b" %c $d \\e'), '"a \\"b\\" %%c $d \\\\e"')
        self.assertEqual(unit_quote("$HOME", dollar=True), '"$$HOME"')


if __name__ == "__main__":
    unittest.main()
