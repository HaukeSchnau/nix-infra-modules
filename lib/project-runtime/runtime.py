#!/usr/bin/env python3
"""Portable Project Runtime dispatcher and local Development adapter."""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import hashlib
import json
import os
import pathlib
import re
import socket
import subprocess
import sys
import tempfile
import time
from collections.abc import Iterator, Mapping, Sequence
from typing import Any, NoReturn


NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,62}$")
CREDENTIAL_RE = re.compile(r"^[A-Za-z0-9_.-]+$")


class RuntimeFailure(RuntimeError):
    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status = status


def fail(status: int, message: str) -> NoReturn:
    raise RuntimeFailure(status, message)


def load_json(path: pathlib.Path, *, label: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(65, f"{label} {path}: {error}")
    if not isinstance(value, dict):
        fail(65, f"{label} {path}: root must be an object")
    return value


def atomic_json(path: pathlib.Path, value: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(value, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(temporary)


@contextlib.contextmanager
def exclusive_lock(path: pathlib.Path) -> Iterator[None]:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with path.open("a+", encoding="utf-8") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def require_string(value: Any, pointer: str) -> str:
    if not isinstance(value, str) or not value:
        fail(65, f"runtime manifest {pointer}: must be a non-empty string")
    return value


def require_absolute_path(value: Any, pointer: str) -> str:
    result = require_string(value, pointer)
    if not pathlib.Path(result).is_absolute():
        fail(65, f"runtime manifest {pointer}: must be an absolute path")
    return result


def validate_manifest(raw: Mapping[str, Any], config: Mapping[str, Any]) -> dict[str, Any]:
    schema_version = raw.get("schemaVersion")
    if schema_version not in (1, 2):
        fail(65, "runtime manifest /schemaVersion: unsupported version")
    descriptor_schema_version = config.get("descriptorSchemaVersion", 1)
    if schema_version == 2 and descriptor_schema_version != 2:
        fail(65, "runtime manifest /schemaVersion: version 2 requires a v2 Project descriptor")

    allowed_root = {
        "schemaVersion",
        "project",
        "realization",
        "paths",
        "endpoints",
        "parameters",
        "settings",
        "secrets",
    }
    if schema_version == 2:
        allowed_root.remove("settings")
    unknown_root = set(raw) - allowed_root
    if unknown_root:
        fail(65, "runtime manifest: unknown fields: " + ", ".join(sorted(unknown_root)))
    if raw.get("project") != config["project"]:
        fail(
            65,
            f"runtime manifest /project: expected {config['project']}, got {raw.get('project')}",
        )
    if raw.get("realization") != config["realization"]:
        fail(
            65,
            "runtime manifest /realization: "
            f"expected {config['realization']}, got {raw.get('realization')}",
        )

    paths = raw.get("paths")
    if not isinstance(paths, dict):
        fail(65, "runtime manifest /paths: must be an object")
    unknown_paths = set(paths) - {"checkout", "state", "cache", "runtime"}
    if unknown_paths:
        fail(65, "runtime manifest /paths: unknown fields: " + ", ".join(sorted(unknown_paths)))
    required_paths = ["state", "runtime"]
    if config["realization"] == "development":
        required_paths.extend(["checkout", "cache"])
    normalized_paths = dict(paths)
    for name in required_paths:
        normalized_paths[name] = require_absolute_path(paths.get(name), f"/paths/{name}")

    endpoints = raw.get("endpoints")
    if not isinstance(endpoints, dict):
        fail(65, "runtime manifest /endpoints: must be an object")
    normalized_endpoints: dict[str, Any] = {}
    for name, endpoint in endpoints.items():
        if not NAME_RE.fullmatch(name) or not isinstance(endpoint, dict):
            fail(65, f"runtime manifest /endpoints/{name}: invalid Endpoint")
        allowed_endpoint = {"url", "listen", "hostNames", "visibility"}
        if schema_version == 2:
            allowed_endpoint.add("protocol")
        unknown_endpoint = set(endpoint) - allowed_endpoint
        if unknown_endpoint:
            fail(
                65,
                f"runtime manifest /endpoints/{name}: unknown fields: "
                + ", ".join(sorted(unknown_endpoint)),
            )
        listen = endpoint.get("listen")
        if not isinstance(listen, dict):
            fail(65, f"runtime manifest /endpoints/{name}/listen: must be an object")
        unknown_listen = set(listen) - {"host", "port"}
        if unknown_listen:
            fail(
                65,
                f"runtime manifest /endpoints/{name}/listen: unknown fields: "
                + ", ".join(sorted(unknown_listen)),
            )
        host = require_string(listen.get("host"), f"/endpoints/{name}/listen/host")
        port = listen.get("port")
        if not isinstance(port, int) or isinstance(port, bool) or not 1 <= port <= 65535:
            fail(65, f"runtime manifest /endpoints/{name}/listen/port: invalid port")
        protocol = "http" if schema_version == 1 else endpoint.get("protocol")
        if protocol not in ("http", "tcp"):
            fail(65, f"runtime manifest /endpoints/{name}/protocol: must be http or tcp")
        if protocol == "http":
            url = require_string(endpoint.get("url"), f"/endpoints/{name}/url")
            host_names = endpoint.get("hostNames", [])
            if not isinstance(host_names, list) or not all(
                isinstance(item, str) and item for item in host_names
            ) or len(host_names) != len(set(host_names)):
                fail(65, f"runtime manifest /endpoints/{name}/hostNames: invalid list")
            visibility = endpoint.get("visibility")
            if visibility is not None and visibility not in ("local", "tailnet", "public"):
                fail(65, f"runtime manifest /endpoints/{name}/visibility: invalid value")
            normalized_endpoints[name] = {
                **endpoint,
                "url": url,
                "hostNames": host_names,
                "listen": {**listen, "host": host, "port": port},
            }
        else:
            publication_fields = set(endpoint) & {"url", "hostNames", "visibility"}
            if publication_fields:
                fail(
                    65,
                    f"runtime manifest /endpoints/{name}: TCP Endpoints cannot declare publication fields: "
                    + ", ".join(sorted(publication_fields)),
                )
            normalized_endpoints[name] = {
                "protocol": protocol,
                "listen": {**listen, "host": host, "port": port},
            }
    expected_endpoint_names = config.get("endpoints")
    if expected_endpoint_names is not None:
        expected_endpoints = set(expected_endpoint_names)
        actual_endpoints = set(normalized_endpoints)
        if actual_endpoints != expected_endpoints:
            missing = ", ".join(sorted(expected_endpoints - actual_endpoints))
            extra = ", ".join(sorted(actual_endpoints - expected_endpoints))
            fail(
                65,
                "runtime manifest /endpoints: does not match descriptor"
                f" (missing: {missing or '-'}; extra: {extra or '-'})",
            )
        expected_protocols = config.get(
            "endpointProtocols", {name: "http" for name in expected_endpoint_names}
        )
        mismatched_protocols = sorted(
            name
            for name, endpoint in normalized_endpoints.items()
            if endpoint.get("protocol", "http") != expected_protocols.get(name, "http")
        )
        if mismatched_protocols:
            fail(
                65,
                "runtime manifest /endpoints: protocols do not match descriptor: "
                + ", ".join(mismatched_protocols),
            )

    if "parameters" in raw and "settings" in raw:
        fail(65, "runtime manifest: set parameters, not both parameters and legacy settings")
    parameters = raw.get("parameters", raw.get("settings", {}))
    if not isinstance(parameters, dict):
        fail(65, "runtime manifest /parameters: must be an object")
    definitions = config.get("parameterDefinitions", {})
    unknown_parameters = set(parameters) - set(definitions)
    if unknown_parameters:
        fail(
            65,
            "runtime manifest /parameters: unknown names: "
            + ", ".join(sorted(unknown_parameters)),
        )
    normalized_parameters: dict[str, Any] = {}
    for name, definition in definitions.items():
        if name in parameters:
            parameter = parameters[name]
        elif "default" in definition:
            parameter = definition["default"]
        elif definition["required"]:
            fail(66, f"Project parameter is required: {name}")
        else:
            parameter = None
        parameter_type = definition["type"]
        valid = (
            parameter is None
            and not definition["required"]
            or parameter_type == "boolean"
            and isinstance(parameter, bool)
            or parameter_type == "integer"
            and isinstance(parameter, int)
            and not isinstance(parameter, bool)
            or parameter_type == "number"
            and isinstance(parameter, (int, float))
            and not isinstance(parameter, bool)
            or parameter_type == "string"
            and isinstance(parameter, str)
        )
        if not valid:
            fail(65, f"runtime manifest /parameters/{name}: expected {parameter_type}")
        normalized_parameters[name] = parameter

    secrets = raw.get("secrets", {})
    if not isinstance(secrets, dict):
        fail(65, "runtime manifest /secrets: must be an object")
    for name, credential in secrets.items():
        if not CREDENTIAL_RE.fullmatch(name):
            fail(65, f"runtime manifest /secrets/{name}: invalid semantic name")
        if not isinstance(credential, str) or not CREDENTIAL_RE.fullmatch(credential):
            fail(66, f"runtime manifest /secrets/{name}: unsafe credential filename")
    unknown_secrets = set(secrets) - set(config.get("secrets", []))
    if unknown_secrets:
        fail(
            65,
            "runtime manifest /secrets: undeclared names: "
            + ", ".join(sorted(unknown_secrets)),
        )

    return {
        **raw,
        "paths": normalized_paths,
        "endpoints": normalized_endpoints,
        "parameters": normalized_parameters,
        "secrets": secrets,
    }


def runtime_root() -> pathlib.Path:
    configured = os.environ.get("XDG_RUNTIME_DIR")
    if configured:
        return pathlib.Path(configured) / "project-runtime"
    return pathlib.Path(os.environ.get("TMPDIR", "/tmp")) / f"project-runtime-{os.getuid()}"


def port_available(port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        try:
            listener.bind(("127.0.0.1", port))
        except OSError:
            return False
    return True


def local_manifest(config: Mapping[str, Any]) -> pathlib.Path:
    checkout = pathlib.Path.cwd().resolve()
    identity = hashlib.sha256(str(checkout).encode()).hexdigest()[:20]
    root = runtime_root() / config["project"] / identity
    manifest_path = root / "runtime.json"
    state = pathlib.Path(
        os.environ.get("XDG_STATE_HOME", pathlib.Path.home() / ".local/state")
    ) / config["project"] / "instances" / identity
    cache = pathlib.Path(
        os.environ.get("XDG_CACHE_HOME", pathlib.Path.home() / ".cache")
    ) / config["project"] / "instances" / identity

    with exclusive_lock(runtime_root() / "local-allocations.lock"):
        target_schema_version = config.get("descriptorSchemaVersion", 1)
        if manifest_path.exists():
            existing = load_json(manifest_path, label="runtime manifest")
            if (
                existing.get("schemaVersion") == target_schema_version
                and existing.get("paths", {}).get("checkout") == str(checkout)
            ):
                validate_manifest(existing, config)
                return manifest_path

        endpoints: dict[str, Any] = {}
        used: set[int] = set()
        for candidate in runtime_root().glob("*/*/runtime.json"):
            if candidate == manifest_path:
                continue
            try:
                allocated = load_json(candidate, label="local runtime manifest")
                allocated_checkout = pathlib.Path(allocated["paths"]["checkout"])
                if allocated_checkout.exists():
                    used.update(
                        endpoint["listen"]["port"]
                        for endpoint in allocated.get("endpoints", {}).values()
                    )
            except (KeyError, TypeError, RuntimeFailure):
                continue
        start, end = config["localPortRange"]
        size = end - start + 1
        for name in sorted(config["endpoints"]):
            protocol = config.get("endpointProtocols", {}).get(name, "http")
            offset = int(
                hashlib.sha256(f"{checkout}/{name}".encode()).hexdigest()[:8], 16
            ) % size
            for step in range(size):
                candidate = start + ((offset + step) % size)
                if candidate not in used and port_available(candidate):
                    used.add(candidate)
                    if target_schema_version == 1:
                        endpoint = {
                            "url": f"http://127.0.0.1:{candidate}",
                            "hostNames": [],
                            "visibility": "local",
                            "listen": {"host": "127.0.0.1", "port": candidate},
                        }
                    else:
                        endpoint = {
                            "protocol": protocol,
                            "listen": {"host": "127.0.0.1", "port": candidate},
                        }
                        if protocol == "http":
                            endpoint.update(
                                {
                                    "url": f"http://127.0.0.1:{candidate}",
                                    "hostNames": [],
                                    "visibility": "local",
                                }
                            )
                    endpoints[name] = endpoint
                    break
            else:
                fail(69, "local Project Runtime listener range is exhausted")

        value = {
            "schemaVersion": target_schema_version,
            "project": config["project"],
            "realization": "development",
            "paths": {
                "checkout": str(checkout),
                "state": str(state),
                "cache": str(cache),
                "runtime": str(root),
            },
            "endpoints": endpoints,
            "parameters": config.get("localParameters", {}),
            # A descriptor declares semantic requirements, not concrete local
            # bindings. Local actions may fall back to repository-owned env
            # files; managed adapters populate this map with real credentials.
            "secrets": {},
        }
        atomic_json(manifest_path, value)
    return manifest_path


def load_manifest(config: Mapping[str, Any]) -> tuple[pathlib.Path, dict[str, Any]]:
    configured = os.environ.get("PROJECT_RUNTIME_FILE")
    if configured:
        path = pathlib.Path(configured)
    elif config["realization"] == "development":
        path = local_manifest(config)
        os.environ["PROJECT_RUNTIME_FILE"] = str(path)
    else:
        fail(66, "PROJECT_RUNTIME_FILE is required for a Release")
    return path, validate_manifest(load_json(path, label="runtime manifest"), config)


def prepare_context(manifest: Mapping[str, Any]) -> None:
    paths = manifest["paths"]
    for name in ("state", "runtime", "cache"):
        if name in paths:
            pathlib.Path(paths[name]).mkdir(parents=True, exist_ok=True, mode=0o700)
    secrets_dir = os.environ.get("PROJECT_SECRETS_DIR")
    if not secrets_dir:
        secrets_dir = str(pathlib.Path(paths["runtime"]) / "secrets")
        pathlib.Path(secrets_dir).mkdir(parents=True, exist_ok=True, mode=0o700)
        os.environ["PROJECT_SECRETS_DIR"] = secrets_dir
    elif not pathlib.Path(secrets_dir).is_dir():
        fail(66, f"PROJECT_SECRETS_DIR does not exist: {secrets_dir}")
    if not pathlib.Path(secrets_dir).is_absolute():
        fail(66, "PROJECT_SECRETS_DIR must be an absolute path")


def preparation_lock(manifest: Mapping[str, Any]) -> contextlib.AbstractContextManager[None]:
    checkout = pathlib.Path(manifest["paths"]["checkout"]).resolve()
    digest = hashlib.sha256(str(checkout).encode()).hexdigest()[:24]
    return exclusive_lock(runtime_root() / "locks" / f"prepare-{digest}.lock")


def execute_action(
    config: Mapping[str, Any], action: str, *, replace: bool, activation: bool = False
) -> int:
    actions = config["actions"]
    executable = config.get("activation") if activation else actions.get(action)
    if not isinstance(executable, str):
        fail(64, f"undeclared Project action: {action}")
    _, manifest = load_manifest(config)
    prepare_context(manifest)
    is_preparation = action == config.get("preparationAction")
    context = preparation_lock(manifest) if is_preparation else contextlib.nullcontext()
    with context:
        if replace and not is_preparation:
            try:
                os.execvpe(executable, [executable], os.environ)
            except OSError as error:
                fail(69, f"could not execute action {action}: {error}")
        try:
            return subprocess.run([executable], env=os.environ, check=False).returncode
        except OSError as error:
            fail(69, f"could not execute action {action}: {error}")


def dependency_order(workloads: Mapping[str, Any], selected: Sequence[str]) -> list[str]:
    ordered: list[str] = []
    visiting: set[str] = set()
    visited: set[str] = set()

    def visit(name: str) -> None:
        if name not in workloads:
            fail(64, f"unknown Development Workload: {name}")
        if name in visited:
            return
        if name in visiting:
            fail(65, f"cyclic Development Workload dependency: {name}")
        visiting.add(name)
        for dependency in workloads[name].get("dependsOn", []):
            visit(dependency)
        visiting.remove(name)
        visited.add(name)
        ordered.append(name)

    for name in selected:
        visit(name)
    return ordered


def supervise(config: Mapping[str, Any], arguments: Sequence[str]) -> int:
    parser = argparse.ArgumentParser(prog="project-runtime dev")
    parser.add_argument("--only")
    try:
        options = parser.parse_args(arguments)
    except SystemExit as error:
        return 0 if error.code == 0 else 64

    _, manifest = load_manifest(config)
    prepare_context(manifest)
    preparation = config.get("preparationAction")
    if preparation:
        status = execute_action(config, preparation, replace=False)
        if status != 0:
            return status

    workloads = config["workloads"]
    selected = [options.only] if options.only else sorted(workloads)
    ordered = dependency_order(workloads, selected)
    processes: list[subprocess.Popen[bytes]] = []
    try:
        for name in ordered:
            action = workloads[name]["action"]
            executable = config["actions"][action]
            processes.append(subprocess.Popen([executable], env=os.environ))
        while processes:
            for process in processes:
                status = process.poll()
                if status is not None:
                    return status
            time.sleep(0.1)
    except KeyboardInterrupt:
        return 130
    finally:
        for process in processes:
            if process.poll() is None:
                process.terminate()
        for process in processes:
            with contextlib.suppress(subprocess.TimeoutExpired):
                process.wait(timeout=10)
            if process.poll() is None:
                process.kill()
    return 0


def context_query(config: Mapping[str, Any], arguments: Sequence[str]) -> int:
    parser = argparse.ArgumentParser(prog="project-context")
    subparsers = parser.add_subparsers(dest="command", required=True)
    path_parser = subparsers.add_parser("path")
    path_parser.add_argument("name")
    endpoint_parser = subparsers.add_parser("endpoint")
    endpoint_parser.add_argument("name")
    endpoint_parser.add_argument(
        "field", choices=["protocol", "url", "listen-host", "listen-port", "host-names"]
    )
    endpoint_parser.add_argument("--json", action="store_true")
    auxiliary_parser = subparsers.add_parser("auxiliary")
    auxiliary_parser.add_argument("name")
    auxiliary_parser.add_argument("port")
    auxiliary_parser.add_argument(
        "field", choices=["protocol", "listen-host", "listen-port"]
    )
    parameter_parser = subparsers.add_parser("parameter")
    parameter_parser.add_argument("name")
    parameter_parser.add_argument("--default")
    parameter_parser.add_argument("--json", action="store_true")
    secret_parser = subparsers.add_parser("secret-file")
    secret_parser.add_argument("name")
    secret_parser.add_argument("--required", action="store_true")
    try:
        options = parser.parse_args(arguments)
    except SystemExit as error:
        return 0 if error.code == 0 else 64

    _, manifest = load_manifest(config)
    prepare_context(manifest)
    if options.command == "path":
        value = manifest["paths"].get(options.name)
        if value is None:
            fail(66, f"Project path is unavailable: {options.name}")
    elif options.command in ("endpoint", "auxiliary"):
        if options.command == "endpoint":
            endpoint_name = options.name
        else:
            auxiliary = config.get("auxiliaryEndpoints", {}).get(options.name, {})
            endpoint_name = auxiliary.get(options.port)
            if endpoint_name is None:
                fail(66, f"Project auxiliary port is unavailable: {options.name}.{options.port}")
        endpoint = manifest["endpoints"].get(endpoint_name)
        if endpoint is None:
            fail(66, f"Project Endpoint is unavailable: {endpoint_name}")
        values = {
            "protocol": endpoint.get("protocol", "http"),
            "url": endpoint.get("url"),
            "listen-host": endpoint["listen"]["host"],
            "listen-port": endpoint["listen"]["port"],
            "host-names": endpoint.get("hostNames", []),
        }
        value = values[options.field]
        if value is None:
            fail(66, f"Project Endpoint field is unavailable: {endpoint_name}.{options.field}")
    elif options.command == "parameter":
        if options.name not in config.get("parameterDefinitions", {}):
            fail(66, f"Project parameter is undeclared: {options.name}")
        value = manifest["parameters"][options.name]
        if value is None and options.default is not None:
            try:
                value = json.loads(options.default)
            except json.JSONDecodeError:
                value = options.default
    else:
        credential = manifest["secrets"].get(options.name)
        if credential is None:
            if options.required:
                fail(66, f"Project Secret is unavailable: {options.name}")
            return 1
        root = pathlib.Path(os.environ.get("PROJECT_SECRETS_DIR", ""))
        value = root / credential
        if options.required and (not value.is_file() or value.stat().st_size == 0):
            fail(66, f"Project Secret file is missing or empty: {options.name}")
        value = str(value)

    if getattr(options, "json", False) or value is None or isinstance(value, (dict, list, bool)):
        print(json.dumps(value, separators=(",", ":")))
    else:
        print(value)
    return 0


def main(arguments: Sequence[str]) -> int:
    config_parser = argparse.ArgumentParser(add_help=False)
    config_parser.add_argument("--config", required=True)
    options, remaining = config_parser.parse_known_args(arguments)
    config = load_json(pathlib.Path(options.config), label="runtime configuration")

    if remaining and remaining[0] == "context":
        return context_query(config, remaining[1:])
    if remaining and remaining[0] == "dev":
        if config["realization"] != "development":
            fail(64, "dev is only available for a Development Runtime")
        return supervise(config, remaining[1:])
    if (
        remaining
        and remaining[0] == "workload"
        and config.get("descriptorSchemaVersion", 1) == 2
        and config["realization"] == "development"
    ):
        if len(remaining) != 2 or remaining[1] not in config["workloads"]:
            fail(64, "usage: project runtime workload <name>")
        action = config["workloads"][remaining[1]]["action"]
        return execute_action(config, action, replace=True)
    if remaining == ["--activate"]:
        if not config.get("activation"):
            fail(64, "this Release has no activation action")
        return execute_action(config, "activation", replace=True, activation=True)

    if config["realization"] == "release" and not remaining:
        action = config.get("defaultAction")
    elif len(remaining) == 1:
        action = remaining[0]
    else:
        fail(64, "usage: project runtime <action>")
    if not isinstance(action, str):
        fail(64, "this Project Runtime has no default action")
    return execute_action(config, action, replace=True)


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except RuntimeFailure as error:
        print(f"project-runtime: {error}", file=sys.stderr)
        raise SystemExit(error.status) from None
