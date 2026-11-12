import http.client
import json
import os
import sys
import tempfile
import threading
import unittest
from pathlib import Path

STATE = Path(tempfile.mkdtemp())
TOKEN = STATE / "token"
TOKEN.write_text("secret\n")
APPS = {
    "shop": {
        "bindingPolicyFile": "",
        "compatibilityFile": str(STATE / "shop" / "compatibility.json"),
        "deliveryMode": "cache",
        "requestedReleaseFile": str(STATE / "shop" / "requested-release.json"),
        "requestedRevisionFile": str(STATE / "shop" / "requested-revision"),
        "updateUnit": "",
        # The update records the request it found, and fails while STATE/fail exists.
        "updateCommand": [
            sys.executable, "-c",
            "import shutil, sys; shutil.copy(sys.argv[1], sys.argv[2]); sys.exit(1 if __import__('os').path.exists(sys.argv[3]) else 0)",
            str(STATE / "shop" / "requested-release.json"), str(STATE / "updated.json"), str(STATE / "fail"),
        ],
        # An update runs while STATE/running exists; each probe counts down one of its lines.
        "updateRunningCommand": [
            sys.executable, "-c",
            "import sys; from pathlib import Path; p = Path(sys.argv[1]); lines = p.read_text().splitlines() if p.exists() else [];"
            " p.write_text(''.join(l + '\\n' for l in lines[1:])) if lines else None; sys.exit(0 if lines else 1)",
            str(STATE / "running"),
        ],
        "placement": None,
    },
}
(STATE / "apps.json").write_text(json.dumps(APPS))
os.environ.update({
    "APP_DEPLOYMENTS_APPS_FILE": str(STATE / "apps.json"),
    "APP_DEPLOYMENTS_TOKEN_FILE": str(TOKEN),
    "APP_DEPLOYMENTS_SYSTEM": "aarch64-darwin",
})

import webhook  # noqa: E402

STORE_PATH = "/nix/store/" + "a" * 32 + "-shop"


class WebhookTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = webhook.ThreadingHTTPServer(("127.0.0.1", 0), webhook.Handler)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def setUp(self):
        for name in ("updated.json", "fail", "running", "shop/compatibility.json", "shop/requested-release.json", "shop/fence"):
            (STATE / name).unlink(missing_ok=True)

    def request(self, method, path, body=None, token="secret"):
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_address[1])
        headers = {"Authorization": f"Bearer {token}"}
        connection.request(method, path, body=None if body is None else json.dumps(body), headers=headers)
        response = connection.getresponse()
        return response.status, json.loads(response.read())

    def deploy(self, **extra):
        return self.request("POST", "/deploy/shop", {"revision": "abcdef1", "storePath": STORE_PATH, "source": "ci", **extra})

    def test_health_names_the_apps_and_the_host_system(self):
        self.assertEqual(self.request("GET", "/health"), (200, {"ok": True, "apps": ["shop"], "system": "aarch64-darwin"}))

    def test_a_deploy_queues_the_release_and_runs_the_update(self):
        status, body = self.deploy(fence=3)
        self.assertEqual(status, 202)
        self.assertEqual(body, {"accepted": True, "app": "shop", "revision": "abcdef1", "storePath": STORE_PATH})
        self.assertEqual(json.loads((STATE / "updated.json").read_text()), {
            "schemaVersion": 1, "revision": "abcdef1", "storePath": STORE_PATH, "source": "ci",
        })

    def test_a_deploy_waits_for_a_running_update(self):
        (STATE / "running").write_text("1\n2\n")
        self.assertEqual(self.deploy()[0], 202)
        self.assertEqual((STATE / "running").read_text(), "")
        self.assertTrue((STATE / "updated.json").exists())

    def test_a_failed_update_is_busy_unless_the_release_is_incompatible(self):
        (STATE / "fail").touch()
        status, body = self.deploy()
        self.assertEqual((status, body["accepted"], body["exitCode"]), (503, False, 1))
        (STATE / "shop" / "compatibility.json").write_text(json.dumps({"compatible": False, "reasons": ["x"]}))
        self.assertEqual(self.deploy()[0], 409)

    def test_a_stale_fence_is_refused_before_anything_runs(self):
        self.assertEqual(self.deploy(fence=5)[0], 202)
        (STATE / "updated.json").unlink()
        self.assertEqual(self.deploy(fence=4), (409, {"error": "stale fence", "fence": 5}))
        self.assertFalse((STATE / "updated.json").exists())

    def test_requests_need_the_token_and_a_store_path(self):
        self.assertEqual(self.request("POST", "/deploy/shop", {}, token="wrong")[0], 403)
        self.assertEqual(self.deploy(storePath="/tmp/x")[0], 400)
        self.assertEqual(self.request("POST", "/deploy/shop", {"revision": "abcdef1"})[0], 400)


if __name__ == "__main__":
    unittest.main()
