"""Placements: a repository's choices for its release on this host, within the grant infra sets.

A placement holds the release's hostname and visibility, which SOPS keys its secrets read,
parameter values and memory limits. The release's user, port, units and site stay in NixOS; a
placement replaces only the bindings the host's configuration gives them:

- `<state>/placement/` holds its copies of the binding policy, secret bindings and runtime base,
  which the update script prefers, and the hostname health probes send.
- Its secrets are decrypted into /run/app-deployments/<project>/credentials and loaded through
  drop-ins in /run/systemd/system, which also carry its memory limits.
- Its route goes to a file agent-service-routes serves and imports the release's compiled site.

`restore` runs before releases start, at boot and after every switch that changes a release's
registration: it binds each placement again over the host's current compiled bindings, deletes one
the grant no longer allows, and writes the credentials and drop-ins a boot emptied from /run. The
webhook (app-deployments.nix) serves the HTTP side.
"""

import contextlib
import fcntl
import hashlib
import hmac
import json
import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

PLANNER = os.environ.get("APP_DEPLOYMENTS_PLANNER", "project-runtime")
SOPS = os.environ.get("APP_DEPLOYMENTS_SOPS", "sops")
SOPS_FILE = os.environ.get("APP_DEPLOYMENTS_SOPS_FILE", "")
SOPS_KEY_FILE = os.environ.get("APP_DEPLOYMENTS_SOPS_KEY_FILE", "")
ROUTES_FILE = Path(os.environ.get("APP_DEPLOYMENTS_PLACEMENT_ROUTES", "/var/lib/app-deployments/placements/routes.json"))
CREDENTIALS = Path(os.environ.get("APP_DEPLOYMENTS_PLACEMENT_CREDENTIALS", "/run/app-deployments"))
UNITS = Path(os.environ.get("APP_DEPLOYMENTS_PLACEMENT_UNITS", "/run/systemd/system"))

LABEL = re.compile(r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$")
NAME = re.compile(r"^[A-Za-z][A-Za-z0-9_-]*$")
KEY_SEGMENT = re.compile(r"^[A-Za-z0-9_.-]+$")
SIZE = re.compile(r"^(\d+(?:\.\d+)?)([KMGT])$")
FIELDS = {"endpoint", "secrets", "parameters", "memory"}
MEMORY = ("high", "max", "swapMax")



@contextlib.contextmanager
def locked():
    """Serializes the webhook's changes and `restore`, which run in different processes."""
    ROUTES_FILE.parent.mkdir(parents=True, exist_ok=True)
    with open(ROUTES_FILE.parent / ".lock", "w") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        yield


class Refused(Exception):
    """A placement the grant or the release doesn't allow, with every reason."""

    def __init__(self, reasons):
        super().__init__("; ".join(reasons))
        self.reasons = reasons


def token_for(key: bytes, project: str) -> str:
    """The project's own token: the stack that holds it can change this project's placement only."""
    return hmac.new(key, project.encode(), hashlib.sha256).hexdigest()


def authorized(header: str, project: str, key: bytes | None, admin_token: str) -> bool:
    if not header.startswith("Bearer "):
        return False
    given = header.removeprefix("Bearer ")
    if hmac.compare_digest(given, admin_token):
        return True
    return key is not None and hmac.compare_digest(given, token_for(key, project))


def valid_host(name: str) -> bool:
    return len(name) <= 253 and "." in name and all(LABEL.fullmatch(label) for label in name.split("."))


def granted_host(name: str, patterns) -> bool:
    """An exact name, or `*.parent` for every name below parent."""
    for pattern in patterns:
        if pattern.startswith("*."):
            if name.endswith(pattern[1:]):
                return True
        elif name == pattern:
            return True
    return False


def size(text: str) -> int | None:
    match = SIZE.fullmatch(text)
    if match is None:
        return None
    return int(float(match[1]) * 1024 ** ("KMGT".index(match[2]) + 1))


def check(project: str, grant: dict, placement: object) -> dict:
    """The placement as stored, or Refused with every way it breaks the grant."""
    if not isinstance(placement, dict):
        raise Refused(["a placement is a JSON object"])
    reasons = [f"unknown field {field}" for field in sorted(set(placement) - FIELDS)]

    endpoint = placement.get("endpoint")
    if endpoint is not None:
        if not isinstance(endpoint, dict) or set(endpoint) - {"hostName", "visibility"}:
            reasons.append("endpoint takes hostName and visibility")
        else:
            host = str(endpoint.get("hostName", "")).lower()
            visibility = endpoint.get("visibility", "tailnet")
            if not valid_host(host):
                reasons.append(f"{host or 'an empty name'} is not a hostname")
            elif not granted_host(host, grant["hostNames"]):
                reasons.append(f"{project} may not claim {host}")
            if visibility not in ("public", "tailnet"):
                reasons.append("visibility is public or tailnet")
            elif visibility == "public" and not grant["public"]:
                reasons.append(f"{project} may not be public")
            endpoint = {"hostName": host, "visibility": visibility}

    secrets = placement.get("secrets", {})
    if not isinstance(secrets, dict):
        reasons.append("secrets maps a secret's name to a SOPS key")
        secrets = {}
    for name, key in sorted(secrets.items()):
        if not NAME.fullmatch(name):
            reasons.append(f"{name} is not a secret name")
        elif not isinstance(key, str) or not all(KEY_SEGMENT.fullmatch(part) for part in key.split("/")):
            reasons.append(f"{name} reads {key!r}, which is not a SOPS key such as projects/{project}/{name}")
        elif not key.startswith(grant["secretPrefix"]):
            reasons.append(f"{name} may not read {key}; {project} reads keys under {grant['secretPrefix']}")

    parameters = placement.get("parameters", {})
    if not isinstance(parameters, dict):
        reasons.append("parameters maps a parameter's name to its value")
        parameters = {}

    memory = placement.get("memory", {})
    ceiling = None if grant.get("memoryMax") is None else size(grant["memoryMax"])
    if not isinstance(memory, dict) or set(memory) - set(MEMORY):
        reasons.append("memory takes high, max and swapMax")
        memory = {}
    for field, value in sorted(memory.items()):
        bytes_ = size(value) if isinstance(value, str) else None
        if bytes_ is None:
            reasons.append(f"memory {field} {value!r} is not a size such as 512M or 1G")
        elif ceiling is None:
            reasons.append(f"{project}'s grant sets no memory ceiling, so its placement sets no memory")
        elif bytes_ > ceiling:
            reasons.append(f"memory {field} {value} is above {project}'s ceiling of {grant['memoryMax']}")

    if reasons:
        raise Refused(reasons)
    stored = {"secrets": dict(secrets), "parameters": dict(parameters), "memory": dict(memory)}
    if endpoint is not None:
        stored["endpoint"] = endpoint
    return stored


def read_json(path):
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def write_atomic(path: Path, text: str, mode: int = 0o644) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        os.unlink(tmp)
        raise


def dumps(value) -> str:
    return json.dumps(value, indent=2, sort_keys=True) + "\n"


def credentials_dir(project: str) -> Path:
    return CREDENTIALS / project / "credentials"


def placement_dir(app: dict) -> Path:
    return Path(app["placement"]["stateDir"]) / "placement"


def policy_file(app: dict) -> str:
    """The binding policy that applies to the release: its placement's, or the compiled one."""
    if app.get("placement") is not None:
        placed = placement_dir(app) / "policy.json"
        if placed.is_file():
            return str(placed)
    return app["bindingPolicyFile"]


def bindings(project: str, app: dict, stored: dict) -> dict:
    """The policy, secret bindings and runtime base the placement gives the release."""
    registration = app["placement"]
    policy = read_json(registration["policy"])
    policy["bindings"]["parameters"] = {**policy["bindings"]["parameters"], **stored["parameters"]}
    policy["bindings"]["secrets"] = sorted(set(policy["bindings"]["secrets"]) | set(stored["secrets"]))
    # As in project-descriptor.nix: a bound secret requirement is met by the credential of its name.
    requirements = policy["descriptor"].get("requirements", {})
    policy["bindings"]["resources"] = {
        **{
            name: {"kind": "secret", "credential": name}
            for name in stored["secrets"]
            if requirements.get(name, {}).get("kind") == "secret"
            and "release" in requirements[name].get("realizations", [])
        },
        **policy["bindings"]["resources"],
    }
    secrets = {
        **read_json(registration["secretBindings"]),
        **{name: str(credentials_dir(project) / name) for name in stored["secrets"]},
    }
    runtime = read_json(registration["runtimeBase"])
    endpoint = stored.get("endpoint")
    if endpoint is not None:
        runtime["endpoints"][registration["action"]].update({
            "url": f"https://{endpoint['hostName']}",
            "hostNames": [endpoint["hostName"]],
            "visibility": endpoint["visibility"],
        })
    return {"policy": policy, "secrets": secrets, "runtime": runtime}


def write_bound(app: dict, stored: dict, bound: dict) -> bool:
    """Writes the files the update script prefers; whether any of them changed."""
    directory = placement_dir(app)
    endpoint = stored.get("endpoint")
    files = {
        "policy.json": dumps(bound["policy"]),
        "secrets.json": dumps(bound["secrets"]),
        "runtime-base.json": dumps(bound["runtime"]),
        "host": None if endpoint is None else endpoint["hostName"] + "\n",
        "placement.json": dumps(stored),
    }
    changed = False
    for name, text in files.items():
        path = directory / name
        current = path.read_text(encoding="utf-8") if path.is_file() else None
        if current == text:
            continue
        changed = True
        if text is None:
            path.unlink()
        else:
            write_atomic(path, text)
    return changed


def plan(policy: dict) -> None:
    """plan-release of the release the host accepts, its policy's descriptor, with the placed bindings.

    Not the active release: after a lock bump changes the topology, only the revision Calder is about
    to promote matches the host, and that promotion waits for this placement.
    """
    with tempfile.TemporaryDirectory() as directory:
        host = Path(directory) / "policy.json"
        candidate = Path(directory) / "candidate.json"
        host.write_text(json.dumps(policy), encoding="utf-8")
        candidate.write_text(json.dumps(policy["descriptor"]), encoding="utf-8")
        result = subprocess.run(
            [PLANNER, "plan-release", "--host", str(host), "--candidate", str(candidate)],
            check=False, capture_output=True, text=True,
        )
    if result.returncode != 0:
        raise Refused([f"plan-release failed: {result.stderr.strip() or result.returncode}"])
    outcome = json.loads(result.stdout)
    if not outcome.get("compatible"):
        raise Refused([f"the release: {reason}" for reason in outcome.get("reasons", [])])


def decrypt(key: str) -> str:
    path = "".join(f'["{part}"]' for part in key.split("/"))
    env = {**os.environ, "SOPS_AGE_KEY_FILE": SOPS_KEY_FILE}
    result = subprocess.run([SOPS, "-d", "--extract", path, SOPS_FILE], check=False, capture_output=True, text=True, env=env)
    if result.returncode != 0:
        raise Refused([f"{key} can't be decrypted from this host's secrets"])
    return result.stdout


def materialize(project: str, app: dict, stored: dict, secrets: dict, values: dict) -> bool:
    """Credentials in /run and the drop-ins that load them and set the memory limits; whether they changed."""
    directory = credentials_dir(project)
    current = {path.name: path.read_text(encoding="utf-8") for path in directory.iterdir()} if directory.is_dir() else None
    changed = current != values
    if changed:
        if directory.exists():
            shutil.rmtree(directory)
        directory.mkdir(parents=True, mode=0o700)
        for name, value in values.items():
            write_atomic(directory / name, value, 0o400)
    registration = app["placement"]
    service = registration["credentialUnits"][0]
    for unit in registration["credentialUnits"]:
        lines = ["[Service]", "LoadCredential="] + [f"LoadCredential={name}:{path}" for name, path in sorted(secrets.items())]
        if unit == service:
            lines += [f"Memory{field[0].upper()}{field[1:]}={value}" for field, value in sorted(stored["memory"].items())]
        dropin = UNITS / f"{unit}.d" / "50-placement.conf"
        text = "\n".join(lines) + "\n"
        if not dropin.is_file() or dropin.read_text(encoding="utf-8") != text:
            write_atomic(dropin, text)
            changed = True
    return changed


def unmaterialize(project: str, app: dict) -> None:
    shutil.rmtree(credentials_dir(project), ignore_errors=True)
    for unit in app["placement"]["credentialUnits"]:
        (UNITS / f"{unit}.d" / "50-placement.conf").unlink(missing_ok=True)


def placed(apps: dict) -> dict:
    """Every release with a placement on this host, by project."""
    out = {}
    for project, app in apps.items():
        if app.get("placement") is None:
            continue
        stored = placement_dir(app) / "placement.json"
        if stored.is_file():
            out[project] = read_json(stored)
    return out


def write_routes(apps: dict) -> None:
    routes = []
    for project, stored in sorted(placed(apps).items()):
        endpoint = stored.get("endpoint")
        if endpoint is None:
            continue
        registration = apps[project]["placement"]
        routes.append({
            "name": project,
            "hostName": endpoint["hostName"],
            "visibility": endpoint["visibility"],
            "upstreamPort": registration["port"],
            "site": registration["site"],
        })
    write_atomic(ROUTES_FILE, json.dumps(routes, indent=2) + "\n")


def redeploy(app: dict) -> None:
    """Asks the update unit to activate the current release again, with the new bindings."""
    state = Path(app["placement"]["stateDir"])
    current = state / "current"
    revision = state / "current-revision"
    if not current.is_symlink() or not revision.is_file():
        return
    active = revision.read_text(encoding="utf-8").strip()
    # The request the update script reads in the app's delivery mode, as the webhook writes it.
    if app["deliveryMode"] == "cache":
        request = {"schemaVersion": 1, "revision": active, "storePath": os.readlink(current), "source": "placement"}
        write_atomic(Path(app["requestedReleaseFile"]), dumps(request))
    else:
        write_atomic(Path(app["requestedRevisionFile"]), active + "\n")
    subprocess.run(["systemctl", "start", "--no-block", app["updateUnit"]], check=False)


def apply(app: dict, rebound: bool, rewritten: bool) -> None:
    """Brings the running release in line: an activation when its bindings changed, since only that
    rewrites its runtime manifest; a restart when only its credentials or drop-ins did, since an
    activation with unchanged bindings finds the release already active."""
    if rebound:
        redeploy(app)
    elif rewritten:
        subprocess.run(["systemctl", "try-restart", "--no-block", app["placement"]["credentialUnits"][0]], check=False)


def put(project: str, app: dict, apps: dict, placement: object, dry_run: bool) -> dict:
    registration = app.get("placement")
    if registration is None:
        raise Refused([f"{project} has no grant on this host"])
    stored = check(project, registration["grant"], placement)
    bound = bindings(project, app, stored)
    plan(bound["policy"])
    values = {name: decrypt(key) for name, key in stored["secrets"].items()}
    summary = {"project": project, "placement": stored}
    if dry_run:
        return summary
    with locked():
        rebound = write_bound(app, stored, bound)
        rewritten = materialize(project, app, stored, bound["secrets"], values)
        write_routes(apps)
        subprocess.run(["systemctl", "daemon-reload"], check=True)
        apply(app, rebound, rewritten)
    return summary


def delete(project: str, app: dict, apps: dict) -> bool:
    if app.get("placement") is None or not (placement_dir(app) / "placement.json").exists():
        return False
    with locked():
        shutil.rmtree(placement_dir(app))
        unmaterialize(project, app)
        write_routes(apps)
        subprocess.run(["systemctl", "daemon-reload"], check=True)
        redeploy(app)
    return True


def get(app: dict) -> dict | None:
    if app.get("placement") is None:
        return None
    stored = placement_dir(app) / "placement.json"
    return read_json(stored) if stored.is_file() else None


def restore(apps: dict) -> int:
    """Binds every placement again and writes /run; the number of placements that failed."""
    failures = 0
    changes = []
    with locked():
        for project, stored in sorted(placed(apps).items()):
            app = apps[project]
            try:
                stored = check(project, app["placement"]["grant"], stored)
                bound = bindings(project, app, stored)
                values = {name: decrypt(key) for name, key in stored["secrets"].items()}
            except Refused as refused:
                failures += 1
                print(f"placements: {project}: deleted, since {refused}", flush=True)
                shutil.rmtree(placement_dir(app))
                unmaterialize(project, app)
                changes.append((app, True, False))
                continue
            except (OSError, ValueError) as error:
                failures += 1
                print(f"placements: {project}: {error}", flush=True)
                continue
            rebound = write_bound(app, stored, bound)
            changes.append((app, rebound, materialize(project, app, stored, bound["secrets"], values)))
        write_routes(apps)
        subprocess.run(["systemctl", "daemon-reload"], check=False)
    for app, rebound, rewritten in changes:
        apply(app, rebound, rewritten)
    return failures


if __name__ == "__main__":
    import sys

    apps = read_json(os.environ["APP_DEPLOYMENTS_APPS_FILE"])
    if sys.argv[1:] == ["restore"]:
        sys.exit(1 if restore(apps) else 0)
    print("usage: placements.py restore", file=sys.stderr)
    sys.exit(64)
