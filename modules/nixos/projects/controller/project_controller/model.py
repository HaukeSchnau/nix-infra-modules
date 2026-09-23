"""Shapes of the catalog written by Nix and the registry kept by the controller.

The registry is JSON on disk, so these are TypedDicts over plain dicts rather
than classes. Optional keys use NotRequired.
"""

from __future__ import annotations

from typing import Any, Literal, NotRequired, TypedDict

DesiredState = Literal["idle", "active", "paused", "retired"]
EndpointPhase = Literal["dormant", "activating", "ready", "failed"]
OperationPhase = Literal[
    "installing-runtime", "refreshing-bundle", "starting", "ready", "prepared", "failed"
]
Visibility = Literal["local", "tailnet", "public"]


class SecretBinding(TypedDict):
    path: str


class EndpointPolicy(TypedDict, total=False):
    hostName: str | None
    aliases: list[str]
    visibility: Visibility | None


class Policy(TypedDict):
    """Host policy for one Project, applied to whatever contract a bundle carries."""

    parameters: dict[str, Any]
    secrets: dict[str, SecretBinding]
    endpoints: dict[str, EndpointPolicy]
    idleTimeoutSec: int


class CatalogProject(TypedDict):
    owner: str
    group: str
    repository: dict[str, str]
    # Store path of the prepared bundle built from the pinned input; None for
    # delegated projects until their first refresh.
    pinnedBundle: str | None
    canonical: bool
    policy: Policy
    delegated: NotRequired[bool]
    # A delegated Project's contract, known from inspection before its first bundle.
    contract: NotRequired[dict[str, Any]]


class Catalog(TypedDict):
    schemaVersion: int
    catalogFile: str
    controllerExecutable: str
    socketProxyExecutable: str
    systemdUnitRoot: str
    workspaceLauncher: NotRequired[str]
    # Where a workspace reaches the host's loopback services, if not directly.
    workspaceHostGateway: NotRequired[str | None]
    bundleBuilder: str
    developmentDomain: str
    portRange: dict[str, int]
    stateRoot: str
    cacheRoot: str
    runtimeRoot: str
    registryFile: str
    routeSourceFile: str
    developmentGrants: dict[str, Any]
    # Defaults for delegated Projects and for missing-checkout handling.
    idleTimeoutSec: int
    missingGraceSec: int
    garbageCollectAfterSec: int
    projects: dict[str, CatalogProject]


class HostNames(TypedDict):
    canonical: str
    aliases: list[str]
    instanceTemplate: str


class Endpoint(TypedDict):
    workload: str
    protocol: Literal["http", "tcp"]
    port: int | None
    publication: Literal["private", "preview"]
    health: dict[str, Any]
    visibility: Visibility
    hostNames: HostNames


class Workload(TypedDict):
    action: str
    kind: Literal["service", "task"]
    lifecycle: Literal["on-demand", "background"]
    dependsOn: list[str]
    secrets: list[str]


class Development(TypedDict):
    """A bundle's contract bound to host policy."""

    runtimeExecutable: str
    parameters: dict[str, Any]
    requirements: dict[str, Any]
    providers: dict[str, Any]
    workloads: dict[str, Workload]
    commands: dict[str, dict[str, Any]]
    endpoints: dict[str, Endpoint]
    secrets: dict[str, SecretBinding]
    preparation: dict[str, Any]
    idleTimeoutSec: int


class Lifecycle(TypedDict):
    phase: EndpointPhase
    lastActivationAt: float | None
    lastReadyAt: float | None
    lastStoppedAt: float | None
    lastFailure: dict[str, Any] | None


class PortPair(TypedDict):
    frontend: int | None
    backend: int | None


class Operation(TypedDict, total=False):
    phase: OperationPhase
    startedAt: float
    updatedAt: float
    finishedAt: float
    detail: str


class Provenance(TypedDict, total=False):
    kind: Literal["pinned", "checkout"]
    bundlePath: str
    sourceDigest: str
    builder: str
    project: str
    builderVersion: int
    vcs: str
    fileCount: int
    builtAt: float
    cacheHit: bool


class Instance(TypedDict):
    id: str
    identity: str
    instanceKey: str
    project: str
    checkout: str
    canonical: bool
    requestedName: str | None
    workspaceName: NotRequired[str | None]
    desiredState: DesiredState
    createdAt: NotRequired[float]
    lastSeenAt: NotRequired[float]
    missingSince: NotRequired[float | None]
    missingStoppedAt: NotRequired[float | None]
    available: bool
    ports: dict[str, PortPair]
    internalPorts: NotRequired[dict[str, int]]
    resourcePorts: NotRequired[dict[str, int]]
    endpointLifecycle: dict[str, Lifecycle]
    installedUnits: list[str]
    execution: NotRequired[dict[str, Any]]
    bundleProvenance: NotRequired[Provenance]
    development: NotRequired[Development]
    resourceBindings: NotRequired[dict[str, Any]]
    resourceSecrets: NotRequired[dict[str, SecretBinding]]
    policyFingerprint: NotRequired[str]
    credentialFingerprint: NotRequired[dict[str, Any]]
    operation: NotRequired[Operation]


class Registry(TypedDict):
    schemaVersion: int
    instances: dict[str, Instance]
    delegatedProjects: NotRequired[dict[str, CatalogProject]]
