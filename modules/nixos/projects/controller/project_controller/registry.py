"""The controller's persistent instance registry and its locks."""

from __future__ import annotations

import contextlib
import fcntl
import hashlib
import json
import os
import pathlib
from collections.abc import Iterator, Sequence
from typing import Any, cast

from .model import Catalog, Instance, Registry
from .util import ProjectError, atomic_json

SCHEMA_VERSION = 3


def read_registry(path: pathlib.Path) -> Registry:
    """Reads the registry without locking; for read-only consumers."""
    if not path.exists() or path.stat().st_size == 0:
        return {"schemaVersion": SCHEMA_VERSION, "instances": {}}
    registry = cast(Registry, json.loads(path.read_text(encoding="utf-8")))
    if registry.get("schemaVersion") != SCHEMA_VERSION:
        raise ProjectError("Unsupported Project Development registry schema")
    return registry


def load_catalog() -> Catalog:
    """The catalog Nix wrote for the calling user."""
    path = pathlib.Path(os.environ.get("PROJECT_DEVELOPMENT_CATALOG", "/etc/projects/catalog.json"))
    try:
        return cast(Catalog, json.loads(path.read_text(encoding="utf-8")))
    except (OSError, json.JSONDecodeError) as error:
        raise ProjectError(f"Could not load Project Development catalog {path}: {error}") from error


def innermost_instance(registry: Registry, cwd: pathlib.Path, project: str | None = None) -> Instance | None:
    """The instance whose checkout most closely contains cwd."""
    cwd = cwd.resolve()
    matches = [
        (len(checkout.parts), instance)
        for instance in registry["instances"].values()
        if project is None or instance["project"] == project
        for checkout in [pathlib.Path(instance["checkout"]).resolve()]
        if cwd == checkout or checkout in cwd.parents
    ]
    return max(matches, key=lambda match: match[0])[1] if matches else None


class RegistryStore:
    def __init__(self, registry_file: pathlib.Path, route_file: pathlib.Path):
        self.registry_file = registry_file
        self.route_file = route_file
        self.lock_file = registry_file.with_suffix(registry_file.suffix + ".lock")
        self.instance_lock_root = registry_file.parent / "instance-locks"

    @contextlib.contextmanager
    def locked(self) -> Iterator[Registry]:
        """The registry under an exclusive lock; call save() before leaving to persist changes."""
        self.lock_file.parent.mkdir(parents=True, exist_ok=True)
        with self.lock_file.open("a+", encoding="utf-8") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            yield read_registry(self.registry_file)

    @contextlib.contextmanager
    def _file_lock(self, key: str, *, shared: bool = False) -> Iterator[None]:
        self.instance_lock_root.mkdir(parents=True, exist_ok=True, mode=0o700)
        name = hashlib.sha256(key.encode()).hexdigest()
        with (self.instance_lock_root / f"{name}.lock").open("a+", encoding="utf-8") as lock:
            fcntl.flock(lock, fcntl.LOCK_SH if shared else fcntl.LOCK_EX)
            yield

    def instance_locked(self, identity: str, *, shared: bool = False) -> contextlib.AbstractContextManager[None]:
        """Serializes slow unit work per instance; endpoint activations share it."""
        return self._file_lock(identity, shared=shared)

    def endpoint_locked(self, identity: str, endpoint: str) -> contextlib.AbstractContextManager[None]:
        return self._file_lock(f"{identity}\0{endpoint}")

    def save(self, registry: Registry, routes: Sequence[dict[str, Any]]) -> None:
        atomic_json(self.registry_file, registry)
        atomic_json(self.route_file, list(routes))
