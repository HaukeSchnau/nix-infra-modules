"""Binding a prepared bundle's Project contract to host policy.

This is the only place where development policy is resolved: generated host
names, endpoint visibility, parameter values and which secrets are available.
"""

from __future__ import annotations

import json
import pathlib
from typing import Any, cast

from .model import Development, Endpoint, Policy, Workload
from .util import ProjectError

BUNDLE_SCHEMA_VERSION = 2


def read_bundle(bundle: pathlib.Path, project: str) -> tuple[dict[str, Any], str]:
    """The normalized descriptor and runtime executable of a prepared bundle."""
    metadata_path = bundle / "share/project/bundle.json"
    try:
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
        descriptor = json.loads((bundle / "share/project/project.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ProjectError(
            f"Development bundle {bundle} is unreadable or predates this host; "
            "run `project dev bundle refresh`"
        ) from error
    if metadata.get("schemaVersion") != BUNDLE_SCHEMA_VERSION:
        raise ProjectError(
            f"Development bundle {bundle} predates this host; run `project dev bundle refresh`"
        )
    if metadata.get("project") != project or descriptor.get("project") != project:
        raise ProjectError(f"Development bundle {bundle} does not describe {project}")
    entrypoint = pathlib.PurePosixPath(metadata.get("entrypoint", ""))
    if entrypoint.is_absolute() or ".." in entrypoint.parts or not entrypoint.parts:
        raise ProjectError("Development bundle entrypoint must be a relative path")
    executable = bundle / entrypoint
    if not executable.is_file():
        raise ProjectError(f"Development bundle entrypoint is missing: {executable}")
    if descriptor.get("development") is None:
        raise ProjectError(f"Project {project} declares no Development realization")
    return descriptor, str(executable)


def _endpoint(
    project: str, name: str, endpoint: dict[str, Any], policy: Policy, domain: str
) -> Endpoint:
    overrides = policy["endpoints"].get(name, {})
    private = endpoint["publication"] == "private"
    visibility = overrides.get("visibility") or (
        "local" if endpoint["protocol"] == "tcp" or private else "tailnet"
    )
    if private and visibility != "local":
        raise ProjectError(f"Endpoint {name} is declared private and cannot be published")
    label = project if name == "web" else f"{project}-{name}"
    generated = f"{label}.{domain}"
    canonical = overrides.get("hostName") or generated
    aliases = ([generated] if canonical != generated else []) + list(overrides.get("aliases", []))
    return cast(
        Endpoint,
        {
            **endpoint,
            "visibility": visibility,
            "hostNames": {
                "canonical": canonical,
                "aliases": list(dict.fromkeys(aliases)),
                "instanceTemplate": ("{instance}" if name == "web" else f"{{instance}}-{name}") + f".{domain}",
            },
        },
    )


def bind(descriptor: dict[str, Any], executable: str, policy: Policy, domain: str) -> Development:
    """Applies host policy to a normalized descriptor without evaluating repository code."""
    project = descriptor["project"]
    declared = descriptor["development"]
    requirements = {
        name: requirement
        for name, requirement in descriptor["requirements"].items()
        if "development" in requirement["realizations"]
    }
    generated = {
        name
        for name, requirement in requirements.items()
        if requirement["kind"] == "secret" and requirement.get("generate") is not None
    }
    bound = policy["secrets"]
    available = set(bound) | generated
    users = [*declared["workloads"].values(), *declared["commands"].values(), declared["preparation"]]
    used = {secret for user in users for secret in user["secrets"]}
    missing = sorted(
        name for name in used - available if descriptor["secrets"].get(name, {}).get("required", True)
    )
    if missing:
        raise ProjectError("Host policy does not bind required Development Secrets: " + ", ".join(missing))

    definitions = descriptor["parameters"]
    unknown = sorted(set(policy["parameters"]) - set(definitions))
    if unknown:
        raise ProjectError("Host policy configures unknown Development Parameters: " + ", ".join(unknown))
    parameters: dict[str, Any] = {}
    for name, definition in definitions.items():
        if name in policy["parameters"]:
            parameters[name] = policy["parameters"][name]
        elif "default" in definition:
            parameters[name] = definition["default"]
        elif definition["required"]:
            raise ProjectError(f"Host policy does not bind required Parameter: {name}")

    def only_available(item: dict[str, Any]) -> dict[str, Any]:
        return {**item, "secrets": [secret for secret in item["secrets"] if secret in available]}

    return {
        "runtimeExecutable": executable,
        "parameters": parameters,
        "requirements": requirements,
        "providers": declared["providers"],
        "workloads": {name: cast(Workload, only_available(item)) for name, item in declared["workloads"].items()},
        "commands": {name: only_available(item) for name, item in declared["commands"].items()},
        "endpoints": {
            name: _endpoint(project, name, endpoint, policy, domain)
            for name, endpoint in declared["endpoints"].items()
        },
        "secrets": {name: bound[name] for name in sorted(used | set(requirements)) if name in bound},
        "preparation": only_available(declared["preparation"]),
        "idleTimeoutSec": policy["idleTimeoutSec"],
    }
