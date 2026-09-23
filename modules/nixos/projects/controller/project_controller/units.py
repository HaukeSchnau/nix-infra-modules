"""Stable names for an instance's systemd units, host names and ingress routes."""

from __future__ import annotations

import hashlib
from dataclasses import dataclass

from .model import Endpoint, Instance
from .util import slugify


def _digest(value: str, length: int = 20) -> str:
    return hashlib.sha256(value.encode()).hexdigest()[:length]


@dataclass(frozen=True)
class EndpointUnits:
    socket: str
    service: str


@dataclass(frozen=True)
class UnitNames:
    manager: str
    endpoints: dict[str, EndpointUnits]

    def all(self) -> list[str]:
        return sorted(
            {self.manager, *(unit for pair in self.endpoints.values() for unit in (pair.socket, pair.service))}
        )


def unit_names(instance: Instance, endpoints: dict[str, Endpoint]) -> UnitNames:
    # The manager keeps the name of the former per-workload "devenv" unit so
    # upgrades replace units instead of leaving orphans behind.
    manager = f"project-dev-{_digest(f'{instance['identity']}/devenv')}-devenv.service"

    def stem(endpoint: str) -> str:
        return f"project-dev-{_digest(f'{instance['identity']}/endpoint/{endpoint}')}-{slugify(endpoint, maximum=24)}"

    return UnitNames(
        manager,
        {name: EndpointUnits(f"{stem(name)}.socket", f"{stem(name)}.service") for name in endpoints},
    )


def published_hostnames(instance: Instance, endpoint: Endpoint) -> list[str]:
    host_names = endpoint["hostNames"]
    if instance["canonical"]:
        return list(dict.fromkeys([host_names["canonical"], *host_names["aliases"]]))
    return [host_names["instanceTemplate"].replace("{instance}", instance["instanceKey"])]


def route_name(instance: Instance, endpoint: str, hostname: str) -> str:
    return f"project-dev-{_digest(f'{instance['project']}/{instance['id']}/{endpoint}/{hostname}', 40)}"
