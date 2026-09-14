"""Validate supplied resources and resolve repository-owned environment references.

This module never allocates a resource. Secret bindings contain credential names;
their values are read only when an action explicitly consumes them.
"""

from __future__ import annotations

import json
import os
import pathlib
import re
from collections.abc import Mapping
from typing import Any


def validate_bindings(
    raw: Any, config: Mapping[str, Any], secrets: Mapping[str, str]
) -> dict[str, Any]:
    if not isinstance(raw, dict):
        raise ValueError("/bindings must be an object")
    requirements = {
        name: definition
        for name, definition in config.get("requirements", {}).items()
        if config["realization"]
        in definition.get("realizations", ["development", "release"])
    }
    unknown = set(raw) - requirements.keys()
    if unknown:
        raise ValueError(
            "/bindings has undeclared resources: " + ", ".join(sorted(unknown))
        )
    for name, requirement in requirements.items():
        prefix = f"/bindings/{name}"
        if name not in raw:
            if requirement.get("required", True):
                raise ValueError(f"{prefix} is required")
            continue
        value = raw[name]
        kind = requirement["kind"]
        if not isinstance(value, dict) or value.get("kind") != kind:
            raise ValueError(f"{prefix} must satisfy kind {kind}")
        fields = {
            "postgresql": {
                "kind",
                "majorVersion",
                "host",
                "port",
                "database",
                "user",
                "url",
                "dataDirectory",
            },
            "directory": {"kind", "path", "persistent"},
            "secret": {"kind", "credential"},
        }[kind]
        if set(value) - fields:
            raise ValueError(f"{prefix} has unknown fields")
        if kind == "postgresql":
            if type(value.get("majorVersion")) is not int or value[
                "majorVersion"
            ] not in requirement.get(
                "majorVersions", [requirement.get("majorVersion")]
            ):
                raise ValueError(
                    f"{prefix} requires PostgreSQL {requirement.get('majorVersions', [requirement.get('majorVersion')])}"
                )
            if type(value.get("port")) is not int or not 1 <= value["port"] <= 65535:
                raise ValueError(f"{prefix}/port must be between 1 and 65535")
            for field in ("host", "database", "user", "url"):
                if not isinstance(value.get(field), str) or not value[field]:
                    raise ValueError(f"{prefix}/{field} must be a non-empty string")
            if "dataDirectory" in value and (
                not isinstance(value["dataDirectory"], str)
                or not pathlib.PurePath(value["dataDirectory"]).is_absolute()
            ):
                raise ValueError(f"{prefix}/dataDirectory must be absolute")
        elif kind == "directory":
            if (
                not isinstance(value.get("path"), str)
                or not pathlib.PurePath(value["path"]).is_absolute()
            ):
                raise ValueError(f"{prefix}/path must be absolute")
            if type(value.get("persistent")) is not bool or value[
                "persistent"
            ] != requirement.get("persistent", True):
                raise ValueError(
                    f"{prefix}/persistent does not satisfy the requirement"
                )
        else:
            if (
                not isinstance(value.get("credential"), str)
                or value["credential"] not in secrets
            ):
                raise ValueError(f"{prefix}/credential must reference a bound secret")
    return raw


def secret_file(manifest: Mapping[str, Any], name: str) -> pathlib.Path | None:
    credential = manifest["secrets"].get(name)
    if credential is None:
        return None
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", credential) or credential in (".", ".."):
        raise ValueError(f"Unsafe credential filename for {name}")
    return (
        pathlib.Path(
            os.environ.get(
                "PROJECT_SECRETS_DIR",
                str(pathlib.Path(manifest["paths"]["runtime"]) / "secrets"),
            )
        )
        / credential
    )


def binding_value(manifest: Mapping[str, Any], name: str, field: str) -> Any:
    binding = manifest.get("bindings", {}).get(name)
    if binding is None:
        return None
    if binding["kind"] == "secret" and field in ("value", "file"):
        path = secret_file(manifest, binding["credential"])
        if path is None:
            return None
        return str(path) if field == "file" else path.read_text().rstrip("\n")
    if field not in binding:
        raise ValueError(f"Unknown binding field: {name}.{field}")
    return binding[field]


def environment_values(
    config: Mapping[str, Any], manifest: Mapping[str, Any], action: str
) -> dict[str, str | None]:
    definition = config.get("environment", {})
    mappings = {
        **definition.get("common", {}),
        **definition.get("actions", {}).get(action, {}),
    }
    result: dict[str, str | None] = {}
    for variable, reference in mappings.items():
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", variable):
            raise ValueError(f"Invalid environment variable: {variable}")
        if isinstance(reference, str):
            value = reference
        elif "binding" in reference:
            value = binding_value(manifest, reference["binding"], reference["field"])
        elif "secret" in reference:
            path = secret_file(manifest, reference["secret"])
            value = path.read_text().rstrip("\n") if path else None
        elif "parameter" in reference:
            value = manifest["parameters"].get(reference["parameter"])
        elif "instance" in reference:
            value = manifest.get("instanceId")
        elif "path" in reference:
            value = manifest["paths"].get(reference["path"])
            if value is not None and "append" in reference:
                value = str(pathlib.Path(value) / reference["append"])
        else:
            value = manifest["endpoints"].get(reference["endpoint"])
            for field in reference["field"].split("."):
                if value is None:
                    break
                if not isinstance(value, dict) or field not in value:
                    raise ValueError(
                        f"Unknown endpoint field: {reference['endpoint']}.{reference['field']}"
                    )
                value = value[field]
        if value is None or isinstance(value, str):
            result[variable] = value
        else:
            result[variable] = json.dumps(value, separators=(",", ":"))
    return result
