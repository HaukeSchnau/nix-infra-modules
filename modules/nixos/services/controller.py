"""The service controller: runs services that repositories declare at runtime, within the grants the
host's configuration gives them.

A repository's stack puts a service's spec (`Fleet.Service` in @schnau/fleet): store paths, the
commands that run from them, an endpoint, a health path, a database, environment, secrets and
memory. The controller keeps each accepted spec as a generation under the state directory and runs
the active one as an instance of the template unit `fleet-service@<name>.service`. A runtime drop-in
gives the instance its command, environment, credentials, memory limits and a DynamicUser with a
stable name, `fleet-<name>`. That name is also the service's PostgreSQL role and database, so peer
authentication works.

A deploy realizes the store paths, creates the database, writes the credentials and runs `prepare`
from the candidate. Only then does it cut over and wait for the health path. A failed `prepare`
leaves the active generation untouched; a failed health check restores it.

Everything in /run (credentials and drop-ins) is derived from the state directory. `restore` writes
it again at start and every few minutes, so a boot brings every service back.

Usage: controller.py serve
"""

import hashlib
import hmac
import json
import os
import re
import shutil
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

# `fleet-<name>` must stay within 31 characters, the limit for user names systemd accepts everywhere.
NAME = re.compile(r"^[a-z]([a-z0-9-]{0,23}[a-z0-9])?$")
PATH_KEY = re.compile(r"^[A-Za-z][A-Za-z0-9_-]*$")
ENV_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
LABEL = re.compile(r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$")
STORE_PATH = re.compile(r"^/nix/store/[0-9a-df-np-sv-z]{32}-[A-Za-z0-9+._?=-]+$")
REVISION = re.compile(r"^[A-Za-z0-9._-]{1,128}$")
KEY_SEGMENT = re.compile(r"^[A-Za-z0-9_.-]+$")
SIZE = re.compile(r"^(\d+)([KMGT])$")
PLACEHOLDER = re.compile(r"\{([^{}]*)\}")
HEALTH_PATH = re.compile(r"^/[\x21-\x7e]*$")
FIELDS = {"release", "command", "prepare", "console", "endpoint", "health", "database", "env", "secrets", "memory"}
COMMANDS = ("command", "prepare", "console")
HISTORY = 10
CONVERGE_SECONDS = 300
# Connections the services' budget leaves to the superuser, the nightly dumps and operators.
RESERVED_CONNECTIONS = 10

CONFIG: dict = {}


class Refused(Exception):
    """A spec the grant or this host doesn't allow, with every reason. `revoked` holds the reasons
    that are permissions the grant doesn't give, as opposed to capacity that others use up."""

    def __init__(self, reasons, revoked=()):
        super().__init__("; ".join(reasons))
        self.reasons = reasons
        self.revoked = list(revoked)


class Busy(Exception):
    """Another deploy of the service is still running; the client tries again."""


class Stale(Exception):
    """A request from a deploy lease that a newer one replaced."""


class Failed(Exception):
    """A deploy step that failed before the cutover."""


def log(message: str) -> None:
    print(message, flush=True)


# Grants and specs


def grant_of(name: str, grants: dict):
    """The grant a service belongs to: the one it is named after, as `<grant>` or `<grant>-<suffix>`."""
    for grant, limits in grants.items():
        if name == grant or name.startswith(grant + "-"):
            return grant, limits
    return None, None


def size(text) -> int | None:
    match = SIZE.fullmatch(text) if isinstance(text, str) else None
    if match is None:
        return None
    return int(match[1]) * 1024 ** ("KMGT".index(match[2]) + 1)


def valid_host(name: str) -> bool:
    return len(name) <= 253 and "." in name and all(LABEL.fullmatch(label) for label in name.split("."))


def granted_host(name: str, patterns) -> bool:
    """An exact name, or `*.parent` for every name below parent."""
    return any(name.endswith(pattern[1:]) if pattern.startswith("*.") else name == pattern for pattern in patterns)


def check_command(field: str, value, paths: dict, reasons: list):
    """An argument list whose first word is a file in one of the release's paths, such as
    `{node}/bin/node`. `{key}` stands for the store path the release names key."""
    if not isinstance(value, list) or not value or not all(isinstance(word, str) for word in value):
        reasons.append(f"{field} is a non-empty list of strings")
        return None
    for word in value:
        if any(character in word for character in "\0\n"):
            reasons.append(f"{field} has a word with a NUL or newline")
        for key in PLACEHOLDER.findall(word):
            if key not in paths:
                reasons.append(f"{field} names {{{key}}}, which is not one of the release's paths")
    if not re.match(r"^\{[^{}]+\}/", value[0]):
        reasons.append(f"{field} starts with a file in one of the release's paths, such as {{bundle}}/bin/server")
    return list(value)


def check(name: str, grant_name: str, grant: dict, spec, others: list, claimed: dict, postgres: dict | None, stored=False) -> dict:
    """The spec as the controller keeps it, or Refused with every way it breaks the grant.

    `others` holds one spec per other service of the grant, for its service count and memory
    ceiling; a service that is deploying counts with the larger memory of its two generations.
    `claimed` maps every hostname another service on the host runs or deploys to that service.
    `postgres` is this host's `{major, free, connectionLimit}`, where free is how many connections
    the other services' databases leave. A `stored` spec carries sealed secret values instead of
    plain ones. Reasons never quote a secret's value or SOPS key.
    """
    if not isinstance(spec, dict):
        raise Refused(["a service is a JSON object"])
    reasons = [f"unknown field {field}" for field in sorted(set(spec) - FIELDS)]
    revoked = []

    def deny(reason):
        reasons.append(reason)
        revoked.append(reason)

    if len(others) + 1 > grant["services"]:
        reasons.append(f"{grant_name} may run {grant['services']} services, and runs {len(others)} others")

    release = spec.get("release")
    paths = {}
    if not isinstance(release, dict) or set(release) != {"revision", "paths"}:
        reasons.append("release takes revision and paths")
        release = None
    else:
        if not isinstance(release["revision"], str) or not REVISION.fullmatch(release["revision"]):
            reasons.append(f"{release['revision']!r} is not a revision")
        if not isinstance(release["paths"], dict) or not release["paths"]:
            reasons.append("release paths map a name such as bundle to a store path")
        else:
            for key, path in sorted(release["paths"].items()):
                if not PATH_KEY.fullmatch(key):
                    reasons.append(f"{key!r} is not a path name such as bundle")
                elif not isinstance(path, str) or not STORE_PATH.fullmatch(path):
                    reasons.append(f"path {key} is {path!r}, which is not a store path")
                else:
                    paths[key] = path

    commands = {}
    for field in COMMANDS:
        value = spec.get(field)
        if value is None and field != "command":
            commands[field] = None
        else:
            commands[field] = check_command(field, value, paths, reasons)

    endpoint = spec.get("endpoint")
    if endpoint is not None:
        if not isinstance(endpoint, dict) or set(endpoint) - {"hostName", "visibility"}:
            reasons.append("endpoint takes hostName and visibility")
            endpoint = None
        else:
            host = str(endpoint.get("hostName", "")).lower()
            visibility = endpoint.get("visibility", "tailnet")
            if not valid_host(host):
                reasons.append(f"{host or 'an empty name'} is not a hostname")
            elif not granted_host(host, grant["hostNames"]):
                deny(f"{grant_name} may not claim {host}")
            elif host in claimed:
                reasons.append(f"{host} belongs to the service {claimed[host]}")
            if visibility not in ("public", "tailnet"):
                reasons.append("visibility is public or tailnet")
            elif visibility == "public" and not grant["public"]:
                deny(f"{grant_name} may not be public")
            endpoint = {"hostName": host, "visibility": visibility}

    health = spec.get("health")
    if not isinstance(health, dict) or set(health) - {"path", "timeoutSec"} or "path" not in health:
        reasons.append("health takes a path such as /health/ready, and timeoutSec")
        health = None
    else:
        timeout = health.get("timeoutSec", 60)
        if not isinstance(health["path"], str) or not HEALTH_PATH.fullmatch(health["path"]):
            reasons.append(f"health path {health['path']!r} is not an absolute URL path")
        if type(timeout) is not int or not 1 <= timeout <= 600:
            reasons.append("health timeoutSec is a whole number of seconds from 1 to 600")
        health = {"path": health["path"], "timeoutSec": timeout}

    database = spec.get("database")
    if database is not None:
        if not isinstance(database, dict) or set(database) - {"env", "majorVersion", "dropOnDelete", "connections"}:
            reasons.append("database takes env, majorVersion, dropOnDelete and connections")
            database = None
        else:
            connections = database.get("connections", (postgres or {}).get("connectionLimit"))
            if not grant["databases"]:
                deny(f"{grant_name} may not have databases")
            elif postgres is None:
                reasons.append("this host runs no PostgreSQL")
            elif type(connections) is not int or connections < 1:
                reasons.append("database connections is a whole number above 0")
            elif connections > postgres["free"]:
                reasons.append(f"the database asks for {connections} connections, and this host's PostgreSQL has {max(postgres['free'], 0)} left")
            major = database.get("majorVersion")
            if major is not None and major != (postgres or {}).get("major"):
                reasons.append(f"the service needs PostgreSQL {major}, and this host runs {(postgres or {}).get('major')}")
            database = {
                "env": database.get("env", "DATABASE_URL"),
                "dropOnDelete": database.get("dropOnDelete", False),
                "connections": connections,
            }
            if not isinstance(database["env"], str) or not ENV_NAME.fullmatch(database["env"]):
                reasons.append(f"database env {database['env']!r} is not a variable name")
            if type(database["dropOnDelete"]) is not bool:
                reasons.append("database dropOnDelete is true or false")

    env = spec.get("env", {})
    if not isinstance(env, dict) or not all(isinstance(value, str) for value in env.values()):
        reasons.append("env maps a variable name to a string")
        env = {}
    for key, value in sorted(env.items()):
        if not ENV_NAME.fullmatch(key):
            reasons.append(f"{key!r} is not a variable name")
        if "\0" in value:
            reasons.append(f"{key} has a NUL")

    secrets = spec.get("secrets", {})
    if not isinstance(secrets, dict):
        reasons.append("secrets map a variable name to a SOPS key or a value")
        secrets = {}
    kinds = ("sops", "sealed") if stored else ("sops", "value")
    for key, source in sorted(secrets.items()):
        if not ENV_NAME.fullmatch(key):
            reasons.append(f"{key!r} is not a variable name")
        elif not isinstance(source, dict) or len(source) != 1 or next(iter(source)) not in kinds or not isinstance(next(iter(source.values())), str):
            reasons.append(f"secret {key} is {{\"sops\": <key>}} or {{\"value\": <string>}}")
        elif "sops" in source:
            path = source["sops"]
            if not all(KEY_SEGMENT.fullmatch(part) for part in path.split("/")):
                reasons.append(f"secret {key} names no SOPS key such as projects/{grant_name}/{key.lower()}")
            elif not any(path.startswith(prefix) for prefix in grant["secretPrefixes"]):
                allowed = " or ".join(grant["secretPrefixes"]) or "no prefix"
                deny(f"secret {key} names a SOPS key outside {allowed}, which {grant_name} may read")
        elif not next(iter(source.values())) or "\0" in next(iter(source.values())):
            reasons.append(f"secret {key} has an empty value or a NUL")

    provided = {"HOST", "PORT"} | ({database["env"]} if database else set()) | {f"{key}_FILE" for key in secrets}
    for key in sorted(provided & set(env)):
        reasons.append(f"env may not set {key}, which the host sets")

    memory = spec.get("memory", {})
    if not isinstance(memory, dict) or set(memory) - {"max", "high"}:
        reasons.append("memory takes max and high")
        memory = {}
    for field, value in sorted(memory.items()):
        if size(value) is None:
            reasons.append(f"memory {field} {value!r} is not a size such as 512M or 1G")
    if "high" in memory and "max" in memory and size(memory["high"]) and size(memory["max"]) and size(memory["high"]) > size(memory["max"]):
        reasons.append("memory high is above max")
    ceiling = size(grant["memoryMax"]) if grant.get("memoryMax") else None
    if ceiling is not None:
        if size(memory.get("max")) is None:
            reasons.append(f"{grant_name} shares {grant['memoryMax']} between its services, so each sets memory max")
        else:
            used = sum(size(other.get("memory", {}).get("max")) or 0 for other in others)
            if used + size(memory["max"]) > ceiling:
                reasons.append(
                    f"memory max {memory['max']} is above what is left of {grant_name}'s {grant['memoryMax']}: "
                    f"its other services take {used // 1024 ** 2}M"
                )

    if reasons:
        raise Refused(reasons, revoked)
    return {
        "release": {"revision": release["revision"], "paths": paths},
        **commands,
        "endpoint": endpoint,
        "health": health,
        "database": database,
        "env": dict(env),
        "secrets": {key: dict(source) for key, source in secrets.items()},
        "memory": dict(memory),
    }


# Systemd


def unit(name: str) -> str:
    return f"fleet-service@{name}.service"


def user(name: str) -> str:
    return f"fleet-{name}"


def unit_quote(word: str, dollar: bool = False) -> str:
    """A word as a unit file reads it back: C escapes inside double quotes, `%%` for a percent sign,
    and in ExecStart `$$` for a dollar sign."""
    text = word.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("%", "%%")
    return '"' + (text.replace("$", "$$") if dollar else text) + '"'


def resolve(argv: list, paths: dict) -> list:
    return [PLACEHOLDER.sub(lambda match: paths[match[1]], word) for word in argv]


def run(args, *, input=None, check=True, **kwargs):
    return subprocess.run(args, input=input, check=check, capture_output=True, text=True, **kwargs)


def systemctl(*args, check=True):
    return run([CONFIG["bin"]["systemctl"], *args], check=check)


def unit_state(name: str) -> tuple[str, str]:
    output = systemctl("show", "--property=ActiveState,SubState", unit(name), check=False).stdout
    values = dict(line.split("=", 1) for line in output.splitlines() if "=" in line)
    return values.get("ActiveState", "unknown"), values.get("SubState", "unknown")


def invocation(name: str) -> str:
    return systemctl("show", "--property=InvocationID", "--value", unit(name), check=False).stdout.strip()


def journal(invocation_id: str, lines: int = 15) -> str:
    """The end of what one run of a unit's process wrote."""
    output = run(
        [CONFIG["bin"]["journalctl"], f"_SYSTEMD_INVOCATION_ID={invocation_id}", "--lines", str(lines), "--output", "cat", "--no-pager"],
        check=False,
    ).stdout
    return output.strip()


# State: /var/lib/fleet/services/<name>/ holds generations/<g>.json, active, port, owner.json,
# deploys.json, drop-database, violations, stopped and, while a deletion runs, the tombstone
# `deleting`. Fences live in /var/lib/fleet/fences/<name>, so they outlive a deletion, and so does
# /var/lib/fleet/kept/<name>.json, the owner of a database a deleted service left.


def state() -> Path:
    return Path(CONFIG["stateDir"])


def service_dir(name: str) -> Path:
    return state() / "services" / name


def services() -> list[str]:
    root = state() / "services"
    return sorted(path.name for path in root.iterdir() if path.is_dir()) if root.is_dir() else []


def read_json(path: Path, default=None):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return default


def write_atomic(path: Path, text: str, mode: int = 0o600) -> None:
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


def record_of(name: str, generation: int) -> dict:
    return read_json(service_dir(name) / "generations" / f"{generation}.json")


def active_generation(name: str) -> int | None:
    text = (service_dir(name) / "active").read_text().strip() if (service_dir(name) / "active").is_file() else ""
    return int(text) if text else None


def active_record(name: str) -> dict | None:
    generation = active_generation(name)
    return None if generation is None else record_of(name, generation)


def specs_of(name: str) -> list[dict]:
    """The specs of the service's generations, oldest first: the active one, and the one being
    deployed while a deploy runs."""
    directory = service_dir(name) / "generations"
    generations = sorted(int(path.stem) for path in directory.glob("*.json")) if directory.is_dir() else []
    return [record_of(name, generation)["spec"] for generation in generations]


def fence_path(name: str) -> Path:
    return state() / "fences" / name


def owner_of(name: str) -> dict | None:
    """Which stack, stage and logical ID put the service, as Fleet.Service sends it."""
    return read_json(service_dir(name) / "owner.json")


def tombstone(name: str) -> Path:
    return service_dir(name) / "deleting"


def violations(name: str) -> list[str]:
    """How the running service breaks its grant since the grant changed; the next PUT is refused."""
    return read_json(service_dir(name) / "violations", [])


def stopped(name: str) -> dict | None:
    """Why the service doesn't run: `{by, reason}`, stopped by an operator until its next deploy,
    or by its grant until the grant allows it again."""
    return read_json(service_dir(name) / "stopped")


def kept_path(name: str) -> Path:
    return state() / "kept" / f"{name}.json"


def kept_owner(name: str):
    """Who owned the database a deleted service of this name left: an owner, None for an operator,
    or `False` when no database was left."""
    kept = read_json(kept_path(name))
    return False if kept is None else kept["owner"]


def drops_database(name: str) -> bool:
    """Whether deleting the service drops its database: only when every spec the host ever
    accepted for it said `dropOnDelete`."""
    return read_json(service_dir(name) / "drop-database", False)


def port_of(name: str) -> int:
    """The service's loopback port, allocated at its first deploy and kept until it is deleted."""
    path = service_dir(name) / "port"
    if path.is_file():
        return int(path.read_text())
    used = {int((service_dir(other) / "port").read_text()) for other in services() if (service_dir(other) / "port").is_file()}
    first, last = CONFIG["portRange"]["from"], CONFIG["portRange"]["to"]
    port = next((port for port in range(first, last + 1) if port not in used), None)
    if port is None:
        raise Refused([f"this host has no free port left in {first}-{last}"])
    write_atomic(path, f"{port}\n", 0o644)
    return port


def deploys(name: str) -> list:
    return read_json(service_dir(name) / "deploys.json", [])


def note_deploy(name: str, generation: int, revision: str, outcome: str, reason: str | None = None) -> None:
    """Records a deploy's outcome, newest first; the client waits for its generation's."""
    entries = [entry for entry in deploys(name) if entry["generation"] != generation]
    entries.insert(0, {"generation": generation, "revision": revision, "outcome": outcome, "reason": reason, "at": int(time.time())})
    write_atomic(service_dir(name) / "deploys.json", dumps(entries[:HISTORY]))
    log(f"fleet: {name}: generation {generation} ({revision}) {outcome}" + (f": {reason}" if reason else ""))


# Secrets


def decrypt(key: str) -> str:
    if not CONFIG["sopsFile"]:
        raise Failed(f"{key} can't be read: this host has no SOPS file")
    path = "".join(f'["{part}"]' for part in key.split("/"))
    result = run(
        [CONFIG["bin"]["sops"], "--decrypt", "--extract", path, CONFIG["sopsFile"]],
        check=False,
        env={**os.environ, "SOPS_AGE_KEY_FILE": CONFIG["ageKeyFile"]},
    )
    if result.returncode != 0:
        raise Failed(f"{key} can't be decrypted from this host's secrets")
    return result.stdout


def recipient() -> str:
    return run([CONFIG["bin"]["ageKeygen"], "-y", CONFIG["ageKeyFile"]]).stdout.split()[0]


def seal(value: str) -> str:
    """The value encrypted for this host's age key, which is how a spec keeps it at rest."""
    return run([CONFIG["bin"]["age"], "--armor", "--recipient", recipient()], input=value).stdout


def unseal(text: str) -> str:
    return run([CONFIG["bin"]["age"], "--decrypt", "--identity", CONFIG["ageKeyFile"]], input=text).stdout


def credentials_dir(name: str, generation: int) -> Path:
    return Path(CONFIG["runtimeDir"]) / name / str(generation)


def secret_values(spec: dict, plain: dict | None = None) -> dict:
    """The values of a stored spec's secrets; `plain` holds values a request just brought."""
    values = {}
    for key, source in spec["secrets"].items():
        if "sops" in source:
            values[key] = decrypt(source["sops"])
        elif plain is not None and key in plain:
            values[key] = plain[key]
        else:
            values[key] = unseal(source["sealed"])
    return values


def write_credentials(name: str, generation: int, values: dict) -> bool:
    """The generation's credentials in /run, which only root reads; whether they changed."""
    directory = credentials_dir(name, generation)
    current = {path.name: path.read_text(encoding="utf-8") for path in directory.iterdir()} if directory.is_dir() else None
    if current == values:
        return False
    shutil.rmtree(directory, ignore_errors=True)
    directory.mkdir(parents=True, mode=0o700)
    for key, value in values.items():
        write_atomic(directory / key, value, 0o400)
    return True


def current_value(name: str, generation: int, key: str, source: dict) -> str:
    path = credentials_dir(name, generation) / key
    return path.read_text(encoding="utf-8") if path.is_file() else unseal(source["sealed"])


# What a generation runs


def environment(name: str, record: dict, unit_name: str) -> dict:
    """The environment a generation's processes get: the spec's, the listen address, the database
    URL, and `<SECRET>_FILE` for every secret, pointing into the unit's credentials directory."""
    spec = record["spec"]
    env = {**spec["env"], "HOST": "127.0.0.1", "PORT": str(port_of(name))}
    if spec["database"] is not None:
        postgres = CONFIG["postgresql"]
        env[spec["database"]["env"]] = (
            f"postgresql:///{user(name)}?host={postgres['socket']}&port={postgres['port']}&user={user(name)}"
        )
    for key in spec["secrets"]:
        env[f"{key}_FILE"] = f"/run/credentials/{unit_name}/{key}"
    return env


def properties(name: str, record: dict) -> list[str]:
    """Unit properties of a generation's processes, as both drop-ins and systemd-run take them."""
    spec, generation = record["spec"], record["generation"]
    lines = [f"User={user(name)}", f"Group={user(name)}"]
    lines += [f"LoadCredential={key}:{credentials_dir(name, generation) / key}" for key in sorted(spec["secrets"])]
    lines += [f"Memory{field.capitalize()}={value}" for field, value in sorted(spec["memory"].items())]
    return lines


def dropin_path(name: str) -> Path:
    return Path(CONFIG["unitsDir"]) / f"{unit(name)}.d" / "50-fleet.conf"


def dropin(name: str, record: dict) -> str:
    spec = record["spec"]
    command = resolve(spec["command"], spec["release"]["paths"])
    lines = [
        f"# Written by fleet-controller: generation {record['generation']}, revision {spec['release']['revision']}.",
        "[Service]",
        *properties(name, record),
        f"SocketBindAllow=tcp:{port_of(name)}",
        "ExecStart=",
        "ExecStart=" + " ".join(unit_quote(word, dollar=True) for word in command),
    ]
    lines += [f"Environment={unit_quote(f'{key}={value}')}" for key, value in sorted(environment(name, record, unit(name)).items())]
    return "\n".join(lines) + "\n"


def write_dropin(name: str, record: dict) -> bool:
    path, text = dropin_path(name), dropin(name, record)
    if path.is_file() and path.read_text(encoding="utf-8") == text:
        return False
    write_atomic(path, text, 0o644)
    return True


def transient(name: str, record: dict, unit_name: str, argv: list, extra: list) -> list:
    """A systemd-run command line that runs argv like the generation's service does."""
    spec = record["spec"]
    args = [CONFIG["bin"]["systemdRun"], "--quiet", "--wait", "--collect", f"--unit={unit_name}", *extra]
    for line in CONFIG["properties"] + properties(name, record):
        args += ["--property", line]
    args += [f"--setenv={key}={value}" for key, value in sorted(environment(name, record, unit_name).items())]
    return args + ["--", *resolve(argv, spec["release"]["paths"])]


# Deploys


def realize(name: str, record: dict) -> None:
    """Fetches the release's store paths from the host's substituters and roots them."""
    paths = record["spec"]["release"]["paths"]
    result = run([CONFIG["bin"]["nixStore"], "--realise", *sorted(set(paths.values()))], check=False)
    if result.returncode != 0:
        raise Failed(f"the release's store paths can't be realized: {result.stderr.strip()[-500:]}")
    roots = Path(CONFIG["gcrootsDir"]) / name
    roots.mkdir(parents=True, exist_ok=True)
    for key, path in paths.items():
        link = roots / f"{record['generation']}-{key}"
        link.unlink(missing_ok=True)
        link.symlink_to(path)


def psql(sql: str) -> str:
    postgres = CONFIG["postgresql"]
    args = [CONFIG["bin"]["psql"], "-X", "-q", "-At", "-v", "ON_ERROR_STOP=1", "-h", postgres["socket"], "-p", str(postgres["port"]), "-d", "postgres"]
    return run(args, input=sql, user="postgres").stdout


def ensure_database(name: str, record: dict) -> None:
    """The service's role and database. Only its role may connect to it, with at most the
    connections its spec asks for."""
    role, limit = user(name), record["spec"]["database"]["connections"]
    psql(
        f"SELECT 'CREATE ROLE \"{role}\" LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '{role}')\\gexec\n"
        f"SELECT 'CREATE DATABASE \"{role}\" OWNER \"{role}\"' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '{role}')\\gexec\n"
        f'ALTER ROLE "{role}" CONNECTION LIMIT {limit};\n'
        f'REVOKE CONNECT, TEMPORARY ON DATABASE "{role}" FROM PUBLIC;\n'
    )


def database_exists(name: str) -> bool:
    return bool(psql(f"SELECT 1 FROM pg_database WHERE datname = '{user(name)}'").strip())


def drop_database(name: str) -> None:
    """Dumps the service's database into the backup directory's `deleted/`, then drops it and its
    role. A failed dump keeps both."""
    role = user(name)
    if psql(f"SELECT 1 FROM pg_database WHERE datname = '{role}'").strip():
        postgres = CONFIG["postgresql"]
        target = Path(CONFIG["backupDir"]) / "deleted" / f"{role}-{time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())}.dump"
        result = run(
            [CONFIG["bin"]["pgDump"], "-Fc", "-h", postgres["socket"], "-p", str(postgres["port"]), "-f", str(target), role],
            check=False, user="postgres",
        )
        if result.returncode != 0:
            raise Failed(f"the final dump of {role} failed, so the database stays: {result.stderr.strip()[-300:]}")
        log(f"fleet: {name}: dumped {role} to {target}")
    psql(f'DROP DATABASE IF EXISTS "{role}" WITH (FORCE);\nDROP ROLE IF EXISTS "{role}";\n')
    (Path(CONFIG["backupDir"]) / f"{role}.dump").unlink(missing_ok=True)


def stop_prepare(name: str) -> None:
    """Stops a `prepare` that a controller restart left behind, so the next one can start."""
    systemctl("stop", f"fleet-prepare-{name}.service", check=False)
    systemctl("reset-failed", f"fleet-prepare-{name}.service", check=False)


def prepare(name: str, record: dict) -> None:
    """Runs the candidate's `prepare` as the service's user, with its environment and credentials."""
    argv = record["spec"]["prepare"]
    if argv is None:
        return
    stop_prepare(name)
    extra = ["--pipe", "--service-type=oneshot", f"--property=TimeoutStartSec={CONFIG['prepareTimeoutSec']}"]
    started = time.monotonic()
    result = subprocess.run(
        transient(name, record, f"fleet-prepare-{name}.service", argv, extra),
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=False,
    )
    for line in result.stdout.splitlines():
        log(f"fleet: {name}: prepare: {line}")
    if result.returncode != 0:
        tail = "\n".join(result.stdout.strip().splitlines()[-10:])
        raise Failed(f"prepare exited with {result.returncode}" + (f": {tail}" if tail else ""))
    log(f"fleet: {name}: prepare took {time.monotonic() - started:.1f}s")


def probe(url: str) -> str | None:
    """None when url answers 200, otherwise what it answered. Any failure, such as a reply that is
    not HTTP, counts as unhealthy."""
    try:
        with urllib.request.urlopen(url, timeout=2) as response:
            return None if response.status == 200 else f"status {response.status}"
    except urllib.error.HTTPError as error:
        return f"status {error.code}"
    except urllib.error.URLError as error:
        return str(error.reason)
    except Exception as error:  # noqa: BLE001 - http.client raises more than URLError
        return f"{type(error).__name__}: {error}"


def healthy(name: str, record: dict, invocation_id: str) -> str | None:
    """Waits until the health path answers 200; None then, or why it didn't."""
    health = record["spec"]["health"]
    url = f"http://127.0.0.1:{port_of(name)}{health['path']}"
    deadline = time.monotonic() + health["timeoutSec"]
    last = "no answer"
    while time.monotonic() < deadline:
        active, sub = unit_state(name)
        if active in ("failed", "inactive", "deactivating") or sub == "auto-restart":
            reason = "the process exited"
            break
        last = probe(url)
        if last is None:
            return None
        time.sleep(0.2)
    else:
        reason = f"{health['path']} did not answer 200 within {health['timeoutSec']}s, last {last}"
    output = journal(invocation_id) if invocation_id else ""
    return reason + (f"; the process wrote: {output}" if output else "")


def cutover(name: str, record: dict) -> None:
    write_dropin(name, record)
    systemctl("daemon-reload")
    systemctl("reset-failed", unit(name), check=False)
    systemctl("restart", unit(name))


def prune(name: str) -> None:
    """Removes every generation but the active one: its spec, credentials and store path roots."""
    keep = active_generation(name)
    for path in (service_dir(name) / "generations").glob("*.json"):
        if int(path.stem) != keep:
            path.unlink()
    runtime = Path(CONFIG["runtimeDir"]) / name
    if runtime.is_dir():
        for path in runtime.iterdir():
            if path.name != str(keep):
                shutil.rmtree(path, ignore_errors=True)
    roots = Path(CONFIG["gcrootsDir"]) / name
    if roots.is_dir():
        for path in roots.iterdir():
            if not path.name.startswith(f"{keep}-"):
                path.unlink()


class Controller:
    """Serializes changes: one deploy per service at a time, and one change to shared files."""

    def __init__(self):
        self.lock = threading.Lock()
        self.busy: set[str] = set()

    def others(self, name: str, grant_name: str) -> tuple[list, dict]:
        """The grant's other services, each as the generation with the most memory, and every
        hostname another service on the host runs or deploys."""
        others, claimed = [], {}
        for other in services():
            specs = specs_of(other)
            if other == name or not specs:
                continue
            if grant_of(other, CONFIG["grants"])[0] == grant_name:
                others.append(max(specs, key=lambda spec: size(spec["memory"].get("max")) or 0))
            for spec in specs:
                if spec["endpoint"] is not None:
                    claimed[spec["endpoint"]["hostName"]] = other
        return others, claimed

    def postgres(self, name: str) -> dict | None:
        """The host's PostgreSQL major, its default connections per service, and how many
        connections the other services' databases leave."""
        postgres = CONFIG["postgresql"]
        if postgres is None:
            return None
        used = sum(
            max((spec["database"] or {}).get("connections", 0) for spec in specs_of(other))
            for other in services() if other != name and specs_of(other)
        )
        free = postgres["maxConnections"] - RESERVED_CONNECTIONS - used
        return {"major": postgres["major"], "free": free, "connectionLimit": postgres["connectionLimit"]}

    def check(self, name: str, spec, stored=False) -> dict:
        grant_name, grant = grant_of(name, CONFIG["grants"])
        if grant is None:
            reason = f"{name} belongs to no grant on this host"
            raise Refused([reason], [reason])
        others, claimed = self.others(name, grant_name)
        return check(name, grant_name, grant, spec, others, claimed, self.postgres(name), stored)

    def changes(self, name: str, spec: dict) -> list[str]:
        """What a spec changes against the active generation; nothing means a PUT does nothing."""
        record = active_record(name)
        if record is None:
            return ["service"]
        old = record["spec"]
        changed = [field for field in sorted(FIELDS - {"secrets"}) if spec.get(field) != old.get(field)]
        if set(spec["secrets"]) != set(old["secrets"]) or any(
            new != old["secrets"][key] if "sops" in new else "sealed" not in old["secrets"][key]
            or new["value"] != current_value(name, record["generation"], key, old["secrets"][key])
            for key, new in spec["secrets"].items()
        ):
            changed.append("secrets")
        if unit_state(name)[0] != "active":
            changed.append("process")
        return changed

    def fence(self, name: str, fence) -> None:
        """Records the highest fence a deploy lease sent; a lower one comes from a stale lease."""
        if fence is None:
            return
        if type(fence) is not int or fence < 0:
            raise Refused(["fence is a whole number"])
        path = fence_path(name)
        current = int(path.read_text()) if path.is_file() else 0
        if fence < current:
            raise Stale(f"fence {fence} is stale; the host has seen {current}")
        write_atomic(path, f"{fence}\n", 0o644)

    def plan(self, name: str, spec: dict) -> dict:
        normalized = self.check(name, spec)
        return {"name": name, "changes": self.changes(name, normalized)}

    def put(self, name: str, body: dict) -> tuple[int, dict]:
        """Accepts a spec as a new generation and deploys it in the background. A service another
        owner put is refused unless the request adopts it."""
        fence, owner, adopt = body.pop("fence", None), body.pop("owner", None), body.pop("adopt", False)
        if owner is not None and (not isinstance(owner, dict) or set(owner) != {"stack", "stage", "fqn"}
                                  or not all(isinstance(value, str) for value in owner.values())):
            raise Refused(["owner takes stack, stage and fqn"])
        with self.lock:
            self.fence(name, fence)
            if name in self.busy or tombstone(name).exists():
                raise Busy(f"{name} is deploying or being deleted")
            normalized = self.check(name, body)
            current, kept = owner_of(name), kept_owner(name)
            if owner is not None and current is not None and owner != current and adopt is not True:
                raise Refused([f"{name} belongs to {owned_by(current)}; a stack takes it over only by adopting it"])
            if kept is not False and (kept is None or owner != kept) and adopt is not True:
                left = "an operator's" if kept is None else owned_by(kept) + "'s"
                raise Refused([f"{name}'s database stays from {left} deleted service; a stack takes it over only by adopting it"])
            if kept is not False:
                # The database predates this service, so deleting the service keeps it.
                write_atomic(service_dir(name) / "drop-database", "false\n", 0o644)
                kept_path(name).unlink()
            if owner is not None:
                write_atomic(service_dir(name) / "owner.json", dumps(owner), 0o644)
            if not self.changes(name, normalized):
                (service_dir(name) / "violations").unlink(missing_ok=True)
                return 200, {**describe(name), "changed": False}
            directory = service_dir(name)
            counter = directory / "generation"
            generation = (int(counter.read_text()) if counter.is_file() else 0) + 1
            write_atomic(counter, f"{generation}\n", 0o644)
            plain = {key: source["value"] for key, source in normalized["secrets"].items() if "value" in source}
            stored = {
                **normalized,
                "secrets": {
                    key: {"sealed": seal(source["value"])} if "value" in source else source
                    for key, source in normalized["secrets"].items()
                },
            }
            port_of(name)
            says = bool(normalized["database"] and normalized["database"]["dropOnDelete"])
            drop = says if not (directory / "drop-database").exists() else drops_database(name) and says
            write_atomic(directory / "drop-database", json.dumps(drop) + "\n", 0o644)
            record = {"generation": generation, "spec": stored}
            write_atomic(directory / "generations" / f"{generation}.json", dumps(record))
            note_deploy(name, generation, stored["release"]["revision"], "deploying")
            self.busy.add(name)
        threading.Thread(target=self.deploy, args=(name, record, plain), daemon=True).start()
        return 202, {"name": name, "generation": generation, "changed": True}

    def deploy(self, name: str, record: dict, plain: dict) -> None:
        generation, revision = record["generation"], record["spec"]["release"]["revision"]
        started = time.monotonic()
        try:
            try:
                realize(name, record)
                if record["spec"]["database"] is not None:
                    ensure_database(name, record)
                write_credentials(name, generation, secret_values(record["spec"], plain))
                prepare(name, record)
            except (Failed, subprocess.CalledProcessError) as failure:
                reason = failure.stderr.strip() if isinstance(failure, subprocess.CalledProcessError) else str(failure)
                note_deploy(name, generation, revision, "failed", reason)
                return
            previous = active_record(name)
            try:
                cutover(name, record)
                reason = healthy(name, record, invocation(name))
            except Exception as error:  # noqa: BLE001 - whatever failed, the previous generation comes back
                reason = f"the controller failed after the cutover: {error}"
            if reason is None:
                with self.lock:
                    write_atomic(service_dir(name) / "active", f"{generation}\n", 0o644)
                    (service_dir(name) / "violations").unlink(missing_ok=True)
                    (service_dir(name) / "stopped").unlink(missing_ok=True)
                    write_routes()
                note_deploy(name, generation, revision, "active")
                log(f"fleet: {name}: generation {generation} took {time.monotonic() - started:.1f}s")
                return
            outcome = "failed" if previous is None else "rolled-back"
            try:
                if previous is None:
                    systemctl("stop", unit(name), check=False)
                    dropin_path(name).unlink(missing_ok=True)
                    systemctl("daemon-reload")
                elif stopped(name):
                    # An operator stopped the service, and only a successful deploy starts it again.
                    systemctl("stop", unit(name), check=False)
                    write_dropin(name, previous)
                    systemctl("daemon-reload")
                else:
                    cutover(name, previous)
            except Exception as error:  # noqa: BLE001
                outcome, reason = "broken", f"{reason}; restoring the previous generation failed too: {error}"
            note_deploy(name, generation, revision, outcome, reason)
        except Exception as error:  # noqa: BLE001 - the client waits for an outcome, whatever happened
            note_deploy(name, generation, revision, "failed", f"the controller failed before the cutover: {error}")
        finally:
            with self.lock:
                prune(name)
                self.busy.discard(name)

    def delete(self, name: str, fence, owner) -> dict | None:
        """Stops the service and removes its route and state. Its database stays unless every spec
        the host accepted for it said `dropOnDelete`, and then goes only after a final dump. A
        request from another owner deletes nothing; one without an owner comes from an operator.
        None when the service doesn't exist."""
        with self.lock:
            self.fence(name, fence)
            if name in self.busy:
                raise Busy(f"{name} is deploying")
            if not service_dir(name).is_dir():
                return None
            current = owner_of(name)
            if owner is not None and current is not None and owner != current:
                log(f"fleet: {name}: not deleted for {owned_by(owner)}, since it belongs to {owned_by(current)}")
                return {"name": name, "deleted": False, "reason": f"{name} belongs to {owned_by(current)}"}
            if not tombstone(name).exists():
                write_atomic(tombstone(name), dumps({"dropDatabase": drops_database(name), "owner": current, "at": int(time.time())}))
            drop = read_json(tombstone(name))["dropDatabase"]
            self.finish_delete(name)
            return {"name": name, "deleted": True, "databaseDropped": drop and bool(CONFIG["postgresql"])}

    def stop(self, name: str) -> dict | None:
        """Stops the service and removes its route, for operators, until its stack deploys it again;
        every stack run does, since a stopped service differs from its spec. The converge loop and
        a failed deploy's rollback leave it stopped. None when the service doesn't exist."""
        with self.lock:
            if name in self.busy:
                raise Busy(f"{name} is deploying")
            if not service_dir(name).is_dir() or tombstone(name).exists():
                return None
            write_atomic(service_dir(name) / "stopped", dumps({"by": "operator", "reason": "an operator stopped it"}), 0o644)
            systemctl("stop", unit(name), check=False)
            write_routes()
            log(f"fleet: {name}: stopped by an operator")
            return describe(name)

    def finish_delete(self, name: str) -> None:
        """Carries out a deletion its tombstone records; at start, one a restart interrupted. A
        database it keeps stays its owner's: another stack reuses it only by adopting it."""
        record = read_json(tombstone(name))
        drop = record["dropDatabase"]
        systemctl("stop", unit(name), check=False)
        stop_prepare(name)
        shutil.rmtree(dropin_path(name).parent, ignore_errors=True)
        systemctl("daemon-reload")
        write_routes()
        if drop and CONFIG["postgresql"]:
            drop_database(name)
        elif CONFIG["postgresql"] and database_exists(name):
            write_atomic(kept_path(name), dumps({"owner": record.get("owner"), "at": record["at"]}), 0o644)
        shutil.rmtree(Path(CONFIG["runtimeDir"]) / name, ignore_errors=True)
        shutil.rmtree(Path(CONFIG["gcrootsDir"]) / name, ignore_errors=True)
        shutil.rmtree(service_dir(name))
        log(f"fleet: {name}: deleted" + (", and its database dropped" if drop else ", its database kept"))

    def restore(self, decrypt_secrets: bool = True) -> int:
        """Brings every service in line with its active generation: credentials, drop-ins, a running
        process. A service whose grant no longer has room for it, in count, memory, hostnames or
        connections, keeps running and records the violations, which refuse its next PUT. One whose
        grant revokes a permission it uses, or that is gone, stops and loses its route until the
        grant allows it again. One an operator stopped stays stopped. A secret that can't be
        decrypted keeps the credentials the service has. Finishes deletions a restart interrupted.
        The number of services that failed.

        Without `decrypt_secrets`, credentials that exist stay as they are. A changed SOPS file
        arrives with a switch, which restarts the controller and restores with them."""
        failures, reload, restart, start = 0, False, [], []
        with self.lock:
            for name in services():
                if name in self.busy:
                    continue
                try:
                    if tombstone(name).exists():
                        self.finish_delete(name)
                        continue
                    for entry in deploys(name):
                        if entry["outcome"] == "deploying":
                            stop_prepare(name)
                            note_deploy(name, entry["generation"], entry["revision"], "failed", "the controller restarted during the deploy")
                    prune(name)
                    record = active_record(name)
                    if record is None:
                        continue
                    held = stopped(name)
                    try:
                        self.check(name, record["spec"], stored=True)
                        (service_dir(name) / "violations").unlink(missing_ok=True)
                        if held and held["by"] == "grant":
                            log(f"fleet: {name}: its grant allows it again")
                            (service_dir(name) / "stopped").unlink()
                            held = None
                    except Refused as refused:
                        if violations(name) != refused.reasons:
                            write_atomic(service_dir(name) / "violations", json.dumps(refused.reasons) + "\n", 0o644)
                            if not refused.revoked:
                                log(f"fleet: {name}: keeps running, but its grant has no room for it: {refused}")
                        if refused.revoked:
                            reason = "; ".join(refused.revoked)
                            if held != {"by": "grant", "reason": reason}:
                                log(f"fleet: {name}: stopped, since its grant no longer permits it: {reason}")
                                write_atomic(service_dir(name) / "stopped", dumps({"by": "grant", "reason": reason}), 0o644)
                            systemctl("stop", unit(name), check=False)
                            continue
                    if held:
                        if unit_state(name)[0] in ("active", "activating", "reloading"):
                            log(f"fleet: {name}: stopping again, since {held['reason']}")
                            systemctl("stop", unit(name), check=False)
                        continue
                    rewritten = False
                    credentials = credentials_dir(name, record["generation"])
                    if decrypt_secrets or not credentials.is_dir():
                        try:
                            rewritten = write_credentials(name, record["generation"], secret_values(record["spec"]))
                        except (Failed, subprocess.CalledProcessError) as error:
                            failures += 1
                            reason = error.stderr.strip() if isinstance(error, subprocess.CalledProcessError) else str(error)
                            if not credentials.is_dir():
                                log(f"fleet: {name}: can't start without its secrets: {reason}")
                                continue
                            log(f"fleet: {name}: keeps its credentials, since {reason}")
                    dropped_in = write_dropin(name, record)
                    reload = reload or dropped_in
                    if rewritten or dropped_in:
                        restart.append(name)
                    elif unit_state(name)[0] not in ("active", "activating", "reloading"):
                        start.append(name)
                except Exception as error:  # noqa: BLE001 - one broken service must not stop the others
                    failures += 1
                    log(f"fleet: {name}: not restored: {error}")
            if reload:
                systemctl("daemon-reload", check=False)
            write_routes()
        for name in restart + start:
            # A stop that came in meanwhile wins: it either lands before this check, or its stop job
            # queues behind this restart job.
            with self.lock:
                if name in self.busy or stopped(name) or tombstone(name).exists():
                    continue
                log(f"fleet: {name}: {'restarting with new credentials or settings' if name in restart else 'starting'}")
                systemctl("reset-failed", unit(name), check=False)
                systemctl("restart", "--no-block", unit(name), check=False)
        return failures


# Routes and status


def owned_by(owner: dict) -> str:
    return f"{owner['fqn']} in stack {owner['stack']}, stage {owner['stage']}"


def write_routes() -> None:
    """The route file the host's runtime ingress reads: one entry per active service with an
    endpoint, proxied with the ingress's defaults."""
    routes = []
    for name in services():
        record = active_record(name)
        if record is None or record["spec"]["endpoint"] is None or tombstone(name).exists() or stopped(name):
            continue
        endpoint = record["spec"]["endpoint"]
        routes.append({"name": name, "hostName": endpoint["hostName"], "visibility": endpoint["visibility"], "upstreamPort": port_of(name)})
    write_atomic(Path(CONFIG["routesFile"]), json.dumps(routes, indent=2) + "\n", 0o644)


def describe(name: str) -> dict:
    """What the service runs: the API's and `fleet status`'s view."""
    record = active_record(name)
    spec = record["spec"] if record else None
    endpoint = spec["endpoint"] if spec else None
    active, sub = unit_state(name)
    return {
        "name": name,
        "owner": owner_of(name),
        "violations": violations(name),
        "stopped": stopped(name),
        "unit": unit(name),
        "user": user(name),
        "revision": spec["release"]["revision"] if spec else None,
        "generation": record["generation"] if record else None,
        "state": f"{active} ({sub})",
        "url": f"https://{endpoint['hostName']}" if endpoint else None,
        "visibility": endpoint["visibility"] if endpoint else None,
        "port": port_of(name) if (service_dir(name) / "port").is_file() else None,
        "database": user(name) if spec and spec["database"] else None,
        "memory": spec["memory"] if spec else {},
        "address": CONFIG["addresses"],
        "deploys": deploys(name),
    }


# HTTP


def token_for(key: bytes, grant: str) -> str:
    """A grant's own token: whoever holds it can change that grant's services only."""
    return hmac.new(key, grant.encode(), hashlib.sha256).hexdigest()


def authorized(header: str, name: str) -> bool:
    """Whether the bearer token is the host's token or the grant's. An empty token or key never
    authorizes anything."""
    if not header.startswith("Bearer "):
        return False
    given = header.removeprefix("Bearer ").strip()
    if not given:
        return False
    admin = Path(CONFIG["tokenFile"]).read_text().strip() if CONFIG.get("tokenFile") else ""
    if admin and hmac.compare_digest(given, admin):
        return True
    grant_name, _ = grant_of(name, CONFIG["grants"])
    key = Path(CONFIG["grantKeyFile"]).read_bytes().strip() if CONFIG.get("grantKeyFile") else b""
    return grant_name is not None and bool(key) and hmac.compare_digest(given, token_for(key, grant_name))


def handler(controller: Controller, operator: bool = False):
    """The API. Over TCP, a PUT or DELETE names its owner. On the operator socket, which only root
    reaches, requests need no token or owner, and `POST /services/<name>/stop` stops a service."""

    class Handler(BaseHTTPRequestHandler):
        server_version = "fleet-controller"

        def address_string(self):
            return "operator" if operator else super().address_string()

        def log_message(self, fmt, *args):
            log("%s - %s" % (self.address_string(), fmt % args))

        def send_json(self, status: int, payload) -> None:
            body = json.dumps(payload).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def route(self, method: str) -> None:
            if method == "GET" and self.path == "/health":
                return self.send_json(200, {"ok": True})
            match = re.fullmatch(r"/services/([^/]+)(/plan|/stop)?", self.path)
            if match is None or (match[2] == "/stop" and not operator):
                return self.send_json(404, {"error": "not found"})
            name, action = match[1], match[2]
            if not NAME.fullmatch(name):
                return self.send_json(404, {"error": "not a service name", "name": name})
            if (method == "POST") != (action is not None) or method not in ("GET", "PUT", "POST", "DELETE"):
                return self.send_json(405, {"error": "method not allowed"})
            if not operator and not authorized(self.headers.get("Authorization", ""), name):
                return self.send_json(403, {"error": "forbidden"})
            body = None
            length = int(self.headers.get("Content-Length") or 0)
            if length > 1024 * 1024:
                return self.send_json(413, {"error": "a spec is at most 1 MiB"})
            if length:
                try:
                    body = json.loads(self.rfile.read(length))
                except json.JSONDecodeError:
                    return self.send_json(400, {"error": "invalid json"})
            try:
                if method == "GET":
                    if not service_dir(name).is_dir() or tombstone(name).exists():
                        kept = kept_owner(name)
                        return self.send_json(404, {"error": "no such service", "name": name, **({} if kept is False else {"kept": {"owner": kept}})})
                    return self.send_json(200, describe(name))
                if method == "DELETE":
                    body = body if isinstance(body, dict) else {}
                    if not operator and body.get("owner") is None:
                        return self.send_json(400, {"error": "a request names its owner; operators use fleet delete"})
                    result = controller.delete(name, body.get("fence"), body.get("owner"))
                    return self.send_json(404 if result is None else 200, result or {"name": name})
                if action == "/stop":
                    result = controller.stop(name)
                    return self.send_json(404 if result is None else 200, result or {"name": name})
                if not isinstance(body, dict):
                    return self.send_json(400, {"error": "the body is a service spec"})
                if action == "/plan":
                    for field in ("fence", "owner", "adopt"):
                        body.pop(field, None)
                    return self.send_json(200, controller.plan(name, body))
                if not operator and body.get("owner") is None:
                    return self.send_json(400, {"error": "a request names its owner, as Fleet.Service sends it"})
                status, payload = controller.put(name, body)
                return self.send_json(status, payload)
            except Refused as refused:
                return self.send_json(422, {"error": "refused", "reasons": refused.reasons})
            except Busy as busy:
                return self.send_json(423, {"error": str(busy)})
            except Stale as stale:
                return self.send_json(409, {"error": str(stale)})
            except Failed as failed:
                return self.send_json(500, {"error": str(failed)})

        def do_GET(self):
            self.route("GET")

        def do_PUT(self):
            self.route("PUT")

        def do_POST(self):
            self.route("POST")

        def do_DELETE(self):
            self.route("DELETE")

    return Handler


class OperatorServer(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


def load_config() -> None:
    CONFIG.update(read_json(Path(os.environ["FLEET_CONFIG"])))


def serve() -> None:
    controller = Controller()
    failures = controller.restore()
    if failures:
        log(f"fleet: {failures} services could not be restored")

    def converge():
        while True:
            time.sleep(CONVERGE_SECONDS)
            try:
                controller.restore(decrypt_secrets=False)
            except Exception as error:  # noqa: BLE001 - the next round tries again
                log(f"fleet: converging failed: {error}")

    threading.Thread(target=converge, daemon=True).start()

    socket_path = Path(CONFIG["operatorSocket"])
    socket_path.parent.mkdir(parents=True, exist_ok=True)
    socket_path.unlink(missing_ok=True)
    operators = OperatorServer(str(socket_path), handler(controller, operator=True))
    os.chmod(socket_path, 0o600)
    threading.Thread(target=operators.serve_forever, daemon=True).start()

    listen = CONFIG["listen"]
    log(f"fleet: listening on {listen['host']}:{listen['port']}")
    ThreadingHTTPServer((listen["host"], listen["port"]), handler(controller)).serve_forever()


if __name__ == "__main__":
    load_config()
    if sys.argv[1:] == ["serve"]:
        serve()
    else:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        sys.exit(64)
