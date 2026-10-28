import unittest

from controller import Refused, check, grant_of, unit_quote

BUNDLE = "/nix/store/" + "a" * 32 + "-bundle"
NODE = "/nix/store/" + "b" * 32 + "-nodejs-26.4.0"
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


def reasons(value, others=(), claimed=None, grant=GRANT, grant_name="shop"):
    try:
        check(f"{grant_name}-beta", grant_name, grant, value, list(others), claimed or {}, 18)
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
        kept = check("shop-beta", "shop", GRANT, spec(database={}), [], {}, 18)
        self.assertEqual(kept["health"], {"path": "/ready", "timeoutSec": 60})
        self.assertEqual(kept["database"], {"env": "DATABASE_URL"})
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
            "secret API_KEY may not read projects/blog/key; shop reads keys under projects/shop/",
            reasons(spec(secrets={"API_KEY": {"sops": "projects/blog/key"}})),
        )
        self.assertIn("secret API_KEY has an empty value or a NUL", reasons(spec(secrets={"API_KEY": {"value": ""}})))

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

    def test_databases_need_the_grant_and_the_major_version(self):
        self.assertIn("blog may not have databases", reasons(spec(database={}), grant={**GRANT, "databases": False}, grant_name="blog"))
        self.assertIn("the service needs PostgreSQL 17, and this host runs 18", reasons(spec(database={"majorVersion": 17})))


class Quoting(unittest.TestCase):
    def test_unit_words_keep_quotes_percent_signs_and_dollars(self):
        self.assertEqual(unit_quote('a "b" %c $d \\e'), '"a \\"b\\" %%c $d \\\\e"')
        self.assertEqual(unit_quote("$HOME", dollar=True), '"$$HOME"')


if __name__ == "__main__":
    unittest.main()
