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

CONFIG: dict = {}


class Refused(Exception):
    """A spec the grant or this host doesn't allow, with every reason."""

    def __init__(self, reasons):
        super().__init__("; ".join(reasons))
        self.reasons = reasons


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


def check(name: str, grant_name: str, grant: dict, spec, others: list, claimed: dict, postgres_major, stored=False) -> dict:
    """The spec as the controller keeps it, or Refused with every way it breaks the grant.

    `others` are the latest specs of the grant's other services, for its service count and memory
    ceiling. `claimed` maps the hostnames of every other service on the host to that service. A
    `stored` spec carries sealed secret values instead of plain ones.
    """
    if not isinstance(spec, dict):
        raise Refused(["a service is a JSON object"])
    reasons = [f"unknown field {field}" for field in sorted(set(spec) - FIELDS)]

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
                reasons.append(f"{grant_name} may not claim {host}")
            elif host in claimed:
                reasons.append(f"{host} belongs to the service {claimed[host]}")
            if visibility not in ("public", "tailnet"):
                reasons.append("visibility is public or tailnet")
            elif visibility == "public" and not grant["public"]:
                reasons.append(f"{grant_name} may not be public")
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
        if not isinstance(database, dict) or set(database) - {"env", "majorVersion"}:
            reasons.append("database takes env and majorVersion")
            database = None
        else:
            if not grant["databases"]:
                reasons.append(f"{grant_name} may not have databases")
            major = database.get("majorVersion")
            if major is not None and major != postgres_major:
                reasons.append(f"the service needs PostgreSQL {major}, and this host runs {postgres_major}")
            database = {"env": database.get("env", "DATABASE_URL")}
            if not isinstance(database["env"], str) or not ENV_NAME.fullmatch(database["env"]):
                reasons.append(f"database env {database['env']!r} is not a variable name")

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
                reasons.append(f"secret {key} reads {path!r}, which is not a SOPS key such as projects/{grant_name}/{key.lower()}")
            elif not any(path.startswith(prefix) for prefix in grant["secretPrefixes"]):
                allowed = " or ".join(grant["secretPrefixes"]) or "no prefix"
                reasons.append(f"secret {key} may not read {path}; {grant_name} reads keys under {allowed}")
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
        raise Refused(reasons)
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


# State: /var/lib/fleet/services/<name>/{generations/<g>.json, active, port, fence, deploys.json}


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


def latest_spec(name: str) -> dict | None:
    """The spec of the service's newest generation: the active one, or the one being deployed."""
    directory = service_dir(name) / "generations"
    generations = sorted(int(path.stem) for path in directory.glob("*.json")) if directory.is_dir() else []
    return record_of(name, generations[-1])["spec"] if generations else None


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


def ensure_database(name: str) -> None:
    role = user(name)
    psql(
        f"SELECT 'CREATE ROLE \"{role}\" LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '{role}')\\gexec\n"
        f"SELECT 'CREATE DATABASE \"{role}\" OWNER \"{role}\"' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '{role}')\\gexec\n"
    )


def drop_database(name: str) -> None:
    role = user(name)
    psql(f'DROP DATABASE IF EXISTS "{role}" WITH (FORCE);\nDROP ROLE IF EXISTS "{role}";\n')
    (Path(CONFIG["backupDir"]) / f"{role}.dump").unlink(missing_ok=True)


def prepare(name: str, record: dict) -> None:
    """Runs the candidate's `prepare` as the service's user, with its environment and credentials."""
    argv = record["spec"]["prepare"]
    if argv is None:
        return
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


def healthy(name: str, record: dict, invocation_id: str) -> str | None:
    """Waits until the health path answers 200; None then, or why it didn't."""
    health = record["spec"]["health"]
    url = f"http://127.0.0.1:{port_of(name)}{health['path']}"
    deadline = time.monotonic() + health["timeoutSec"]
    last = "no answer"
    while time.monotonic() < deadline:
        active, sub = unit_state(name)
        if active == "failed" or sub == "auto-restart":
            reason = "the process exited"
            break
        try:
            with urllib.request.urlopen(url, timeout=2) as response:
                if response.status == 200:
                    return None
                last = f"status {response.status}"
        except urllib.error.HTTPError as error:
            last = f"status {error.code}"
        except (urllib.error.URLError, OSError) as error:
            last = str(getattr(error, "reason", error))
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
        others, claimed = [], {}
        for other in services():
            spec = latest_spec(other)
            if other == name or spec is None:
                continue
            if grant_of(other, CONFIG["grants"])[0] == grant_name:
                others.append(spec)
            if spec["endpoint"] is not None:
                claimed[spec["endpoint"]["hostName"]] = other
        return others, claimed

    def check(self, name: str, spec, stored=False) -> dict:
        grant_name, grant = grant_of(name, CONFIG["grants"])
        if grant is None:
            raise Refused([f"{name} belongs to no grant on this host"])
        others, claimed = self.others(name, grant_name)
        major = CONFIG["postgresql"]["major"] if CONFIG["postgresql"] else None
        return check(name, grant_name, grant, spec, others, claimed, major, stored)

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
        path = service_dir(name) / "fence"
        current = int(path.read_text()) if path.is_file() else 0
        if fence < current:
            raise Stale(f"fence {fence} is stale; the host has seen {current}")
        write_atomic(path, f"{fence}\n", 0o644)

    def plan(self, name: str, spec) -> dict:
        normalized = self.check(name, spec)
        return {"name": name, "changes": self.changes(name, normalized)}

    def put(self, name: str, spec, fence) -> tuple[int, dict]:
        with self.lock:
            if name in self.busy:
                raise Busy(f"{name} is deploying generation {deploys(name)[0]['generation']}")
            normalized = self.check(name, spec)
            self.fence(name, fence)
            if not self.changes(name, normalized):
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
                    ensure_database(name)
                write_credentials(name, generation, secret_values(record["spec"], plain))
                prepare(name, record)
            except (Failed, subprocess.CalledProcessError) as failure:
                reason = failure.stderr.strip() if isinstance(failure, subprocess.CalledProcessError) else str(failure)
                note_deploy(name, generation, revision, "failed", reason)
                return
            previous = active_record(name)
            cutover(name, record)
            reason = healthy(name, record, invocation(name))
            if reason is None:
                with self.lock:
                    write_atomic(service_dir(name) / "active", f"{generation}\n", 0o644)
                    write_routes()
                note_deploy(name, generation, revision, "active")
                log(f"fleet: {name}: generation {generation} took {time.monotonic() - started:.1f}s")
            elif previous is not None:
                cutover(name, previous)
                note_deploy(name, generation, revision, "rolled-back", reason)
            else:
                systemctl("stop", unit(name), check=False)
                dropin_path(name).unlink(missing_ok=True)
                systemctl("daemon-reload")
                note_deploy(name, generation, revision, "failed", reason)
        except Exception as error:  # noqa: BLE001 - the client waits for an outcome, whatever happened
            note_deploy(name, generation, revision, "failed", f"the controller failed: {error}")
        finally:
            with self.lock:
                prune(name)
                self.busy.discard(name)

    def delete(self, name: str, fence) -> bool:
        with self.lock:
            if name in self.busy:
                raise Busy(f"{name} is deploying")
            if not service_dir(name).is_dir():
                return False
            self.fence(name, fence)
            systemctl("stop", unit(name), check=False)
            shutil.rmtree(dropin_path(name).parent, ignore_errors=True)
            systemctl("daemon-reload")
            if CONFIG["postgresql"]:
                drop_database(name)
            shutil.rmtree(Path(CONFIG["runtimeDir"]) / name, ignore_errors=True)
            shutil.rmtree(Path(CONFIG["gcrootsDir"]) / name, ignore_errors=True)
            shutil.rmtree(service_dir(name))
            write_routes()
            log(f"fleet: {name}: deleted")
            return True

    def restore(self, decrypt_secrets: bool = True) -> int:
        """Brings every service in line with its active generation: credentials, drop-ins, a running
        process. A service its grant no longer allows stops, and keeps its state and database. The
        number of services that failed.

        Without `decrypt_secrets`, credentials that exist stay as they are. A changed SOPS file
        arrives with a switch, which restarts the controller and restores with them."""
        failures, reload, restart, start = 0, False, [], []
        with self.lock:
            for name in services():
                if name in self.busy:
                    continue
                for entry in deploys(name):
                    if entry["outcome"] == "deploying":
                        note_deploy(name, entry["generation"], entry["revision"], "failed", "the controller restarted during the deploy")
                prune(name)
                record = active_record(name)
                if record is None:
                    continue
                refused = service_dir(name) / "refused"
                try:
                    self.check(name, record["spec"], stored=True)
                    rewritten = False
                    if decrypt_secrets or not credentials_dir(name, record["generation"]).is_dir():
                        rewritten = write_credentials(name, record["generation"], secret_values(record["spec"]))
                    dropped_in = write_dropin(name, record)
                except (Refused, Failed, subprocess.CalledProcessError) as error:
                    failures += 1
                    if not refused.is_file():
                        log(f"fleet: {name}: stopped, since {error}")
                        write_atomic(refused, f"{error}\n", 0o644)
                    systemctl("stop", unit(name), check=False)
                    if dropin_path(name).is_file():
                        dropin_path(name).unlink()
                        reload = True
                    continue
                refused.unlink(missing_ok=True)
                reload = reload or dropped_in
                if rewritten or dropped_in:
                    restart.append(name)
                elif unit_state(name)[0] not in ("active", "activating", "reloading"):
                    start.append(name)
            if reload:
                systemctl("daemon-reload")
            write_routes()
        for name in restart + start:
            log(f"fleet: {name}: {'restarting with new credentials or settings' if name in restart else 'starting'}")
            systemctl("reset-failed", unit(name), check=False)
            systemctl("restart", unit(name), check=False)
        return failures


# Routes and status


def write_routes() -> None:
    """The route file the host's runtime ingress reads, and the Caddy site each route imports."""
    sites = Path(CONFIG["sitesDir"])
    sites.mkdir(parents=True, exist_ok=True)
    routes = []
    for name in services():
        record = active_record(name)
        site = sites / f"{name}.caddy"
        if record is None or record["spec"]["endpoint"] is None or (service_dir(name) / "refused").is_file():
            site.unlink(missing_ok=True)
            continue
        endpoint, port = record["spec"]["endpoint"], port_of(name)
        write_atomic(site, f"encode zstd gzip\nreverse_proxy 127.0.0.1:{port}\n", 0o644)
        routes.append({"name": name, "hostName": endpoint["hostName"], "visibility": endpoint["visibility"], "upstreamPort": port, "site": str(site)})
    for site in sites.glob("*.caddy"):
        if not (service_dir(site.stem) / "active").is_file():
            site.unlink()
    write_atomic(Path(CONFIG["routesFile"]), json.dumps(routes, indent=2) + "\n", 0o644)


def describe(name: str) -> dict:
    """What the service runs: the API's and `fleet status`'s view."""
    record = active_record(name)
    spec = record["spec"] if record else None
    endpoint = spec["endpoint"] if spec else None
    active, sub = unit_state(name)
    refused = service_dir(name) / "refused"
    return {
        "name": name,
        "refused": refused.read_text().strip() if refused.is_file() else None,
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
    if not header.startswith("Bearer "):
        return False
    given = header.removeprefix("Bearer ").strip()
    if CONFIG.get("tokenFile") and hmac.compare_digest(given, Path(CONFIG["tokenFile"]).read_text().strip()):
        return True
    grant_name, _ = grant_of(name, CONFIG["grants"])
    if grant_name is None or not CONFIG.get("grantKeyFile"):
        return False
    return hmac.compare_digest(given, token_for(Path(CONFIG["grantKeyFile"]).read_bytes().strip(), grant_name))


def handler(controller: Controller):
    class Handler(BaseHTTPRequestHandler):
        server_version = "fleet-controller"

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
            match = re.fullmatch(r"/services/([^/]+)(/plan)?", self.path)
            if match is None:
                return self.send_json(404, {"error": "not found"})
            name, planning = match[1], match[2] is not None
            if not NAME.fullmatch(name):
                return self.send_json(404, {"error": "not a service name", "name": name})
            if (method == "POST") != planning or method not in ("GET", "PUT", "POST", "DELETE"):
                return self.send_json(405, {"error": "method not allowed"})
            if not authorized(self.headers.get("Authorization", ""), name):
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
                    if not service_dir(name).is_dir():
                        return self.send_json(404, {"error": "no such service", "name": name})
                    return self.send_json(200, describe(name))
                if method == "DELETE":
                    fence = self.headers.get("X-Fleet-Fence")
                    deleted = controller.delete(name, None if fence is None else int(fence))
                    return self.send_json(200 if deleted else 404, {"name": name})
                if not isinstance(body, dict):
                    return self.send_json(400, {"error": "the body is a service spec"})
                fence = body.pop("fence", None)
                if planning:
                    return self.send_json(200, controller.plan(name, body))
                status, payload = controller.put(name, body, fence)
                return self.send_json(status, payload)
            except Refused as refused:
                return self.send_json(422, {"error": "refused", "reasons": refused.reasons})
            except Busy as busy:
                return self.send_json(423, {"error": str(busy)})
            except Stale as stale:
                return self.send_json(409, {"error": str(stale)})
            except ValueError:
                return self.send_json(400, {"error": "X-Fleet-Fence is a whole number"})

        def do_GET(self):
            self.route("GET")

        def do_PUT(self):
            self.route("PUT")

        def do_POST(self):
            self.route("POST")

        def do_DELETE(self):
            self.route("DELETE")

    return Handler


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
            controller.restore(decrypt_secrets=False)

    threading.Thread(target=converge, daemon=True).start()
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
