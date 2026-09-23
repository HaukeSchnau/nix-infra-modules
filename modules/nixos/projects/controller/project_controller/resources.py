"""Port allocation and requirement bindings for an instance."""

from __future__ import annotations

import hashlib
import os
import pathlib
import secrets
import urllib.parse
from dataclasses import dataclass, field
from typing import Any

from .model import Development, Instance, Registry, SecretBinding
from .util import ProjectError


class PortAllocator:
    """Deterministic ports from a host range; a hash of the identity picks
    the first candidate so an instance keeps its ports across rebuilds."""

    def __init__(self, first: int, last: int):
        self.first, self.last = first, last

    def allocate(self, used: set[int], identity: str, discriminator: str) -> int:
        size = self.last - self.first + 1
        offset = int(hashlib.sha256(f"{identity}/{discriminator}".encode()).hexdigest()[:8], 16) % size
        for step in range(size):
            candidate = self.first + (offset + step) % size
            if candidate not in used:
                used.add(candidate)
                return candidate
        raise ProjectError("Project Development port range is exhausted")

    def private(self, used: set[int], instance: Instance, name: str, preferred: int | None) -> int:
        """A port inside the instance's workspace namespace, preferring the declared one."""
        if preferred and preferred not in used:
            used.add(preferred)
            return preferred
        return self.allocate(used, instance["identity"], name)


def host_ports(registry: Registry) -> set[int]:
    """Ports taken on the host: endpoint pairs and native resources."""
    used: set[int] = set()
    for other in registry["instances"].values():
        used.update(p for pair in other["ports"].values() for p in (pair["frontend"], pair["backend"]) if p is not None)
        used.update(other.get("resourcePorts", {}).values())
    return used


def namespace_ports(registry: Registry, instance: Instance) -> set[int]:
    """Ports taken inside the instance's workspace namespace."""
    execution = instance.get("execution")
    return {
        port
        for other in registry["instances"].values()
        if other.get("execution") == execution
        for port in [*other.get("internalPorts", {}).values(), *other.get("resourcePorts", {}).values()]
    }


def ensure_ports(allocator: PortAllocator, registry: Registry, instance: Instance, development: Development) -> None:
    """Keeps only ports for declared endpoints and allocates missing ones."""
    endpoints = development["endpoints"]
    instance["ports"] = {name: pair for name, pair in instance["ports"].items() if name in endpoints}
    if "internalPorts" in instance:
        instance["internalPorts"] = {n: p for n, p in instance["internalPorts"].items() if n in endpoints}
    used, private = host_ports(registry), namespace_ports(registry, instance)
    for name, endpoint in sorted(endpoints.items()):
        pair = instance["ports"].setdefault(name, {"frontend": None, "backend": None})
        for side in ("frontend", "backend"):
            if pair[side] is None:
                pair[side] = allocator.allocate(used, instance["identity"], f"{name}/{side}")
        if instance.get("execution"):
            internal = instance.setdefault("internalPorts", {})
            if name not in internal:
                internal[name] = allocator.private(private, instance, name, endpoint["port"])


@dataclass
class ResourcePlan:
    bindings: dict[str, Any] = field(default_factory=dict)
    credentials: dict[str, SecretBinding] = field(default_factory=dict)
    resources: dict[str, dict[str, Any]] = field(default_factory=dict)
    errors: list[str] = field(default_factory=list)


def plan_resources(
    allocator: PortAllocator,
    registry: Registry,
    instance: Instance,
    development: Development,
    paths: dict[str, pathlib.Path],
) -> ResourcePlan:
    """Resolves requirements without creating anything; allocates resource ports on `instance`.

    `development` is the policy-bound development, without the instance's
    generated credentials, so generated secrets are not mistaken for host ones.
    """
    plan = ResourcePlan()
    host_secrets = development["secrets"]
    resource_ports = instance.setdefault("resourcePorts", {})
    for name, requirement in development["requirements"].items():
        kind = requirement["kind"]
        provider = development["providers"].get(name)
        if kind == "directory":
            persistent = requirement["persistent"]
            path = paths["state" if persistent else "runtime"] / requirement["path"]
            plan.bindings[name] = {"kind": kind, "path": str(path), "persistent": persistent}
            plan.resources[name] = {"source": "instance", "kind": kind, "path": str(path)}
        elif kind == "secret" and name in host_secrets:
            plan.bindings[name] = {"kind": kind, "credential": name}
            plan.resources[name] = {"source": "host-credential", "kind": kind}
        elif kind == "secret" and requirement.get("generate") is not None:
            path = paths["state"] / "credentials" / name
            plan.credentials[name] = {"path": str(path)}
            plan.bindings[name] = {"kind": kind, "credential": name}
            plan.resources[name] = {
                "source": "generated", "kind": kind, "path": str(path),
                "bytes": requirement["generate"]["bytes"],
            }
        elif kind == "postgresql" and provider is not None:
            major = provider["majorVersion"]
            port = resource_ports.get(name)
            if port is None:
                if instance.get("execution"):
                    port = allocator.private(
                        namespace_ports(registry, instance), instance, f"resource/{name}", provider["port"]
                    )
                else:
                    port = allocator.allocate(host_ports(registry), instance["identity"], f"resource/{name}")
                resource_ports[name] = port
            path = paths["state"] / requirement["dataDirectory"]
            version_file = path / "PG_VERSION"
            if version_file.exists() and version_file.read_text().strip() != str(major):
                plan.errors.append(
                    f"Requirement {name} retains PostgreSQL {version_file.read_text().strip()} data; "
                    f"an explicit database migration is required for PostgreSQL {major}"
                )
            user, database = provider["user"], provider["database"]
            plan.bindings[name] = {
                "kind": kind, "majorVersion": major, "host": "127.0.0.1", "port": port,
                "database": database, "user": user, "dataDirectory": str(path),
                "url": f"postgresql://{urllib.parse.quote(user, safe='')}@127.0.0.1:{port}/{urllib.parse.quote(database, safe='')}",
            }
            plan.resources[name] = {
                "source": "native-process", "kind": kind, "workload": provider["workload"],
                "path": str(path), "port": port,
            }
        elif requirement["required"]:
            hint = "; bind an account credential in host policy" if kind == "secret" else ""
            plan.errors.append(f"Requirement {name} ({kind}) has no authorized binding{hint}")
    return plan


def create_resources(plan: ResourcePlan) -> None:
    """Creates generated credentials and instance directories; existing ones are kept."""
    for resource in plan.resources.values():
        if resource["source"] == "generated":
            path = pathlib.Path(resource["path"])
            path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            try:
                fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            except FileExistsError:
                continue
            with os.fdopen(fd, "w") as output:
                output.write(secrets.token_hex(resource["bytes"]) + "\n")
                output.flush()
                os.fsync(output.fileno())
        elif resource["source"] in ("instance", "native-process"):
            pathlib.Path(resource["path"]).mkdir(parents=True, exist_ok=True, mode=0o700)
