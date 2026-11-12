"""The release host's webhook: CI promotes releases to the host through it.

It serves the same API on every release host. The apps file (APP_DEPLOYMENTS_APPS_FILE) gives each
app's state files and the platform's commands for its update: `updateCommand` runs one update and
exits once it ends, `updateRunningCommand` exits 0 while an update runs. NixOS starts and inspects
the app's update unit; nix-darwin runs the update script itself.

Placements (placements.py) are served for the apps whose host registered a grant.
"""

import json
import os
import re
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import placements

APPS_FILE = os.environ["APP_DEPLOYMENTS_APPS_FILE"]
TOKEN_FILE = os.environ["APP_DEPLOYMENTS_TOKEN_FILE"]
PLANNER = os.environ.get("APP_DEPLOYMENTS_PLANNER", "project-runtime")
SYSTEM = os.environ.get("APP_DEPLOYMENTS_SYSTEM")

with open(APPS_FILE, "r", encoding="utf-8") as handle:
    APPS = json.load(handle)


def read_token():
    with open(TOKEN_FILE, "r", encoding="utf-8") as handle:
        return handle.read().strip()


def placement_key():
    path = os.environ.get("APP_DEPLOYMENTS_PLACEMENT_KEY_FILE")
    if not path:
        return None
    with open(path, "rb") as handle:
        return handle.read().strip()


FENCE_LOCK = threading.Lock()


def read_text(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return handle.read().strip() or None
    except FileNotFoundError:
        return None


def accept_fence(state_dir, fence):
    """Records the highest fencing token seen; a lower one comes from a stale deploy lease."""
    path = os.path.join(state_dir, "fence")
    with FENCE_LOCK:
        current = int(read_text(path) or "0")
        if fence < current:
            return current
        os.makedirs(state_dir, exist_ok=True)
        with open(path + ".next", "w", encoding="utf-8") as handle:
            handle.write(str(fence) + "\n")
        os.replace(path + ".next", path)
        return None


def update_running(app):
    return subprocess.run(app["updateRunningCommand"], check=False, capture_output=True).returncode == 0


def app_status(app):
    state_dir = os.path.dirname(app["requestedReleaseFile"])
    current = os.path.join(state_dir, "current")
    revision_file = os.path.join(state_dir, "current-revision")
    pending = None
    try:
        with open(app["requestedReleaseFile"], "r", encoding="utf-8") as handle:
            pending = json.load(handle).get("revision")
    except (FileNotFoundError, json.JSONDecodeError):
        pass
    compatibility = None
    try:
        with open(app["compatibilityFile"], "r", encoding="utf-8") as handle:
            compatibility = json.load(handle)
    except (FileNotFoundError, json.JSONDecodeError):
        pass
    since = None
    if os.path.exists(revision_file):
        since = int(os.path.getmtime(revision_file) * 1000)
    return {
        "revision": read_text(revision_file),
        "storePath": os.path.realpath(current) if os.path.islink(current) else None,
        "previous": read_text(os.path.join(state_dir, "previous-revision")),
        "pending": pending,
        "since": since,
        "healthy": None if compatibility is None else bool(compatibility.get("compatible", True)),
    }


class Handler(BaseHTTPRequestHandler):
    server_version = "app-deployments-webhook"

    def log_message(self, fmt, *args):
        print("%s - %s" % (self.address_string(), fmt % args), flush=True)

    def send_json(self, status, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def placement_request(self, method):
        """Serves /placements/<project>[/plan]; True when the path was one of them."""
        match = re.fullmatch(r"/placements/([^/]+)(/plan)?", self.path)
        if match is None:
            return False
        project, planning = match[1], match[2] is not None
        allowed = {"GET": not planning, "PUT": not planning, "DELETE": not planning, "POST": planning}
        if not allowed.get(method):
            self.send_json(405, {"error": "method not allowed"})
            return True
        if not placements.authorized(self.headers.get("Authorization", ""), project, placement_key(), read_token()):
            self.send_json(403, {"error": "forbidden"})
            return True
        app = APPS.get(project)
        if app is None:
            self.send_json(404, {"error": "unknown app", "app": project})
            return True
        if method == "GET":
            stored = placements.get(app)
            self.send_json(200, stored) if stored is not None else self.send_json(404, {"error": "no placement"})
            return True
        if method == "DELETE":
            try:
                found = placements.delete(project, app, APPS)
            except placements.Refused as refused:
                self.send_json(422, {"error": "placement deleted, but the grant's default can't apply", "reasons": refused.reasons})
                return True
            self.send_json(200 if found else 404, {"project": project})
            return True
        length = int(self.headers.get("Content-Length", "0") or "0")
        try:
            body = json.loads(self.rfile.read(length).decode("utf-8") or "null")
        except json.JSONDecodeError:
            self.send_json(400, {"error": "invalid json"})
            return True
        try:
            self.send_json(200, placements.put(project, app, APPS, body, dry_run=planning))
        except placements.Refused as refused:
            self.send_json(422, {"error": "placement refused", "reasons": refused.reasons})
        return True

    def do_PUT(self):
        if not self.placement_request("PUT"):
            self.send_json(404, {"error": "not found"})

    def do_DELETE(self):
        if not self.placement_request("DELETE"):
            self.send_json(404, {"error": "not found"})

    def do_GET(self):
        if self.placement_request("GET"):
            return
        if self.path == "/health":
            self.send_json(200, {"ok": True, "apps": sorted(APPS.keys()), "system": SYSTEM})
            return
        match = re.fullmatch(r"/status/([^/]+)", self.path)
        if match is not None:
            if self.headers.get("Authorization", "") != "Bearer " + read_token():
                self.send_json(403, {"error": "forbidden"})
                return
            app = APPS.get(match.group(1))
            if app is None:
                self.send_json(404, {"error": "unknown app", "app": match.group(1)})
                return
            self.send_json(200, app_status(app))
            return
        self.send_json(404, {"error": "not found"})

    def do_POST(self):
        if self.placement_request("POST"):
            return
        expected = "Bearer " + read_token()
        if self.headers.get("Authorization", "") != expected:
            self.send_json(403, {"error": "forbidden"})
            return

        match = re.fullmatch(r"/(deploy|preflight)/([^/]+)", self.path)
        if match is None:
            self.send_json(404, {"error": "not found"})
            return

        action, app_name = match.groups()
        app = APPS.get(app_name)
        if app is None:
            self.send_json(404, {"error": "unknown app", "app": app_name})
            return

        length = int(self.headers.get("Content-Length", "0") or "0")
        payload = {}
        if length:
            try:
                payload = json.loads(self.rfile.read(length).decode("utf-8"))
            except json.JSONDecodeError:
                self.send_json(400, {"error": "invalid json"})
                return

        if action == "preflight":
            descriptor = payload.get("descriptor")
            if not isinstance(descriptor, dict):
                self.send_json(400, {"error": "preflight requires a descriptor object"})
                return
            if not app["bindingPolicyFile"]:
                self.send_json(400, {"error": "app does not use the Project adapter"})
                return
            with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8") as candidate:
                json.dump(descriptor, candidate)
                candidate.flush()
                result = subprocess.run(
                    [
                        PLANNER,
                        "plan-release",
                        "--host", placements.policy_file(app),
                        "--candidate", candidate.name,
                    ],
                    check=False,
                    capture_output=True,
                    text=True,
                )
            if result.returncode != 0:
                self.send_json(500, {"error": "compatibility evaluation failed"})
                return
            compatibility = json.loads(result.stdout)
            self.send_json(200 if compatibility.get("compatible") else 409, {
                "app": app_name,
                "compatibility": compatibility,
            })
            return

        revision = str(payload.get("revision", "")).strip()
        if revision:
            if not all(ch in "0123456789abcdefABCDEF" for ch in revision) or len(revision) < 7:
                self.send_json(400, {"error": "invalid revision"})
                return
        store_path = str(payload.get("storePath", "")).strip()
        if store_path and re.fullmatch(r"/nix/store/[0-9a-df-np-sv-z]{32}-[^/]+", store_path) is None:
            self.send_json(400, {"error": "invalid storePath"})
            return

        fence = payload.get("fence")
        if fence is not None:
            if not isinstance(fence, int) or isinstance(fence, bool) or fence < 0:
                self.send_json(400, {"error": "invalid fence"})
                return
            newer = accept_fence(os.path.dirname(app["requestedReleaseFile"]), fence)
            if newer is not None:
                self.send_json(409, {"error": "stale fence", "fence": newer})
                return

        # An update that is already running, such as a placement's redeploy, may have read the
        # requests before this one: systemctl start would join it and answer with its result, and
        # the update script skips its run while another holds the lock. Wait, then run this one.
        while update_running(app):
            time.sleep(1)

        if app["deliveryMode"] == "cache":
            if not revision or not store_path:
                self.send_json(400, {"error": "cache delivery requires revision and storePath"})
                return
            release = {
                "schemaVersion": 1,
                "revision": revision,
                "storePath": store_path,
                "source": str(payload.get("source", "promotion-webhook")),
            }
            tmp_path = app["requestedReleaseFile"] + ".next"
            os.makedirs(os.path.dirname(app["requestedReleaseFile"]), exist_ok=True)
            with open(tmp_path, "w", encoding="utf-8") as handle:
                json.dump(release, handle, sort_keys=True)
                handle.write("\n")
            os.replace(tmp_path, app["requestedReleaseFile"])
        elif revision:
            tmp_path = app["requestedRevisionFile"] + ".next"
            os.makedirs(os.path.dirname(app["requestedRevisionFile"]), exist_ok=True)
            with open(tmp_path, "w", encoding="utf-8") as handle:
                handle.write(revision + "\n")
            os.replace(tmp_path, app["requestedRevisionFile"])

        try:
            subprocess.run(app["updateCommand"], check=True)
        except subprocess.CalledProcessError as error:
            compatibility = None
            try:
                with open(app["compatibilityFile"], "r", encoding="utf-8") as handle:
                    compatibility = json.load(handle)
            except (FileNotFoundError, json.JSONDecodeError):
                pass
            status = 409 if compatibility is not None and not compatibility.get("compatible", True) else 503
            self.send_json(status, {
                "accepted": False,
                "app": app_name,
                "exitCode": error.returncode,
                "compatibility": compatibility,
            })
            return

        self.send_json(202, {
            "accepted": True,
            "app": app_name,
            "revision": revision or None,
            "storePath": store_path or None,
        })


if __name__ == "__main__":
    host = os.environ.get("APP_DEPLOYMENTS_WEBHOOK_HOST", "0.0.0.0")
    port = int(os.environ["APP_DEPLOYMENTS_WEBHOOK_PORT"])
    ThreadingHTTPServer((host, port), Handler).serve_forever()
