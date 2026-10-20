import json
import os
import tempfile
import unittest
from pathlib import Path

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
            "policy.json": {"descriptor": {}, "managedJobs": [], "bindings": {"parameters": {"otlp": "http://o", "title": "Old"}, "secrets": ["session"], "resources": {}}},
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
        self.assertEqual(bound["secrets"]["session"], "/run/secrets/session")
        self.assertTrue(bound["secrets"]["apiKey"].endswith("/shop/credentials/apiKey"))
        self.assertEqual(bound["runtime"]["endpoints"]["web"]["url"], "https://shop.example.org")
        self.assertEqual(bound["runtime"]["endpoints"]["web"]["visibility"], "public")
        self.assertEqual(bound["runtime"]["endpoints"]["web"]["listen"], {"port": 18200})

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


if __name__ == "__main__":
    unittest.main()
