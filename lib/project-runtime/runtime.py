#!/usr/bin/env python3
"""Project runtime context queries for managed native development."""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import shlex
import sys
from collections.abc import Mapping, Sequence
from typing import Any, NoReturn

import bindings


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


def require_string(value: Any, pointer: str) -> str:
    if not isinstance(value, str) or not value:
        fail(65, f"runtime manifest {pointer}: must be a non-empty string")
    return value


def require_absolute_path(value: Any, pointer: str) -> str:
    result = require_string(value, pointer)
    if not pathlib.Path(result).is_absolute():
        fail(65, f"runtime manifest {pointer}: must be an absolute path")
    return result


def validate_manifest(
    raw: Mapping[str, Any], config: Mapping[str, Any]
) -> dict[str, Any]:
    schema_version = raw.get("schemaVersion")
    if schema_version not in (1, 2, 3):
        fail(65, "runtime manifest /schemaVersion: unsupported version")
    descriptor_schema_version = config.get("descriptorSchemaVersion", 1)
    if descriptor_schema_version >= 4 and schema_version != 3:
        fail(65, "Project descriptor v4 requires runtime manifest version 3")
    if schema_version >= 2 and descriptor_schema_version < 2:
        fail(
            65,
            "runtime manifest /schemaVersion: version 2 requires a v2 or newer Project descriptor",
        )

    allowed_root = {
        "schemaVersion",
        "project",
        "realization",
        "revision",
        "paths",
        "endpoints",
        "parameters",
        "settings",
        "secrets",
    }
    if schema_version >= 2:
        allowed_root.remove("settings")
    if schema_version == 3:
        if descriptor_schema_version < 4:
            fail(
                65,
                "runtime manifest /schemaVersion: version 3 requires a v4 Project descriptor",
            )
        allowed_root.update(("instanceId", "bindings"))
        require_string(raw.get("instanceId"), "/instanceId")
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
    revision = raw.get("revision")
    if revision is not None and (
        not isinstance(revision, str)
        or re.fullmatch(r"[0-9a-f]{40,64}", revision) is None
    ):
        fail(65, "runtime manifest /revision: must be a lowercase Git object ID")

    paths = raw.get("paths")
    if not isinstance(paths, dict):
        fail(65, "runtime manifest /paths: must be an object")
    unknown_paths = set(paths) - {"checkout", "state", "cache", "runtime"}
    if unknown_paths:
        fail(
            65,
            "runtime manifest /paths: unknown fields: "
            + ", ".join(sorted(unknown_paths)),
        )
    required_paths = ["state", "runtime"]
    if config["realization"] == "development":
        required_paths.extend(["checkout", "cache"])
    normalized_paths = dict(paths)
    for name in required_paths:
        normalized_paths[name] = require_absolute_path(
            paths.get(name), f"/paths/{name}"
        )

    endpoints = raw.get("endpoints")
    if not isinstance(endpoints, dict):
        fail(65, "runtime manifest /endpoints: must be an object")
    normalized_endpoints: dict[str, Any] = {}
    for name, endpoint in endpoints.items():
        if not NAME_RE.fullmatch(name) or not isinstance(endpoint, dict):
            fail(65, f"runtime manifest /endpoints/{name}: invalid Endpoint")
        allowed_endpoint = {"url", "listen", "hostNames", "visibility"}
        if schema_version >= 2:
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
        if (
            not isinstance(port, int)
            or isinstance(port, bool)
            or not 1 <= port <= 65535
        ):
            fail(65, f"runtime manifest /endpoints/{name}/listen/port: invalid port")
        protocol = "http" if schema_version == 1 else endpoint.get("protocol")
        if protocol not in ("http", "tcp"):
            fail(
                65, f"runtime manifest /endpoints/{name}/protocol: must be http or tcp"
            )
        if protocol == "http":
            url = require_string(endpoint.get("url"), f"/endpoints/{name}/url")
            host_names = endpoint.get("hostNames", [])
            if (
                not isinstance(host_names, list)
                or not all(isinstance(item, str) and item for item in host_names)
                or len(host_names) != len(set(host_names))
            ):
                fail(65, f"runtime manifest /endpoints/{name}/hostNames: invalid list")
            visibility = endpoint.get("visibility")
            if visibility is not None and visibility not in (
                "local",
                "tailnet",
                "public",
            ):
                fail(
                    65, f"runtime manifest /endpoints/{name}/visibility: invalid value"
                )
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
        fail(
            65,
            "runtime manifest: set parameters, not both parameters and legacy settings",
        )
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
        if (
            not isinstance(credential, str)
            or not CREDENTIAL_RE.fullmatch(credential)
            or credential in (".", "..")
        ):
            fail(66, f"runtime manifest /secrets/{name}: unsafe credential filename")
    unknown_secrets = set(secrets) - set(config.get("secrets", []))
    if unknown_secrets:
        fail(
            65,
            "runtime manifest /secrets: undeclared names: "
            + ", ".join(sorted(unknown_secrets)),
        )

    if schema_version == 3:
        try:
            bindings.validate_bindings(raw.get("bindings", {}), config, secrets)
        except ValueError as error:
            fail(65, f"runtime manifest {error}")

    return {
        **raw,
        "paths": normalized_paths,
        "endpoints": normalized_endpoints,
        "parameters": normalized_parameters,
        "secrets": secrets,
    }


def load_manifest(config: Mapping[str, Any]) -> tuple[pathlib.Path, dict[str, Any]]:
    configured = os.environ.get("PROJECT_RUNTIME_FILE")
    if configured:
        path = pathlib.Path(configured)
    else:
        fail(
            66,
            "PROJECT_RUNTIME_FILE is required; use native devenv for local development",
        )
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
    subparsers.add_parser("snapshot")
    subparsers.add_parser("revision")
    subparsers.add_parser("instance-id")
    binding_parser = subparsers.add_parser("binding")
    binding_parser.add_argument("name")
    binding_parser.add_argument("field")
    binding_parser.add_argument("--json", action="store_true")
    environment_parser = subparsers.add_parser("environment")
    environment_parser.add_argument("action", nargs="?", default="")
    try:
        options = parser.parse_args(arguments)
    except SystemExit as error:
        return 0 if error.code == 0 else 64

    _, manifest = load_manifest(config)
    prepare_context(manifest)
    if options.command == "snapshot":
        root = pathlib.Path(os.environ.get("PROJECT_SECRETS_DIR", ""))
        value = {
            "schemaVersion": 1,
            "project": manifest["project"],
            "realization": manifest["realization"],
            "revision": manifest.get("revision"),
            "instanceId": manifest.get("instanceId")
            or (
                pathlib.Path(manifest["paths"]["runtime"]).name
                if manifest["realization"] == "development"
                else None
            ),
            "paths": manifest["paths"],
            "endpoints": manifest["endpoints"],
            "parameters": manifest["parameters"],
            "bindings": manifest.get("bindings", {}),
            "secretFiles": {
                name: str(root / credential)
                for name, credential in manifest["secrets"].items()
            },
        }
    elif options.command == "path":
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
                fail(
                    66,
                    f"Project auxiliary port is unavailable: {options.name}.{options.port}",
                )
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
            fail(
                66,
                f"Project Endpoint field is unavailable: {endpoint_name}.{options.field}",
            )
    elif options.command == "parameter":
        if options.name not in config.get("parameterDefinitions", {}):
            fail(66, f"Project parameter is undeclared: {options.name}")
        value = manifest["parameters"][options.name]
        if value is None and options.default is not None:
            try:
                value = json.loads(options.default)
            except json.JSONDecodeError:
                value = options.default
    elif options.command == "revision":
        value = manifest.get("revision")
        if value is None:
            return 1
    elif options.command == "instance-id":
        value = manifest.get("instanceId")
        # TODO: Remove path-derived IDs after all v1/v2 runtimes have migrated.
        if value is None and manifest["realization"] == "development":
            value = pathlib.Path(manifest["paths"]["runtime"]).name
        if value is None:
            return 1
    elif options.command == "binding":
        try:
            value = bindings.binding_value(manifest, options.name, options.field)
        except (ValueError, OSError) as error:
            fail(66, f"Project binding: {error}")
        if value is None:
            return 1
    elif options.command == "environment":
        try:
            for name, value in bindings.environment_values(
                config, manifest, options.action
            ).items():
                print(
                    f"unset {name}"
                    if value is None
                    else f"export {name}={shlex.quote(value)}"
                )
        except (ValueError, OSError) as error:
            fail(66, f"Project environment: {error}")
        return 0
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

    if (
        getattr(options, "json", False)
        or value is None
        or isinstance(value, (dict, list, bool))
    ):
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
    fail(64, "usage: project context runtime --config FILE context <query>")


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except RuntimeFailure as error:
        print(f"project-runtime: {error}", file=sys.stderr)
        raise SystemExit(error.status) from None
