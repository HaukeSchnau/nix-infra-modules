"""Development instance lifecycle.

Nix writes an immutable catalog once. The controller turns its entries into
any number of instances without another Nix evaluation: one canonical
instance per enrolled Project plus one per ad-hoc jj/git workspace, all with
the same lifecycle. Desired state is idle (sockets only), active (running on
demand or in the background), paused, or retired; only an explicit `up`
resumes the last two.
"""

from __future__ import annotations

import contextlib
import hashlib
import json
import os
import pathlib
import re
import secrets as token_source
import subprocess
import time
from collections.abc import Callable, Mapping, Sequence
from typing import Any, Protocol, cast

from . import contract, resources
from .bundles import BundleBuilder
from .discovery import Checkout, CheckoutDiscovery, inside
from .model import (
    Catalog,
    CatalogProject,
    DesiredState,
    Development,
    Instance,
    Lifecycle,
    OperationPhase,
    Provenance,
    Registry,
)
from .readiness import ProtocolReadiness
from .registry import SCHEMA_VERSION, RegistryStore, read_registry
from .systemd import SystemdUserServices
from .units import UnitNames, published_hostnames, route_name, unit_names
from .util import DNS_RE, NAME_RE, ProjectError, Runner, atomic_json, slugify, snapshot

CATALOG_SCHEMA_VERSION = 2
POLICY_FINGERPRINT_VERSION = 4
UNPREPARED_RUNTIME = "/unprepared/project-runtime"


class Discovery(Protocol):
    def resolve(self, cwd: pathlib.Path, requested: str | None = None) -> Checkout: ...


def _lifecycle() -> Lifecycle:
    return {"phase": "dormant", "lastActivationAt": None, "lastReadyAt": None, "lastStoppedAt": None, "lastFailure": None}


def validate_catalog(catalog: Mapping[str, Any]) -> None:
    if catalog.get("schemaVersion") != CATALOG_SCHEMA_VERSION:
        raise ProjectError("Unsupported Project Development catalog schema")
    for key in ("controllerExecutable", "socketProxyExecutable", "systemdUnitRoot", "catalogFile"):
        if not str(catalog.get(key, "")).startswith("/"):
            raise ProjectError(f"Project Development catalog requires absolute {key}")
    domain = catalog.get("developmentDomain", "")
    if not domain or any(not DNS_RE.fullmatch(label) for label in domain.split(".")):
        raise ProjectError("Invalid Development domain")
    ports = catalog.get("portRange", {})
    if not (1 <= ports.get("from", 0) <= ports.get("to", 0) <= 65535):
        raise ProjectError("Invalid Project Development port range")
    for name in catalog.get("projects", {}):
        if not NAME_RE.fullmatch(name):
            raise ProjectError(f"Invalid Project name: {name}")


class Controller:
    def __init__(
        self,
        catalog: Catalog,
        *,
        discovery: Discovery | None = None,
        services: SystemdUserServices | None = None,
        readiness: ProtocolReadiness | None = None,
        runner: Runner | None = None,
        now: Callable[[], float] = time.time,
        id_factory: Callable[[], str] = lambda: token_source.token_hex(3),
        report: Callable[[str], None] = lambda _message: None,
    ):
        validate_catalog(catalog)
        self.catalog = catalog
        self.projects = catalog["projects"]
        self.runner = runner or Runner()
        self.discovery = discovery or CheckoutDiscovery(
            self.projects,
            self.runner,
            workspace_launcher=catalog.get("workspaceLauncher"),
            delegate=self._delegate_checkout,
        )
        self.services = services or SystemdUserServices(catalog, self.runner)
        self.readiness = readiness or ProtocolReadiness(self.runner)
        self.now = now
        self.id_factory = id_factory
        self.report = report
        self.bundles = BundleBuilder(catalog["bundleBuilder"], self.runner, now, lambda message: self.report(message))
        self.ports = resources.PortAllocator(catalog["portRange"]["from"], catalog["portRange"]["to"])
        self.store = RegistryStore(pathlib.Path(catalog["registryFile"]), pathlib.Path(catalog["routeSourceFile"]))
        self._bound: dict[tuple[str, str], Development] = {}
        for name, project in read_registry(self.store.registry_file).get("delegatedProjects", {}).items():
            checkout = pathlib.Path(project["repository"]["checkout"])
            if name not in self.projects and self._development_granted(checkout):
                self.projects[name] = self._delegated_project(checkout, project.get("contract"))

    # Delegated (unenrolled) Projects

    def _development_granted(self, root: pathlib.Path) -> bool:
        grants = self.catalog["developmentGrants"]
        if any(inside(root.resolve(), pathlib.Path(parent).resolve()) for parent in grants.get("checkoutRoots", [])):
            return True
        if grants.get("workspaces"):
            return bool(self._execution(str(root)))
        return False

    def _delegated_project(self, root: pathlib.Path, descriptor: Mapping[str, Any] | None) -> CatalogProject:
        grants = self.catalog["developmentGrants"]
        project = cast(
            CatalogProject,
            {
                "delegated": True,
                "owner": grants["owner"],
                "group": grants["group"],
                "repository": {"checkout": str(root), "url": ""},
                "pinnedBundle": None,
                "canonical": False,
                "policy": {"parameters": {}, "secrets": {}, "endpoints": {}, "idleTimeoutSec": self.catalog["idleTimeoutSec"]},
            },
        )
        if descriptor is not None:
            project["contract"] = dict(descriptor)
        return project

    def _admit_delegated(self, inspection: Mapping[str, Any]) -> CatalogProject:
        root = pathlib.Path(inspection["checkout"])
        descriptor = inspection["contract"]
        if not self._development_granted(root):
            raise ProjectError("Development is not granted for this checkout directory")
        if descriptor.get("development") is None:
            raise ProjectError("Unenrolled repositories require a Development contract")
        if not (root / "devenv.nix").is_file():
            raise ProjectError("Unenrolled repositories require a native devenv definition")
        for name, requirement in descriptor["requirements"].items():
            if (
                "development" in requirement["realizations"]
                and requirement["kind"] != "secret"
                and requirement["kind"] not in self.catalog["developmentGrants"]["resourceKinds"]
            ):
                raise ProjectError(f"Requirement {name} needs a {requirement['kind']} Development grant")
        project = self._delegated_project(root, descriptor)
        self._bind_project(descriptor["project"], project)
        return project

    def _delegate_checkout(self, root: pathlib.Path, requested: str | None) -> Checkout:
        inspection = self.inspect(root)
        name = inspection["contract"]["project"]
        if requested is not None and name != requested:
            raise ProjectError(f"Expected Project {requested}, got {name}")
        if name in self.projects:
            raise ProjectError(f"Checkout does not match the authorized repository for Project {name}")
        self.projects[name] = self._admit_delegated(inspection)
        discovery = cast(CheckoutDiscovery, self.discovery)
        return Checkout(name, root, False, discovery.workspace_name(root), discovery.branch(root))

    # Binding contracts

    def _bind(self, descriptor: Mapping[str, Any], executable: str, project: CatalogProject) -> Development:
        return contract.bind(dict(descriptor), executable, project["policy"], self.catalog["developmentDomain"])

    def _bind_path(self, project_name: str, bundle: str) -> Development:
        key = (project_name, bundle)
        if key not in self._bound:
            descriptor, executable = contract.read_bundle(pathlib.Path(bundle), project_name)
            self._bound[key] = self._bind(descriptor, executable, self.projects[project_name])
        return self._bound[key]

    def _bind_project(self, project_name: str, project: CatalogProject) -> Development:
        """The development of a Project before any instance has a bundle of its own."""
        if project["pinnedBundle"] is not None:
            return self._bind_path(project_name, project["pinnedBundle"])
        descriptor = project.get("contract")
        if descriptor is None:
            raise ProjectError(f"Project {project_name} has no prepared bundle; run `project dev bundle refresh`")
        return self._bind(descriptor, UNPREPARED_RUNTIME, project)

    def _development(self, instance: Instance) -> Development:
        """The instance's bound development, with its generated credentials."""
        development = instance.get("development") or self._bind_project(
            instance["project"], self.projects[instance["project"]]
        )
        return {**development, "secrets": {**instance.get("resourceSecrets", {}), **development["secrets"]}}

    # Inspection

    def inspect(self, cwd: pathlib.Path) -> dict[str, Any]:
        root = cast(CheckoutDiscovery, self.discovery).root(cwd) if isinstance(self.discovery, CheckoutDiscovery) else cwd
        path = self.bundles.export(root)
        return {"checkout": str(root), "contract": json.loads(path.read_text(encoding="utf-8"))}

    def export(self, cwd: pathlib.Path) -> pathlib.Path:
        root = cast(CheckoutDiscovery, self.discovery).root(cwd) if isinstance(self.discovery, CheckoutDiscovery) else cwd
        return self.bundles.export(root)

    def plan(self, cwd: pathlib.Path, name: str | None = None) -> dict[str, Any]:
        """Resolves the checkout's current contract against host policy without creating state."""
        inspection = self.inspect(cwd)
        descriptor = inspection["contract"]
        project_name = descriptor["project"]
        if descriptor.get("development") is None:
            return {**inspection, "ready": False, "errors": ["Project has no Development realization"]}
        project = self.projects.get(project_name)
        if project is None:
            try:
                project = self._admit_delegated(inspection)
            except ProjectError as error:
                return {**inspection, "ready": False, "errors": [str(error)]}
            self.projects[project_name] = project
            checkout = Checkout(project_name, pathlib.Path(inspection["checkout"]), False, None, None)
        else:
            checkout = self.discovery.resolve(cwd, project_name)
        registry = read_registry(self.store.registry_file)
        instance = self._matching_instance(registry, checkout, name)
        registered = instance is not None
        if instance is None:
            instance = cast(Instance, {
                "id": "pending", "identity": f"{project_name}:pending", "project": project_name,
                "instanceKey": name or "pending", "canonical": False, "checkout": str(checkout.root),
                "requestedName": name, "desiredState": "idle", "available": True,
                "ports": {}, "endpointLifecycle": {}, "installedUnits": [],
            })
            registry["instances"][instance["identity"]] = instance
        try:
            self._bind_execution(instance)
            executable = self._bind_project(project_name, project)["runtimeExecutable"]
            instance["development"] = self._bind(descriptor, executable, project)
            resources.ensure_ports(self.ports, registry, instance, instance["development"])
            plan = resources.plan_resources(self.ports, registry, instance, instance["development"], self._paths(instance))
            found, errors = plan.resources, plan.errors
        except ProjectError as error:
            found, errors = {}, [str(error)]
        return {
            **inspection,
            "ready": not errors,
            "errors": errors,
            "instanceId": instance["id"] if registered else None,
            "desiredState": instance["desiredState"],
            "resources": found,
            "bundle": self._bundle_status(instance) if registered else None,
        }

    # Instances

    @staticmethod
    def _matching_instance(registry: Registry, checkout: Checkout, requested_name: str | None) -> Instance | None:
        """Locates the instance bound to a checkout; the path is not its identity."""
        for instance in registry["instances"].values():
            if (
                instance["project"] == checkout.project
                and instance.get("requestedName") == requested_name
                and (
                    (checkout.canonical and requested_name is None and instance["canonical"])
                    or instance["checkout"] == str(checkout.root.resolve())
                )
            ):
                return instance
        return None

    def _execution(self, checkout: str) -> dict[str, Any] | None:
        """The workspace runtime owning a checkout, if any."""
        launcher = self.catalog.get("workspaceLauncher")
        if not launcher:
            return None
        result = self.runner.output([launcher, "environment", "--cwd", checkout], cwd=pathlib.Path(checkout))
        if result is None:
            raise ProjectError("Could not inspect the checkout execution environment")
        return json.loads(result) or None

    def _bind_execution(self, instance: Instance) -> None:
        execution = self._execution(instance["checkout"])
        previous = instance.get("execution")
        if previous is not None and previous != execution:
            raise ProjectError("Workspace execution ownership changed; relocate the retained instance explicitly")
        if execution:
            instance["execution"] = execution

    def _instance_hostnames(self, instance: Instance, development: Development | None = None) -> set[str]:
        development = development or self._development(instance)
        return {
            hostname
            for endpoint in development["endpoints"].values()
            if endpoint["visibility"] != "local"
            for hostname in published_hostnames(instance, endpoint)
        }

    def _new_instance_key(self, registry: Registry, project: str, source: str) -> str:
        """The shortest key derived from `source` whose published host names are free."""
        base = slugify(source)
        used_keys = {i["instanceKey"] for i in registry["instances"].values() if i["project"] == project}
        used_hostnames: set[str] = set()
        for other in registry["instances"].values():
            if other["project"] in self.projects:
                with contextlib.suppress(ProjectError):
                    used_hostnames |= self._instance_hostnames(other)
        for name, catalog_project in self.projects.items():
            with contextlib.suppress(ProjectError):
                for endpoint in self._bind_project(name, catalog_project)["endpoints"].values():
                    if endpoint["visibility"] != "local":
                        used_hostnames |= {endpoint["hostNames"]["canonical"], *endpoint["hostNames"]["aliases"]}
        development = self._bind_project(project, self.projects[project])
        for index in range(1, 10_001):
            candidate = base if index == 1 else f"{base}-{index}"
            probe = cast(Instance, {"project": project, "instanceKey": candidate, "canonical": False})
            if candidate not in used_keys and self._instance_hostnames(probe, development).isdisjoint(used_hostnames):
                return candidate
        raise ProjectError(f"Could not allocate a Development name for '{source}'")

    def _new_id(self, registry: Registry) -> str:
        used = {instance["id"] for instance in registry["instances"].values()}
        for _ in range(100):
            candidate = slugify(self.id_factory(), maximum=12)
            if candidate not in used:
                return candidate
        raise ProjectError("Could not allocate a unique Development instance ID")

    def _instance(self, registry: Registry, checkout: Checkout, requested_name: str | None) -> Instance:
        """The instance for a checkout, created if needed."""
        instance = self._matching_instance(registry, checkout, requested_name)
        if instance is not None:
            if instance["canonical"]:
                instance["checkout"] = str(checkout.root.resolve())
            self._bind_execution(instance)
            self._reconcile_topology(registry, instance)
            return instance
        instance_id = self._new_id(registry)
        canonical = checkout.canonical and requested_name is None
        instance = cast(Instance, {
            "id": instance_id,
            "identity": f"{checkout.project}:{instance_id}",
            "instanceKey": "default",
            "project": checkout.project,
            "checkout": str(checkout.root.resolve()),
            "canonical": canonical,
            "requestedName": requested_name,
            "workspaceName": checkout.workspace_name,
            "desiredState": "idle",
            "createdAt": self.now(),
            "lastSeenAt": self.now(),
            "missingSince": None,
            "missingStoppedAt": None,
            "available": checkout.root.exists(),
            "ports": {},
            "endpointLifecycle": {},
            "installedUnits": [],
        })
        self._bind_execution(instance)
        if not canonical:
            # A workspace runtime names its own directory, so prefer that.
            source = (
                checkout.root.name
                if instance.get("execution") and requested_name is None
                else requested_name or checkout.workspace_name or checkout.branch or checkout.root.name
            )
            instance["instanceKey"] = self._new_instance_key(registry, checkout.project, source)
        registry["instances"][instance["identity"]] = instance
        self._reconcile_topology(registry, instance)
        return instance

    def _reconcile_topology(self, registry: Registry, instance: Instance) -> None:
        development = self._development(instance)
        resources.ensure_ports(self.ports, registry, instance, development)
        lifecycle = instance["endpointLifecycle"]
        instance["endpointLifecycle"] = {name: lifecycle.get(name, _lifecycle()) for name in development["endpoints"]}

    def _storage_root(self, project_name: str, kind: str) -> pathlib.Path:
        if self.projects[project_name].get("delegated", False):
            return pathlib.Path(self.catalog["developmentGrants"][f"{kind}Root"])
        return pathlib.Path(self.catalog["stateRoot" if kind == "state" else "cacheRoot"])

    def _paths(self, instance: Instance) -> dict[str, pathlib.Path]:
        suffix = pathlib.Path(instance["project"]) / "instances" / instance["instanceKey"]
        return {
            "state": self._storage_root(instance["project"], "state") / suffix,
            "cache": self._storage_root(instance["project"], "cache") / suffix,
            "runtime": pathlib.Path(self.catalog["runtimeRoot"]) / suffix,
        }

    def _unit_names(self, instance: Instance) -> UnitNames:
        return unit_names(instance, self._development(instance)["endpoints"])

    # Runtime manifest and workspace binding

    def _manifest(self, instance: Instance) -> dict[str, Any]:
        """The runtime manifest `project-context` reads (schema 3)."""
        development, paths = self._development(instance), self._paths(instance)
        endpoints: dict[str, Any] = {}
        for name, endpoint in sorted(development["endpoints"].items()):
            local = endpoint["visibility"] == "local"
            host_names = [] if local else published_hostnames(instance, endpoint)
            ports = instance["ports"][name]
            value: dict[str, Any] = {
                "protocol": endpoint["protocol"],
                "listen": {
                    "host": "0.0.0.0" if instance.get("execution") else "127.0.0.1",
                    "port": instance.get("internalPorts", {}).get(name, ports["backend"]),
                },
            }
            if endpoint["protocol"] == "http":
                value["url"] = f"http://127.0.0.1:{ports['frontend']}" if local else f"https://{host_names[0]}"
                value["hostNames"] = host_names
                value["visibility"] = endpoint["visibility"]
            endpoints[name] = value
        parameters = dict(development["parameters"])
        checkout = instance["checkout"]
        if execution := instance.get("execution"):
            checkout = str(pathlib.Path(execution["visibleRoot"]) / pathlib.Path(checkout).relative_to(execution["root"]))
            # Workspace loopback is private; the host's loopback services
            # (such as a telemetry collector) are reached through its gateway.
            if gateway := self.catalog.get("workspaceHostGateway"):
                parameters = {
                    name: value.replace("://127.0.0.1:", f"://{gateway}:") if isinstance(value, str) else value
                    for name, value in parameters.items()
                }
        return {
            "schemaVersion": 3,
            "instanceId": instance["id"],
            "bindings": instance.get("resourceBindings", {}),
            "project": instance["project"],
            "realization": "development",
            "paths": {
                "checkout": checkout,
                "state": str(paths["state"]),
                "cache": str(paths["cache"]),
                "runtime": str(paths["runtime"]),
            },
            "endpoints": endpoints,
            "parameters": parameters,
            "secrets": {name: name for name in sorted(development["secrets"])},
        }

    def _materialize_manifest(self, instance: Instance) -> pathlib.Path:
        paths = self._paths(instance)
        for path in paths.values():
            path.mkdir(parents=True, exist_ok=True, mode=0o700)
            path.chmod(0o700)
        (paths["runtime"] / "secrets").mkdir(parents=True, exist_ok=True, mode=0o700)
        manifest = paths["runtime"] / "runtime.json"
        atomic_json(manifest, self._manifest(instance))
        if execution := instance.get("execution"):
            (paths["runtime"] / "workspace-secrets").mkdir(mode=0o700, exist_ok=True)
            development = self._development(instance)
            execution_file = paths["runtime"] / "execution.json"
            atomic_json(
                execution_file,
                {
                    "execution": execution,
                    "instanceId": instance["id"],
                    "checkout": instance["checkout"],
                    "default": instance.get("requestedName") is None,
                    "executable": development["runtimeExecutable"],
                    "paths": {name: str(path) for name, path in paths.items()},
                    "secrets": {name: secret["path"] for name, secret in development["secrets"].items()},
                    "endpoints": {
                        name: {"host": instance["ports"][name]["backend"], "guest": port}
                        for name, port in instance.get("internalPorts", {}).items()
                    },
                },
            )
            self.runner.run(
                [self.catalog["workspaceLauncher"], "bind-project", "--cwd", instance["checkout"], "--file", str(execution_file)]
            )
        return manifest

    def _unbind_execution(self, instance: Instance) -> None:
        if execution := instance.get("execution"):
            self.runner.run(
                [self.catalog["workspaceLauncher"], "unbind-project", "--cwd", execution["root"], "--instance", instance["id"]]
            )

    # Registry persistence

    def _routes(self, registry: Registry) -> list[dict[str, Any]]:
        routes: list[dict[str, Any]] = []
        for instance in registry["instances"].values():
            if (
                not instance["available"]
                or instance["project"] not in self.projects
                or instance["desiredState"] in ("paused", "retired")
            ):
                continue
            for name, endpoint in sorted(self._development(instance)["endpoints"].items()):
                if endpoint["visibility"] == "local" or endpoint["protocol"] != "http":
                    continue
                for hostname in published_hostnames(instance, endpoint):
                    routes.append({
                        "name": route_name(instance, name, hostname),
                        "hostName": hostname,
                        "visibility": endpoint["visibility"],
                        "upstreamPort": instance["ports"][name]["frontend"],
                    })
        return sorted(routes, key=lambda route: route["name"])

    def _save(self, registry: Registry) -> None:
        registry.setdefault("delegatedProjects", {}).update(
            {name: project for name, project in self.projects.items() if project.get("delegated", False)}
        )
        self.store.save(registry, self._routes(registry))

    def _set_operation(self, identity: str, phase: OperationPhase, *, detail: str | None = None, finished: bool = False) -> None:
        with self.store.locked() as registry:
            instance = registry["instances"].get(identity)
            if instance is None:
                return
            starts = phase in ("installing-runtime", "refreshing-bundle")
            previous = instance.get("operation", {})
            operation: dict[str, Any] = {
                "phase": phase,
                "startedAt": self.now() if starts else previous.get("startedAt", self.now()),
                "updatedAt": self.now(),
            }
            if detail is not None:
                operation["detail"] = detail
            if finished:
                operation["finishedAt"] = self.now()
            instance["operation"] = cast(Any, operation)
            self._save(registry)

    # Fingerprints decide when installed units must be replaced

    def _policy_fingerprint(self, instance: Instance) -> str:
        payload = {
            "version": POLICY_FINGERPRINT_VERSION,
            "checkout": instance["checkout"],
            "execution": instance.get("execution"),
            "development": self._development(instance),
        }
        return hashlib.sha256(json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()).hexdigest()

    @staticmethod
    def _credential_fingerprint(development: Development) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for name, secret in sorted(development["secrets"].items()):
            path = pathlib.Path(secret["path"])
            try:
                with path.open("rb") as stream:
                    size = os.fstat(stream.fileno()).st_size
                    digest = hashlib.file_digest(stream, "sha256").hexdigest()
                result[name] = {"path": str(path), "size": size, "sha256": digest}
            except FileNotFoundError:
                result[name] = {"path": str(path), "missing": True}
        return result

    def _runtime_is_current(self, instance: Instance) -> bool:
        return (
            instance.get("policyFingerprint") == self._policy_fingerprint(instance)
            and instance["installedUnits"] == self._unit_names(instance).all()
            and instance.get("credentialFingerprint") == self._credential_fingerprint(self._development(instance))
        )

    # Bundles

    def _bundle_root(self, instance: Instance) -> pathlib.Path:
        return self._paths(instance)["cache"] / "development-bundle"

    def _bundle_status(self, instance: Instance) -> dict[str, Any]:
        provenance = self._provenance(instance)
        return {
            "kind": provenance["kind"],
            "available": pathlib.Path(provenance["bundlePath"]).exists() if provenance.get("bundlePath") else False,
            "provenance": provenance,
        }

    def _provenance(self, instance: Instance) -> Provenance:
        """A checkout-built bundle, or the Project's pinned one."""
        provenance = instance.get("bundleProvenance", {})
        if provenance.get("kind") == "checkout":
            return provenance
        pinned = self.projects[instance["project"]]["pinnedBundle"]
        return {"kind": "pinned", **({"bundlePath": pinned} if pinned else {})}

    def _refresh(self, instance: Instance) -> Provenance:
        project = instance["project"]
        root = self._storage_root(project, "cache") / project / "bundles"
        build_link = self._bundle_root(instance).with_name("development-bundle-build")
        provenance = self.bundles.build(project, pathlib.Path(instance["checkout"]), root, build_link)
        self.bundles.retain(pathlib.Path(provenance["bundlePath"]), self._bundle_root(instance))
        build_link.unlink(missing_ok=True)
        if self.projects[project].get("delegated", False):
            descriptor, _ = contract.read_bundle(pathlib.Path(provenance["bundlePath"]), project)
            self.projects[project]["contract"] = descriptor
        return provenance

    # Installing and starting instances

    def _ensure_instance_runtime(self, identity: str, *, refresh_bundle: bool = False) -> Instance:
        """Binds the instance's bundle, allocates resources, writes its manifest and installs its units."""
        with self.store.instance_locked(identity):
            with self.store.locked() as registry:
                if identity not in registry["instances"]:
                    raise ProjectError("Development instance is no longer registered")
                current = snapshot(registry["instances"][identity])
            if current["desiredState"] in ("paused", "retired") and not refresh_bundle:
                self.services.remove(current["installedUnits"])
                return current
            self._set_operation(identity, "refreshing-bundle" if refresh_bundle else "installing-runtime")
            refreshed = self._refresh(current) if refresh_bundle else None
            with self.store.locked() as registry:
                if identity not in registry["instances"]:
                    raise ProjectError("Development instance is no longer registered")
                instance = registry["instances"][identity]
                provenance = refreshed or self._provenance(instance)
                if "bundlePath" not in provenance:
                    raise ProjectError("This Project has no prepared bundle; run `project dev bundle refresh`")
                bundle = pathlib.Path(provenance["bundlePath"])
                if not bundle.exists():
                    raise ProjectError("The Development bundle is no longer available; run `project dev bundle refresh`")
                instance["bundleProvenance"] = provenance
                instance["development"] = self._bind_path(instance["project"], str(bundle))
                self.report(f"Using {'refreshed' if provenance['kind'] == 'checkout' else 'pinned'} Development bundle.")
                self._reconcile_topology(registry, instance)
                plan = resources.plan_resources(self.ports, registry, instance, instance["development"], self._paths(instance))
                if plan.errors:
                    raise ProjectError("; ".join(plan.errors))
                resources.create_resources(plan)
                instance["resourceBindings"] = plan.bindings
                instance["resourceSecrets"] = plan.credentials
                names = self._unit_names(instance)
                units = names.all()
                changed = not self._runtime_is_current(instance)
                if changed:
                    for lifecycle in instance["endpointLifecycle"].values():
                        lifecycle["phase"] = "dormant"
                        lifecycle["lastStoppedAt"] = self.now()
                installed = snapshot(instance)
                self._materialize_manifest(installed)
                self._save(registry)
                old_units = list(instance["installedUnits"])
            self.bundles.retain(bundle, self._bundle_root(installed))
            if changed or installed["desiredState"] not in ("idle", "active"):
                self.services.remove(sorted(set(old_units) | set(units)))
            if installed["desiredState"] in ("idle", "active"):
                self.services.install(installed, self._development(installed), names)
                self.services.start([pair.socket for pair in names.endpoints.values()])
                if installed["desiredState"] == "active":
                    self._start_background(installed)
            with self.store.locked() as registry:
                instance = registry["instances"][identity]
                instance["installedUnits"] = units
                instance["policyFingerprint"] = self._policy_fingerprint(instance)
                instance["credentialFingerprint"] = self._credential_fingerprint(self._development(instance))
                self._save(registry)
                result = snapshot(instance)
            self._set_operation(identity, "prepared", finished=True)
            return result

    def _register(self, checkout: Checkout, name: str | None, *, refresh_bundle: bool = False, activate: bool = False) -> Instance:
        with self.store.locked() as registry:
            created = self._matching_instance(registry, checkout, name) is None
            instance = self._instance(registry, checkout, name)
            if activate:
                instance["desiredState"] = "active"
            instance.update({"lastSeenAt": self.now(), "missingSince": None, "missingStoppedAt": None, "available": True})
            identity = instance["identity"]
            self._save(registry)
        if created:
            self.report(f"Registered {instance['instanceKey']}.")
        if self._provenance(instance).get("bundlePath") is None:
            refresh_bundle = True
        try:
            return self._ensure_instance_runtime(identity, refresh_bundle=refresh_bundle)
        except ProjectError as error:
            self._set_operation(identity, "failed", detail=str(error), finished=True)
            raise

    def _start_background(self, instance: Instance) -> None:
        if any(w["lifecycle"] == "background" for w in self._development(instance)["workloads"].values()):
            self.services.start([self._unit_names(instance).manager])

    @staticmethod
    def _select_workloads(development: Development, only: str | None) -> list[str]:
        workloads = sorted(development["workloads"])
        if only is not None and only not in workloads:
            raise ProjectError(f"Unknown Workload: {only}")
        return workloads if only is None else [only]

    def _endpoint_services(self, instance: Instance, workloads: set[str]) -> list[str]:
        development, names = self._development(instance), self._unit_names(instance)
        return [
            pair.service
            for name, pair in names.endpoints.items()
            if development["endpoints"][name]["workload"] in workloads
        ]

    # Commands

    def _locate(self, registry: Registry, *, cwd: pathlib.Path, project: str | None, name: str | None) -> Instance:
        try:
            instance = self._matching_instance(registry, self.discovery.resolve(cwd, project), name)
            if instance is not None:
                return instance
        except ProjectError:
            pass
        if project and name and not os.environ.get("PROJECT_WORKSPACE_ROOT"):
            matches = [
                i for i in registry["instances"].values() if i["project"] == project and i.get("requestedName") == name
            ]
            if len(matches) == 1:
                return matches[0]
        raise ProjectError("No registered Development instance matches this workspace")

    def _identity(self, *, cwd: pathlib.Path, project: str | None, name: str | None) -> str:
        with self.store.locked() as registry:
            return self._locate(registry, cwd=cwd, project=project, name=name)["identity"]

    def bundle_status(self, *, cwd: pathlib.Path, project: str | None = None, name: str | None = None) -> dict[str, Any]:
        with self.store.locked() as registry:
            return self._bundle_status(self._locate(registry, cwd=cwd, project=project, name=name))

    def refresh_bundle(self, *, cwd: pathlib.Path, project: str | None = None, name: str | None = None) -> Instance:
        return self._register(self.discovery.resolve(cwd, project), name, refresh_bundle=True)

    def reset_bundle(self, *, cwd: pathlib.Path, project: str | None = None, name: str | None = None) -> Instance:
        with self.store.locked() as registry:
            instance = self._locate(registry, cwd=cwd, project=project, name=name)
            instance.pop("bundleProvenance", None)
            instance.pop("development", None)
            self._save(registry)
            identity = instance["identity"]
        self.report("Reset to pinned Development bundle.")
        return self._ensure_instance_runtime(identity)

    def up(self, *, cwd: pathlib.Path, project: str | None = None, name: str | None = None, only: str | None = None) -> Instance:
        instance = self._register(self.discovery.resolve(cwd, project), name, activate=True)
        selected = self._select_workloads(self._development(instance), only)
        self._set_operation(instance["identity"], "starting", detail=", ".join(selected))
        try:
            units = self._endpoint_services(instance, set(selected))
            # Worker-only instances have no ingress to warm.
            self.report("Starting " + ", ".join(selected) + "...")
            self.services.warm(units or [self._unit_names(instance).manager])
        except Exception as error:
            self._set_operation(instance["identity"], "failed", detail=str(error), finished=True)
            raise
        self._set_operation(instance["identity"], "ready", finished=True)
        with self.store.locked() as registry:
            return snapshot(registry["instances"][instance["identity"]])

    def down(self, *, cwd: pathlib.Path, project: str | None = None, name: str | None = None, only: str | None = None) -> Instance:
        """Pauses the instance, or with `only` stops one workload's endpoints and keeps it active."""
        identity = self._identity(cwd=cwd, project=project, name=name)
        if only is None:
            return self._deactivate(identity, "paused")
        with self.store.instance_locked(identity):
            with self.store.locked() as registry:
                instance = registry["instances"][identity]
                self._select_workloads(self._development(instance), only)
                services = self._endpoint_services(instance, {only})
                names = self._unit_names(instance)
                affected = [name for name, pair in names.endpoints.items() if pair.service in services]
            for unit in services:
                self.services.stop(unit)
            with self.store.locked() as registry:
                instance = registry["instances"][identity]
                for endpoint in affected:
                    instance["endpointLifecycle"][endpoint].update({"phase": "dormant", "lastStoppedAt": self.now()})
                self._save(registry)
                return snapshot(instance)

    def restart(self, *, cwd: pathlib.Path, project: str | None = None, name: str | None = None, only: str | None = None) -> Instance:
        self.down(cwd=cwd, project=project, name=name, only=only)
        return self.up(cwd=cwd, project=project, name=name, only=only)

    def _deactivate(self, identity: str, desired_state: DesiredState) -> Instance:
        """Withdraws demand before stopping units so reconciliation cannot revive them."""
        with self.store.instance_locked(identity):
            with self.store.locked() as registry:
                instance = registry["instances"][identity]
                instance["desiredState"] = desired_state
                units = set(instance["installedUnits"])
                with contextlib.suppress(ProjectError):
                    units |= set(self._unit_names(instance).all())
                for lifecycle in instance["endpointLifecycle"].values():
                    lifecycle.update({"phase": "dormant", "lastStoppedAt": self.now()})
                self._save(registry)
                result = snapshot(instance)
            self.services.remove(sorted(units))
            if desired_state == "retired":
                self._unbind_execution(result)
            return result

    def retire(self, *, cwd: pathlib.Path, project: str | None = None, name: str | None = None) -> Instance:
        return self._deactivate(self._identity(cwd=cwd, project=project, name=name), "retired")

    def retire_workspace(self, root: pathlib.Path) -> list[Instance]:
        with self.store.locked() as registry:
            identities = [
                i["identity"]
                for i in registry["instances"].values()
                if i.get("execution", {}).get("root") == str(root.resolve())
            ]
        return [self._deactivate(identity, "retired") for identity in identities]

    def relocate(self, instance_id: str, checkout_path: pathlib.Path) -> Instance:
        """Rebinds a retained instance to another checkout, keeping its ID, published ports and data."""
        with self.store.locked() as registry:
            matches = [value for value in registry["instances"].values() if value["id"] == instance_id]
            if len(matches) != 1:
                raise ProjectError(f"Unknown Development instance ID: {instance_id}")
            previous = snapshot(matches[0])
        checkout = self.discovery.resolve(checkout_path, previous["project"])
        if previous["canonical"] or checkout.canonical:
            raise ProjectError("Canonical checkout placement is managed by host policy")
        self._deactivate(previous["identity"], "paused")
        self._unbind_execution(previous)
        with self.store.instance_locked(previous["identity"]):
            with self.store.locked() as registry:
                instance = registry["instances"][previous["identity"]]
                other = self._matching_instance(registry, checkout, instance.get("requestedName"))
                if other is not None and other["id"] != instance_id:
                    raise ProjectError("The destination already has a Development instance")
                instance["checkout"] = str(checkout.root.resolve())
                instance.pop("execution", None)
                instance.pop("internalPorts", None)
                self._bind_execution(instance)
                if instance.get("execution") != previous.get("execution"):
                    instance.pop("resourcePorts", None)
                instance.update({
                    "workspaceName": checkout.workspace_name,
                    "available": checkout.root.exists(),
                    "missingSince": None,
                    "missingStoppedAt": None,
                })
                instance.pop("policyFingerprint", None)
                self._save(registry)
                return snapshot(instance)

    def reconcile(self) -> list[str]:
        """Registers canonical instances, tracks missing checkouts and repairs installed units."""
        actions: list[str] = []
        # Registration and state changes are short global transactions; slow
        # unit work is serialized per instance.
        with self.store.locked() as registry:
            for project_name, project in self.projects.items():
                if project["canonical"]:
                    path = pathlib.Path(project["repository"]["checkout"]).resolve()
                    self._instance(registry, Checkout(project_name, path, True, "default", None), None)
            self._save(registry)
            identities = list(registry["instances"])

        now = self.now()
        for identity in identities:
            with self.store.locked() as registry:
                instance = registry["instances"].get(identity)
                if instance is None:
                    continue
                enrolled = instance["project"] in self.projects
                units = list(instance["installedUnits"])
                key = instance["instanceKey"]
                if not enrolled:
                    instance.update({"desiredState": "retired", "available": False})
                    disposition = "removed"
                elif pathlib.Path(instance["checkout"]).exists():
                    instance.update({"missingSince": None, "missingStoppedAt": None, "available": True})
                    disposition = "present"
                else:
                    missing_since = instance.get("missingSince") or now
                    instance["missingSince"] = missing_since
                    absent = now - missing_since
                    disposition = "missing-grace"
                    if absent >= self.catalog["missingGraceSec"]:
                        instance["available"] = False
                        instance["missingStoppedAt"] = instance.get("missingStoppedAt") or now
                        disposition = "missing-stopped"
                    if absent >= self.catalog["garbageCollectAfterSec"] and not instance["canonical"]:
                        instance["desiredState"] = "retired"
                        disposition = "retired"
                self._save(registry)
            if disposition == "present":
                # Evaluating repository Nix here could hold the instance lock
                # behind a remote builder, so bundle refresh stays explicit.
                try:
                    self._ensure_instance_runtime(identity)
                except ProjectError as error:
                    # One instance's contract drift must not block the others.
                    self._set_operation(identity, "failed", detail=str(error), finished=True)
                    action = f"skipped {key}: {error}"
                    actions.append(action)
                    self.report(action)
            elif disposition != "missing-grace":
                self.services.remove(units)
                actions.append(f"{'suspended' if disposition == 'missing-stopped' else 'retired'} {key}")
        return actions

    def list_instances(self, project: str | None = None) -> list[Instance]:
        workspace_root = os.environ.get("PROJECT_WORKSPACE_ROOT")
        with self.store.locked() as registry:
            return sorted(
                (
                    snapshot(instance)
                    for instance in registry["instances"].values()
                    if (project is None or instance["project"] == project)
                    and (not workspace_root or instance.get("execution", {}).get("root") == workspace_root)
                ),
                key=lambda instance: (instance["project"], instance["instanceKey"]),
            )

    def status(self, *, cwd: pathlib.Path, project: str | None = None, name: str | None = None) -> dict[str, Any]:
        with self.store.locked() as registry:
            instance = self._locate(registry, cwd=cwd, project=project, name=name)
            result: dict[str, Any] = dict(snapshot(instance))
            names = self._unit_names(instance)
            result["managerActive"] = self.services.is_active(names.manager)
            endpoints = self._manifest(instance)["endpoints"]
            for endpoint, value in endpoints.items():
                value["lifecycle"] = instance["endpointLifecycle"][endpoint]
                value["activationListen"] = {"host": "127.0.0.1", "port": instance["ports"][endpoint]["frontend"]}
                value["socketActive"] = self.services.is_active(names.endpoints[endpoint].socket)
                value["proxyActive"] = self.services.is_active(names.endpoints[endpoint].service)
            result["endpoints"] = endpoints
            result["bundle"] = self._bundle_status(instance)
            return result

    def urls(self, *, cwd: pathlib.Path, project: str | None = None, name: str | None = None, only: str | None = None) -> dict[str, str]:
        with self.store.locked() as registry:
            instance = self._locate(registry, cwd=cwd, project=project, name=name)
            development = self._development(instance)
            selected = set(self._select_workloads(development, only))
            return {
                endpoint: value["url"]
                for endpoint, value in self._manifest(instance)["endpoints"].items()
                if "url" in value and development["endpoints"][endpoint]["workload"] in selected
            }

    def logs(self, *, cwd: pathlib.Path, project: str | None = None, name: str | None = None, only: str | None = None) -> None:
        with self.store.locked() as registry:
            instance = self._locate(registry, cwd=cwd, project=project, name=name)
            development = self._development(instance)
            workloads = self._select_workloads(development, only)
            units = [self._unit_names(instance).manager, *self._endpoint_services(instance, set(workloads))]
        if only is None:
            self.services.logs(units)
            return
        # The manager prefixes each process's lines with its devenv name.
        processes = [re.escape(development["workloads"][name]["action"]) for name in workloads]
        self.services.logs(units, pattern=r"^\[(" + "|".join(processes) + r")\]")

    def _current_instance(self, *, cwd: pathlib.Path, project: str | None, name: str | None) -> Instance | None:
        """The innermost active, current instance containing cwd, found without Git."""
        cwd = cwd.resolve()
        with self.store.locked() as registry:
            matches: list[tuple[int, Instance]] = []
            for instance in registry["instances"].values():
                checkout = pathlib.Path(instance["checkout"]).resolve()
                if (
                    instance["available"]
                    and instance["desiredState"] == "active"
                    and (project is None or instance["project"] == project)
                    and instance.get("requestedName") == name
                    and inside(cwd, checkout)
                    and self._runtime_is_current(instance)
                ):
                    matches.append((len(checkout.parts), instance))
            if not matches:
                return None
            instance = max(matches, key=lambda match: match[0])[1]
            if self.now() - instance.get("lastSeenAt", 0) >= 60:
                instance["lastSeenAt"] = self.now()
                self._save(registry)
            return snapshot(instance)

    def run_command(self, *, cwd: pathlib.Path, command_name: str, arguments: Sequence[str], project: str | None = None, name: str | None = None) -> None:
        """Runs a declared command inside the instance, after its dependencies are ready."""
        instance = self._current_instance(cwd=cwd, project=project, name=name) or self._register(
            self.discovery.resolve(cwd, project), name, activate=True
        )
        development = self._development(instance)
        command = development["commands"].get(command_name)
        if command is None:
            raise ProjectError(f"Unknown Development command: {command_name}")
        manifest = self._materialize_manifest(instance)
        secrets_directory = self._paths(instance)["runtime"] / "secrets"
        for secret_name in command["secrets"]:
            target = secrets_directory / secret_name
            target.unlink(missing_ok=True)
            target.symlink_to(development["secrets"][secret_name]["path"])
        environment = {**os.environ, "PROJECT_RUNTIME_FILE": str(manifest), "PROJECT_SECRETS_DIR": str(secrets_directory)}
        environment.update(self._execution_environment(instance))
        manager = self._unit_names(instance).manager
        os.chdir(instance["checkout"])
        invocation = [
            "systemd-run", "--user", "--scope", "--quiet", "--expand-environment=no",
            f"--property=Requires={manager}", f"--property=After={manager}",
            "--", development["runtimeExecutable"], "command", command_name, *arguments,
        ]
        os.execvpe(invocation[0], invocation, environment)

    def _execution_environment(self, instance: Instance) -> dict[str, str]:
        if not instance.get("execution"):
            return {}
        return {
            "PROJECT_EXECUTION_FILE": str(self._paths(instance)["runtime"] / "execution.json"),
            "PROJECT_WORKSPACE_LAUNCHER": self.catalog["workspaceLauncher"],
        }

    def _registered(self, identity: str) -> tuple[Instance, Development]:
        with self.store.locked() as registry:
            instance = registry["instances"].get(identity)
            if instance is None:
                raise ProjectError("Unknown Development instance identity")
            if instance["desiredState"] in ("paused", "retired"):
                raise ProjectError(f"Development instance is {instance['desiredState']}; run `project dev up` to resume")
            if not instance["available"] or not pathlib.Path(instance["checkout"]).exists():
                raise ProjectError("Development instance Checkout is unavailable")
            return snapshot(instance), self._development(instance)

    def run_manager(self, identity: str) -> None:
        """The manager unit's ExecStart: runs the bundle's devenv manager for the instance."""
        instance, development = self._registered(identity)
        environment = {**os.environ, "PROJECT_RUNTIME_FILE": str(self._materialize_manifest(instance))}
        environment.update(self._execution_environment(instance))
        if instance.get("execution"):
            environment["AGENT_SERVICE_UNIT"] = self._unit_names(instance).manager
        if environment.get("CREDENTIALS_DIRECTORY"):
            environment["PROJECT_SECRETS_DIR"] = environment["CREDENTIALS_DIRECTORY"]
        executable = development["runtimeExecutable"]
        os.chdir(instance["checkout"])
        os.execve(executable, [executable, "manager"], environment)

    def _demand(self, instance: Instance, operation: str, endpoint: str) -> None:
        """Asks the devenv manager to start or release the endpoint's process closure."""
        development = self._development(instance)
        arguments = [development["runtimeExecutable"], "control", operation, f"endpoint:{endpoint}"]
        if operation == "acquire":
            arguments.append(development["endpoints"][endpoint]["workload"])
        manifest = self._paths(instance)["runtime"] / "runtime.json"
        self.runner.run(["env", f"PROJECT_RUNTIME_FILE={manifest}", *arguments])

    def _set_lifecycle(self, identity: str, endpoint: str, **fields: Any) -> Lifecycle:
        with self.store.locked() as registry:
            lifecycle = registry["instances"][identity]["endpointLifecycle"][endpoint]
            lifecycle.update(cast(Lifecycle, fields))
            self._save(registry)
            return snapshot(lifecycle)

    def endpoint_activate(self, identity: str, endpoint: str) -> Lifecycle:
        """The proxy's ExecStartPre: starts the endpoint's process and waits until it is ready."""
        # Endpoints may probe readiness concurrently; topology and stop
        # operations keep exclusive ownership of the instance.
        with self.store.instance_locked(identity, shared=True), self.store.endpoint_locked(identity, endpoint):
            instance, development = self._registered(identity)
            if endpoint not in development["endpoints"]:
                raise ProjectError(f"Unknown Endpoint: {endpoint}")
            with self.store.locked() as registry:
                registry["instances"][identity]["desiredState"] = "active"
                self._save(registry)
            self._set_lifecycle(identity, endpoint, phase="activating", lastActivationAt=self.now(), lastFailure=None)
            declared = development["endpoints"][endpoint]
            try:
                if instance["desiredState"] == "idle":
                    self._start_background(instance)
                self._demand(instance, "acquire", endpoint)
                backend = instance["ports"][endpoint]["backend"]
                assert backend is not None, "ports are allocated before units are installed"
                self.readiness.wait(declared["protocol"], backend, declared["health"])
            except Exception as error:
                self._set_lifecycle(identity, endpoint, phase="failed", lastFailure={"at": self.now(), "message": str(error)})
                raise
            return self._set_lifecycle(identity, endpoint, phase="ready", lastReadyAt=self.now())

    def endpoint_finished(self, identity: str, endpoint: str) -> Lifecycle | dict[str, Any]:
        """The proxy's ExecStopPost: marks the endpoint dormant and releases its demand."""
        # Takes only the short registry lock: a lifecycle command may hold the
        # instance lock while it waits for systemctl to stop this unit.
        with self.store.locked() as registry:
            instance = registry["instances"].get(identity)
            if instance is None or endpoint not in instance["endpointLifecycle"]:
                return {}
            lifecycle = instance["endpointLifecycle"][endpoint]
            if os.environ.get("SERVICE_RESULT", "success") == "success" or lifecycle["phase"] != "failed":
                lifecycle.update({"phase": "dormant", "lastStoppedAt": self.now()})
            self._save(registry)
            current, result = snapshot(instance), snapshot(lifecycle)
        with contextlib.suppress(subprocess.CalledProcessError):
            self._demand(current, "release", endpoint)
        return result
