import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import placements

GRANT = {"hostNames": ["shop.example.org", "*.shop.example.net"], "public": True, "secretPrefix": "projects/shop/", "memoryMax": "1G"}


def reasons(placement, grant=GRANT):
    try:
        placements.check("shop", grant, placement)
    except placements.Refused as refused:
        return refused.reasons
    return []


class CheckTests(unittest.TestCase):
    def test_a_placement_within_the_grant_is_stored_normalized(self):
        stored = placements.check("shop", GRANT, {
            "endpoint": {"hostName": "Shop.Example.org", "visibility": "public"},
            "secrets": {"apiKey": "projects/shop/api-key"},
            "parameters": {"title": "Shop"},
            "memory": {"max": "512M"},
        })
        self.assertEqual(stored["endpoint"], {"hostName": "shop.example.org", "visibility": "public"})
        self.assertEqual(stored["secrets"], {"apiKey": "projects/shop/api-key"})

    def test_a_suffix_allows_names_below_it_but_not_itself(self):
        self.assertEqual(reasons({"endpoint": {"hostName": "beta.shop.example.net"}}), [])
        self.assertEqual(reasons({"endpoint": {"hostName": "shop.example.net"}}), ["shop may not claim shop.example.net"])

    def test_every_breach_of_the_grant_is_named(self):
        self.assertEqual(reasons({
            "endpoint": {"hostName": "other.example.org", "visibility": "public"},
            "secrets": {"apiKey": "projects/other/api-key"},
            "memory": {"max": "2G"},
            "colour": "red",
        }), [
            "unknown field colour",
            "shop may not claim other.example.org",
            "apiKey may not read projects/other/api-key; shop reads keys under projects/shop/",
            "memory max 2G is above shop's ceiling of 1G",
        ])

    def test_public_and_memory_need_the_grant_to_allow_them(self):
        tailnet_only = {**GRANT, "public": False, "memoryMax": None}
        self.assertEqual(reasons({"endpoint": {"hostName": "shop.example.org", "visibility": "public"}, "memory": {"high": "256M"}}, tailnet_only), [
            "shop may not be public",
            "shop's grant sets no memory ceiling, so its placement sets no memory",
        ])

    def test_sizes_and_keys_are_checked_for_form(self):
        self.assertEqual(reasons({"secrets": {"apiKey": 'projects/shop/"] | x'}, "memory": {"max": "lots"}}), [
            "apiKey reads 'projects/shop/\"] | x', which is not a SOPS key such as projects/shop/apiKey",
            "memory max 'lots' is not a size such as 512M or 1G",
        ])

    def test_a_job_schedule_is_checked_against_the_jobs_and_systemd(self):
        jobs = {"backup": {}, "sync": {}}
        stored = placements.check("shop", GRANT, {"jobs": {"backup": {"calendar": "*-*-* 04:00", "randomizedDelaySec": "30min"}}}, jobs)
        self.assertEqual(stored["jobs"], {"backup": {"calendar": "*-*-* 04:00", "randomizedDelaySec": "30min"}})
        try:
            placements.check("shop", GRANT, {"jobs": {
                "backup": {"calendar": "when it suits"},
                "sync": {"interval": "10min", "calendar": "daily"},
                "report": {"interval": "1h"},
            }}, jobs)
        except placements.Refused as refused:
            self.assertEqual(refused.reasons, [
                "job backup: 'when it suits' is not a systemd calendar such as *-*-* 04:00",
                "shop has no scheduled job report on this host",
                "job sync takes a calendar or an interval, and randomizedDelaySec",
            ])
        else:
            self.fail("refused nothing")

    def test_a_schedule_cannot_smuggle_settings_into_the_timer(self):
        self.assertFalse(placements.valid_schedule("timespan", "10min\nExecStart=/bin/sh"))


class TokenTests(unittest.TestCase):
    def test_a_project_token_opens_only_its_own_placement(self):
        key = b"secret key"
        token = placements.token_for(key, "shop")
        self.assertTrue(placements.authorized(f"Bearer {token}", "shop", key, "admin"))
        self.assertFalse(placements.authorized(f"Bearer {token}", "blog", key, "admin"))
        self.assertTrue(placements.authorized("Bearer admin", "blog", key, "admin"))
        self.assertFalse(placements.authorized(f"Bearer {token}", "shop", None, "admin"))


class BindingTests(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        files = {
            "policy.json": {
                "descriptor": {"requirements": {"apiKey": {"kind": "secret", "realizations": ["release"]}}},
                "managedJobs": [],
                "bindings": {"parameters": {"otlp": "http://o", "title": "Old"}, "secrets": ["session"], "resources": {}},
            },
            "secrets.json": {"session": "/run/secrets/session"},
            "runtime.json": {"endpoints": {"web": {"url": "https://old.example.org", "hostNames": ["old.example.org"], "visibility": "tailnet", "listen": {"port": 18200}}}},
        }
        for name, value in files.items():
            (self.dir / name).write_text(json.dumps(value))
        self.app = {
            "requestedReleaseFile": str(self.dir / "requested-release.json"),
            "placement": {
                "grant": GRANT, "port": 18200, "stateDir": str(self.dir), "action": "web",
                "policy": str(self.dir / "policy.json"), "secretBindings": str(self.dir / "secrets.json"),
                "runtimeBase": str(self.dir / "runtime.json"), "site": "/etc/app-deployments/sites/shop.caddy",
                "credentialUnits": ["app-deployment-shop.service"],
            },
        }

    def test_the_placement_adds_to_the_host_bindings_and_moves_the_endpoint(self):
        stored = placements.check("shop", GRANT, {
            "endpoint": {"hostName": "shop.example.org", "visibility": "public"},
            "secrets": {"apiKey": "projects/shop/api-key"},
            "parameters": {"title": "Shop"},
        })
        bound = placements.bindings("shop", self.app, stored)
        self.assertEqual(bound["policy"]["bindings"]["parameters"], {"otlp": "http://o", "title": "Shop"})
        self.assertEqual(bound["policy"]["bindings"]["secrets"], ["apiKey", "session"])
        self.assertEqual(bound["policy"]["bindings"]["resources"], {"apiKey": {"kind": "secret", "credential": "apiKey"}})
        self.assertEqual(bound["secrets"]["session"], "/run/secrets/session")
        self.assertTrue(bound["secrets"]["apiKey"].endswith("/shop/credentials/apiKey"))
        self.assertEqual(bound["runtime"]["endpoints"]["web"]["url"], "https://shop.example.org")
        self.assertEqual(bound["runtime"]["endpoints"]["web"]["visibility"], "public")
        self.assertEqual(bound["runtime"]["endpoints"]["web"]["listen"], {"port": 18200})

    def test_the_placement_policy_applies_once_it_exists(self):
        self.app["bindingPolicyFile"] = "/nix/store/compiled-policy.json"
        self.assertEqual(placements.policy_file(self.app), "/nix/store/compiled-policy.json")
        stored = placements.check("shop", GRANT, {"secrets": {"apiKey": "projects/shop/api-key"}})
        placements.write_bound(self.app, stored, placements.bindings("shop", self.app, stored))
        self.assertEqual(placements.policy_file(self.app), str(self.dir / "placement" / "policy.json"))

    def test_routes_list_placed_releases_with_their_site(self):
        (self.dir / "placement").mkdir()
        (self.dir / "placement" / "placement.json").write_text(json.dumps(
            {"endpoint": {"hostName": "shop.example.org", "visibility": "public"}, "secrets": {}, "parameters": {}, "memory": {}}
        ))
        placements.ROUTES_FILE = self.dir / "routes.json"
        placements.write_routes({"shop": self.app, "blog": {"placement": None}})
        self.assertEqual(json.loads(placements.ROUTES_FILE.read_text()), [{
            "name": "shop", "hostName": "shop.example.org", "visibility": "public", "upstreamPort": 18200,
            "site": "/etc/app-deployments/sites/shop.caddy",
        }])


class RestoreTests(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        placements.ROUTES_FILE = self.dir / "routes.json"
        placements.CREDENTIALS = self.dir / "run"
        placements.UNITS = self.dir / "units"
        self.policy = {"descriptor": {}, "managedJobs": [], "bindings": {"parameters": {"otlp": "http://old"}, "secrets": [], "resources": {}}}
        files = {
            "policy.json": self.policy,
            "secrets.json": {},
            "runtime.json": {"endpoints": {"web": {"listen": {"port": 18200}}}},
        }
        for name, value in files.items():
            (self.dir / name).write_text(json.dumps(value))
        (self.dir / "current-revision").write_text("abc\n")
        (self.dir / "current").symlink_to(self.dir)
        self.app = {
            "deliveryMode": "source",
            "requestedReleaseFile": str(self.dir / "requested-release.json"),
            "requestedRevisionFile": str(self.dir / "requested-revision"),
            "updateUnit": "app-deployment-shop-update.service",
            "placement": {
                "grant": GRANT, "port": 18200, "stateDir": str(self.dir), "action": "web",
                "policy": str(self.dir / "policy.json"), "secretBindings": str(self.dir / "secrets.json"),
                "runtimeBase": str(self.dir / "runtime.json"), "site": "/etc/app-deployments/sites/shop.caddy",
                "credentialUnits": ["app-deployment-shop.service"],
            },
        }
        stored = placements.check("shop", GRANT, {"endpoint": {"hostName": "shop.example.org", "visibility": "public"}, "parameters": {"title": "Shop"}})
        placements.write_bound(self.app, stored, placements.bindings("shop", self.app, stored))

    def restore(self):
        with mock.patch.object(placements.subprocess, "run") as run:
            failures = placements.restore({"shop": self.app})
        return failures, [call.args[0] for call in run.call_args_list]

    def test_a_switch_that_changes_the_host_bindings_rebinds_and_redeploys(self):
        self.policy["bindings"]["parameters"]["otlp"] = "http://new"
        (self.dir / "policy.json").write_text(json.dumps(self.policy))
        failures, commands = self.restore()
        bound = json.loads((self.dir / "placement" / "policy.json").read_text())
        self.assertEqual((failures, bound["bindings"]["parameters"]), (0, {"otlp": "http://new", "title": "Shop"}))
        self.assertIn(["systemctl", "start", "--no-block", "app-deployment-shop-update.service"], commands)
        # A source-delivered release reads its request from the revision file; a release file would outlive it.
        self.assertEqual((self.dir / "requested-revision").read_text(), "abc\n")
        self.assertFalse((self.dir / "requested-release.json").exists())

    def test_a_boot_rewrites_run_without_redeploying(self):
        failures, commands = self.restore()
        self.assertEqual(failures, 0)
        self.assertTrue((self.dir / "units" / "app-deployment-shop.service.d" / "50-placement.conf").is_file())
        self.assertNotIn("start", [word for command in commands for word in command])

    def test_an_unchanged_placement_neither_redeploys_nor_restarts(self):
        self.restore()
        _, commands = self.restore()
        self.assertEqual(commands, [["systemctl", "daemon-reload"]])

    def test_a_placement_the_grant_no_longer_allows_is_deleted(self):
        self.app["placement"]["grant"] = {**GRANT, "hostNames": ["other.example.org"]}
        failures, commands = self.restore()
        self.assertEqual(failures, 1)
        self.assertFalse((self.dir / "placement").exists())
        self.assertEqual(json.loads(placements.ROUTES_FILE.read_text()), [])
        self.assertIn(["systemctl", "start", "--no-block", "app-deployment-shop-update.service"], commands)


class ScheduleTests(unittest.TestCase):
    def setUp(self):
        placements.UNITS = Path(tempfile.mkdtemp())
        self.app = {"placement": {"jobs": {
            "backup": {"timer": "app-deployment-shop-job-backup.timer", "onBootSec": "5min", "cadence": "fixed"},
            "sync": {"timer": "app-deployment-shop-job-sync.timer", "onBootSec": "1min", "cadence": "spaced"},
        }}}

    def dropin(self, job):
        return placements.UNITS / f"app-deployment-shop-job-{job}.timer.d" / "50-placement.conf"

    def test_an_interval_replaces_the_timer_as_the_host_compiles_one(self):
        changed = placements.schedule(self.app, {"jobs": {"backup": {"interval": "10min", "randomizedDelaySec": "30s"}}})
        self.assertEqual(changed, ["app-deployment-shop-job-backup.timer"])
        self.assertEqual(self.dropin("backup").read_text().splitlines(), [
            "[Timer]", "OnCalendar=", "OnActiveSec=", "OnUnitActiveSec=", "OnUnitInactiveSec=",
            "OnActiveSec=5min", "OnUnitActiveSec=10min", "OnUnitInactiveSec=10min", "RandomizedDelaySec=30s",
        ])
        self.assertFalse(self.dropin("sync").exists())

    def test_dropping_a_schedule_gives_the_timer_its_compiled_one_back(self):
        placements.schedule(self.app, {"jobs": {"sync": {"calendar": "hourly"}}})
        self.assertEqual(placements.schedule(self.app, {"jobs": {"sync": {"calendar": "hourly"}}}), [])
        self.assertEqual(placements.schedule(self.app, {"jobs": {}}), ["app-deployment-shop-job-sync.timer"])
        self.assertFalse(self.dropin("sync").exists())


if __name__ == "__main__":
    unittest.main()
