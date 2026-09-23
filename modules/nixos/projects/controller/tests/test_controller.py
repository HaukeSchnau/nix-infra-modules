from __future__ import annotations

import concurrent.futures
import copy
import io
import json
import pathlib
import subprocess
import tempfile
import threading
import time
import unittest
from unittest import mock

from project_controller import cli, controller as controller_module
from project_controller.bundles import BundleBuilder
from project_controller.controller import Controller
from project_controller.discovery import Checkout, CheckoutDiscovery
from project_controller.registry import RegistryStore
from project_controller.systemd import SystemdUserServices
from project_controller.util import ProjectError, normalized_repository_url, slugify

DOMAIN = "dev.example.test"


def descriptor() -> dict:
    """A normalized descriptor as the SDK exports it."""

    def health(paths, startup, request, interval):
        return {"startupTimeoutSec": startup, "requestTimeoutSec": request, "intervalSec": interval} | (
            {"paths": paths} if paths is not None else {}
        )

    def workload(name, depends=(), secrets=(), lifecycle="on-demand"):
        return {"action": name, "kind": "service", "dependsOn": list(depends), "secrets": list(secrets), "lifecycle": lifecycle}

    def endpoint(workload_name, protocol="http", paths=("/",), startup=5, request=3, interval=2, port=None):
        return {
            "workload": workload_name,
            "protocol": protocol,
            "port": port,
            "publication": "preview",
            "health": health(list(paths) if protocol == "http" else None, startup, request, interval),
        }

    return {
        "schemaVersion": 4,
        "project": "studienbuch",
        "parameters": {"flavour": {"type": "string", "description": "", "required": False, "default": "development"}},
        "secrets": {"better-auth": {"description": "", "required": True}},
        "requirements": {
            "better-auth": {
                "kind": "secret", "description": "", "required": True,
                "realizations": ["development", "release"], "generate": None,
            }
        },
        "environment": {},
        "release": None,
        "development": {
            "workloads": {
                "database": workload("database"),
                "web": workload("web", ["database"], ["better-auth"]),
                "mobile": workload("mobile"),
            },
            "commands": {"console": {"action": "console", "dependsOn": ["database"], "secrets": ["better-auth"]}},
            "endpoints": {
                "web": endpoint("web", paths=["/health", "/assets/app.css"]),
                "mobile": endpoint("mobile", paths=["/status"], startup=10, request=4, interval=1),
                "database": endpoint("database", protocol="tcp", startup=8, request=2, interval=1),
            },
            "preparation": {"action": "prepare", "secrets": [], "timeoutSec": 30},
            "providers": {},
        },
    }


def write_bundle(root: pathlib.Path, value: dict) -> pathlib.Path:
    executable = root / "bin/studienbuch-project-runtime"
    executable.parent.mkdir(parents=True, exist_ok=True)
    executable.write_text("#!/bin/sh\n")
    metadata = root / "share/project"
    metadata.mkdir(parents=True, exist_ok=True)
    (metadata / "bundle.json").write_text(
        json.dumps({"schemaVersion": 2, "project": "studienbuch", "entrypoint": "bin/studienbuch-project-runtime"})
    )
    (metadata / "project.json").write_text(json.dumps(value))
    return root


class FakeDiscovery:
    def __init__(self, checkouts):
        self.checkouts = {pathlib.Path(path).resolve(): value for path, value in checkouts.items()}

    def resolve(self, cwd, requested=None):
        value = self.checkouts[pathlib.Path(cwd).resolve()]
        if requested and requested != value.project:
            raise ProjectError("wrong project")
        return value


class FakeServices:
    def __init__(self):
        self.active, self.installs, self.removes, self.warms, self.starts, self.stops, self.log_units = set(), [], [], [], [], [], []

    def is_active(self, unit):
        return unit in self.active

    def install(self, instance, development, names):
        self.installs.append((instance["identity"], names))

    def start(self, units):
        self.starts.append(list(units))
        self.active.update(units)

    def warm(self, units):
        self.warms.append(list(units))
        self.active.update(units)

    def stop(self, unit):
        self.stops.append(unit)
        self.active.discard(unit)

    def remove(self, units):
        self.removes.append(list(units))
        self.active.difference_update(units)

    def logs(self, units, pattern=None):
        self.log_units.append((list(units), pattern))


class FakeReadiness:
    def __init__(self):
        self.calls, self.failures = [], set()

    def wait(self, protocol, port, health):
        self.calls.append((protocol, port, health))
        if port in self.failures:
            raise ProjectError(f"{protocol} not ready")


class Clock:
    def __init__(self, value=1000):
        self.value = value

    def __call__(self):
        return self.value


class Harness:
    def __init__(self, *, canonical=False, readiness=None, value=None):
        self.temp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temp.name)
        self.checkout, self.worktree, self.other = (self.root / name for name in ("checkouts/app", "worktrees/auth", "worktrees/other"))
        for path in (self.checkout, self.worktree, self.other):
            path.mkdir(parents=True)
        self.secret = self.root / "better-auth-secret"
        self.secret.write_text("TOP-SECRET-VALUE")
        self.bundle = write_bundle(self.root / "pinned-bundle", value or descriptor())
        self.catalog = {
            "schemaVersion": 2,
            "catalogFile": str(self.root / "catalog.json"),
            "controllerExecutable": "/nix/store/controller/bin/project",
            "socketProxyExecutable": "/nix/store/systemd/lib/systemd/systemd-socket-proxyd",
            "systemdUnitRoot": str(self.root / "systemd/user"),
            "bundleBuilder": "/nix/store/builder/bin/project-development-bundle",
            "developmentDomain": DOMAIN,
            "portRange": {"from": 21000, "to": 21039},
            "stateRoot": str(self.root / "state"),
            "cacheRoot": str(self.root / "cache"),
            "runtimeRoot": str(self.root / "runtime"),
            "registryFile": str(self.root / "registry.json"),
            "routeSourceFile": str(self.root / "routes.json"),
            "developmentGrants": {},
            "idleTimeoutSec": 1800,
            "missingGraceSec": 10,
            "garbageCollectAfterSec": 100,
            "projects": {
                "studienbuch": {
                    "owner": "user",
                    "group": "users",
                    "repository": {"url": "git@example.test:team/studienbuch.git", "checkout": str(self.checkout)},
                    "pinnedBundle": str(self.bundle),
                    "canonical": canonical,
                    "policy": {
                        "parameters": {},
                        "secrets": {"better-auth": {"path": str(self.secret)}},
                        "endpoints": {"web": {"aliases": ["legacy.example.test"]}},
                        "idleTimeoutSec": 1800,
                    },
                }
            },
        }
        self.services = FakeServices()
        self.readiness = readiness or FakeReadiness()
        self.clock = Clock()
        ids = iter(["abc123", "def456", "fed987", "aaa111"])
        self.discovery = FakeDiscovery({
            self.checkout: Checkout("studienbuch", self.checkout, True, "default", "main"),
            self.worktree: Checkout("studienbuch", self.worktree, False, "auth-redesign", "auth"),
            self.other: Checkout("studienbuch", self.other, False, "other", "other"),
        })
        self.controller = Controller(
            self.catalog, discovery=self.discovery, services=self.services, readiness=self.readiness,
            now=self.clock, id_factory=lambda: next(ids),
        )
        self.controller.bundles.retain = mock.Mock()
        self.controller._demand = mock.Mock()

    def registry(self):
        return json.loads(pathlib.Path(self.catalog["registryFile"]).read_text())

    def routes(self):
        return json.loads(pathlib.Path(self.catalog["routeSourceFile"]).read_text())

    def close(self):
        self.temp.cleanup()


class ControllerTestCase(unittest.TestCase):
    canonical = False

    def setUp(self):
        self.h = Harness(canonical=self.canonical)
        self.addCleanup(self.h.close)

    def with_requirements(self, *, postgres=True):
        value = descriptor()
        value["requirements"].update({
            "uploads": {"kind": "directory", "description": "", "required": True,
                        "realizations": ["development", "release"], "path": "uploads", "persistent": True},
            "session-key": {"kind": "secret", "description": "", "required": True,
                            "realizations": ["development", "release"], "generate": {"bytes": 32}},
        })
        value["secrets"]["session-key"] = {"description": "", "required": True}
        if postgres:
            value["requirements"]["database"] = {
                "kind": "postgresql", "description": "", "required": True,
                "realizations": ["development", "release"], "majorVersions": [17], "dataDirectory": "postgres",
            }
            value["development"]["providers"]["database"] = {
                "workload": "database", "port": 5432, "database": "test", "user": "postgres", "majorVersion": 17,
            }
        write_bundle(self.h.bundle, value)
        return value


class BindingTest(ControllerTestCase):
    def test_bundle_contract_is_bound_to_host_policy(self):
        instance = self.h.controller.up(cwd=self.h.worktree, only="web")
        bound = instance["development"]
        self.assertEqual(bound["runtimeExecutable"], str(self.h.bundle / "bin/studienbuch-project-runtime"))
        self.assertEqual(bound["parameters"], {"flavour": "development"})
        self.assertEqual(bound["endpoints"]["database"]["visibility"], "local")
        web = bound["endpoints"]["web"]["hostNames"]
        self.assertEqual(web["canonical"], f"studienbuch.{DOMAIN}")
        self.assertEqual(web["aliases"], ["legacy.example.test"])
        self.assertEqual(bound["endpoints"]["mobile"]["hostNames"]["instanceTemplate"], f"{{instance}}-mobile.{DOMAIN}")

    def test_unbound_required_secret_and_private_publication_fail(self):
        self.h.catalog["projects"]["studienbuch"]["policy"]["secrets"] = {}
        with self.assertRaisesRegex(ProjectError, "does not bind required Development Secrets: better-auth"):
            self.h.controller.up(cwd=self.h.worktree)
        value = descriptor()
        value["development"]["endpoints"]["web"]["publication"] = "private"
        write_bundle(self.h.bundle, value)
        harness = Harness(value=value)
        self.addCleanup(harness.close)
        harness.catalog["projects"]["studienbuch"]["policy"]["endpoints"]["web"]["visibility"] = "tailnet"
        with self.assertRaisesRegex(ProjectError, "private and cannot be published"):
            harness.controller.up(cwd=harness.worktree)

    def test_bundles_from_an_older_host_ask_for_a_refresh(self):
        (self.h.bundle / "share/project/bundle.json").write_text(json.dumps({"schemaVersion": 1}))
        with self.assertRaisesRegex(ProjectError, "bundle refresh"):
            self.h.controller.up(cwd=self.h.worktree)


class InstanceTest(ControllerTestCase):
    def test_dormant_instance_keeps_stable_routes_and_paired_ports(self):
        instance = self.h.controller.up(cwd=self.h.worktree, only="web")
        self.assertEqual((instance["id"], instance["instanceKey"]), ("abc123", "auth-redesign"))
        ports = {port for pair in instance["ports"].values() for port in pair.values()}
        self.assertEqual(len(ports), 6)
        self.assertEqual(instance["endpointLifecycle"]["web"]["phase"], "dormant")
        before = self.h.routes()
        self.h.controller.down(cwd=self.h.worktree, only="web")
        self.assertEqual(self.h.routes(), before)
        route = next(item for item in before if item["hostName"] == f"auth-redesign.{DOMAIN}")
        self.assertEqual(route["upstreamPort"], instance["ports"]["web"]["frontend"])

    def test_only_http_endpoints_of_active_instances_are_routed(self):
        self.h.controller.up(cwd=self.h.worktree, only="web")
        self.assertEqual(
            {route["hostName"] for route in self.h.routes()},
            {f"auth-redesign.{DOMAIN}", f"auth-redesign-mobile.{DOMAIN}"},
        )

    def test_instance_keys_avoid_existing_and_canonical_hostnames(self):
        collision = self.h.root / "worktrees/auth-copy"
        collision.mkdir()
        self.h.discovery.checkouts[collision.resolve()] = Checkout("studienbuch", collision, False, "auth-redesign", "x")
        self.h.discovery.checkouts[self.h.other.resolve()] = Checkout("studienbuch", self.h.other, False, "studienbuch", "y")
        self.assertEqual(self.h.controller.up(cwd=self.h.worktree, only="web")["instanceKey"], "auth-redesign")
        self.assertEqual(self.h.controller.up(cwd=collision, only="web")["instanceKey"], "auth-redesign-2")
        self.assertEqual(self.h.controller.up(cwd=self.h.other, only="web")["instanceKey"], "studienbuch-2")
        hostnames = [route["hostName"] for route in self.h.routes()]
        self.assertEqual(len(hostnames), len(set(hostnames)))

    def test_manifest_exposes_backend_listener_and_protocol_without_secrets(self):
        instance = self.h.controller.up(cwd=self.h.worktree, only="mobile")
        manifest = json.loads((self.h.root / "runtime/studienbuch/instances/auth-redesign/runtime.json").read_text())
        self.assertEqual(manifest["schemaVersion"], 3)
        self.assertEqual(manifest["instanceId"], instance["id"])
        self.assertEqual(manifest["endpoints"]["mobile"]["listen"]["port"], instance["ports"]["mobile"]["backend"])
        self.assertEqual(manifest["endpoints"]["database"], {
            "protocol": "tcp", "listen": {"host": "127.0.0.1", "port": instance["ports"]["database"]["backend"]},
        })
        self.assertEqual(manifest["secrets"], {"better-auth": "better-auth"})
        self.assertNotIn("TOP-SECRET-VALUE", json.dumps(self.h.registry()) + json.dumps(manifest))

    def test_retirement_preserves_ownership_and_can_resume_the_same_data(self):
        original = self.h.controller.up(cwd=self.h.worktree, only="web")
        marker = self.h.root / "state/studienbuch/instances/auth-redesign/keep"
        marker.write_text("durable")
        self.assertEqual(self.h.controller.retire(cwd=self.h.worktree)["desiredState"], "retired")
        self.h.controller.reconcile()
        self.assertEqual(self.h.routes(), [])
        self.assertEqual(self.h.services.active, set())
        resumed = self.h.controller.up(cwd=self.h.worktree, only="web")
        self.assertEqual((resumed["id"], resumed["ports"]), (original["id"], original["ports"]))
        self.assertEqual(marker.read_text(), "durable")

    def test_missing_workspace_is_suspended_then_retired_with_its_identity(self):
        original = self.h.controller.up(cwd=self.h.worktree, only="web")
        self.h.worktree.rmdir()
        self.h.controller.reconcile()
        self.assertTrue(self.h.routes())
        self.h.clock.value += 11
        self.assertEqual(self.h.controller.reconcile(), ["suspended auth-redesign"])
        self.assertEqual(self.h.routes(), [])
        self.h.clock.value += 90
        self.h.controller.reconcile()
        retained = self.h.registry()["instances"][original["identity"]]
        self.assertEqual((retained["desiredState"], retained["id"]), ("retired", original["id"]))

    def test_paused_instances_stay_down_and_resume_background_work(self):
        value = descriptor()
        value["development"]["workloads"]["importer"] = {
            "action": "importer", "kind": "service", "dependsOn": ["database"], "secrets": [], "lifecycle": "background",
        }
        write_bundle(self.h.bundle, value)
        instance = self.h.controller.up(cwd=self.h.worktree, only="web")
        manager = self.h.controller._unit_names(instance).manager
        self.assertIn([manager], self.h.services.starts)
        self.h.controller.down(cwd=self.h.worktree)
        self.h.controller.reconcile()
        self.assertEqual(self.h.services.active, set())
        with self.assertRaisesRegex(ProjectError, "paused"):
            self.h.controller.endpoint_activate(instance["identity"], "web")
        self.h.controller.up(cwd=self.h.worktree, only="web")
        self.assertIn(manager, self.h.services.active)

    def test_relocate_preserves_instance_identity_data_and_ports(self):
        original = self.h.controller.up(cwd=self.h.worktree, only="web")
        paths = self.h.controller._paths(original)
        moved = self.h.controller.relocate(original["id"], self.h.other)
        self.assertEqual(moved["desiredState"], "paused")
        self.h.controller.reconcile()
        resumed = self.h.controller.up(cwd=self.h.other, only="web")
        for field in ("identity", "id", "ports", "instanceKey"):
            self.assertEqual(resumed[field], original[field])
        self.assertEqual((self.h.controller._paths(resumed), resumed["checkout"]), (paths, str(self.h.other)))
        self.assertEqual(len(self.h.registry()["instances"]), 1)

    def test_secret_changes_replace_units_but_rematerialized_copies_do_not(self):
        self.h.controller.up(cwd=self.h.worktree, only="web")
        replacement = self.h.secret.with_suffix(".new")
        replacement.write_bytes(self.h.secret.read_bytes())
        replacement.replace(self.h.secret)
        self.h.services.removes.clear()
        self.h.controller.reconcile()
        self.assertEqual(self.h.services.removes, [])
        self.h.secret.write_text("NEW-SECRET-VALUE")
        self.h.controller.reconcile()
        self.assertEqual(len(self.h.services.removes), 1)

    def test_policy_changes_rebind_without_a_bundle_refresh(self):
        self.h.controller.up(cwd=self.h.worktree, only="web")
        self.h.catalog["projects"]["studienbuch"]["policy"]["parameters"] = {"flavour": "changed"}
        harness_controller = Controller(
            self.h.catalog, discovery=self.h.discovery, services=self.h.services,
            readiness=self.h.readiness, now=self.h.clock,
        )
        harness_controller.bundles.retain = mock.Mock()
        harness_controller.reconcile()
        instance = next(iter(self.h.registry()["instances"].values()))
        self.assertEqual(instance["development"]["parameters"], {"flavour": "changed"})


class CanonicalTest(ControllerTestCase):
    canonical = True

    def test_reconcile_installs_sockets_without_warming_or_background_work(self):
        self.h.controller.reconcile()
        instance = next(iter(self.h.registry()["instances"].values()))
        self.assertTrue(instance["canonical"])
        self.assertEqual(instance["desiredState"], "idle")
        self.assertEqual(self.h.services.warms, [])
        self.assertEqual(
            {route["hostName"] for route in self.h.routes()},
            {f"studienbuch.{DOMAIN}", f"studienbuch-mobile.{DOMAIN}", "legacy.example.test"},
        )
        self.h.controller.endpoint_activate(instance["identity"], "web")
        self.assertEqual(self.h.registry()["instances"][instance["identity"]]["desiredState"], "active")

    def test_bundle_refresh_is_explicit(self):
        refreshed = write_bundle(self.h.root / "refreshed", descriptor())
        build = mock.Mock(return_value={"kind": "checkout", "bundlePath": str(refreshed), "sourceDigest": "a" * 64})
        self.h.controller.bundles.build = build
        self.h.controller.reconcile()
        self.h.controller.up(cwd=self.h.checkout, only="web")
        self.assertEqual(build.call_count, 0)
        self.h.controller.refresh_bundle(cwd=self.h.checkout)
        self.assertEqual(build.call_count, 1)
        self.h.controller.reconcile()
        status = self.h.controller.bundle_status(cwd=self.h.checkout)
        self.assertEqual((status["kind"], status["available"]), ("checkout", True))
        self.assertEqual(build.call_count, 1)
        self.h.controller.reset_bundle(cwd=self.h.checkout)
        self.assertEqual(self.h.controller.bundle_status(cwd=self.h.checkout)["provenance"]["bundlePath"], str(self.h.bundle))


class EndpointTest(ControllerTestCase):
    def test_protocol_specific_readiness_and_lifecycle(self):
        instance = self.h.controller.up(cwd=self.h.worktree, only="web")
        identity = instance["identity"]
        route_file = pathlib.Path(self.h.catalog["routeSourceFile"])
        inode = route_file.stat().st_ino
        self.h.controller.endpoint_activate(identity, "web")
        self.h.controller.endpoint_activate(identity, "database")
        self.assertEqual([call[0] for call in self.h.readiness.calls], ["http", "tcp"])
        self.assertEqual(self.h.readiness.calls[0][2]["paths"], ["/health", "/assets/app.css"])
        self.assertEqual(self.h.readiness.calls[1][1], instance["ports"]["database"]["backend"])
        self.assertEqual(self.h.registry()["instances"][identity]["endpointLifecycle"]["web"]["phase"], "ready")
        self.h.controller.endpoint_finished(identity, "web")
        self.assertEqual(route_file.stat().st_ino, inode)
        self.assertEqual(self.h.registry()["instances"][identity]["endpointLifecycle"]["web"]["phase"], "dormant")

    def test_failure_is_diagnostic_and_retry_succeeds(self):
        instance = self.h.controller.up(cwd=self.h.worktree, only="mobile")
        identity = instance["identity"]
        routes = self.h.routes()
        self.h.readiness.failures.add(instance["ports"]["mobile"]["backend"])
        with self.assertRaisesRegex(ProjectError, "not ready"):
            self.h.controller.endpoint_activate(identity, "mobile")
        lifecycle = self.h.registry()["instances"][identity]["endpointLifecycle"]["mobile"]
        self.assertEqual(lifecycle["phase"], "failed")
        self.assertIn("http not ready", lifecycle["lastFailure"]["message"])
        self.assertEqual(self.h.routes(), routes)
        self.h.readiness.failures.clear()
        self.assertEqual(self.h.controller.endpoint_activate(identity, "mobile")["phase"], "ready")

    def test_stopping_one_endpoint_keeps_the_shared_manager(self):
        instance = self.h.controller.up(cwd=self.h.worktree)
        names = self.h.controller._unit_names(instance)
        self.h.controller.down(cwd=self.h.worktree, only="web")
        self.assertEqual(self.h.services.stops, [names.endpoints["web"].service])

    def test_endpoints_are_single_flight_individually_but_concurrent_together(self):
        class Measured(FakeReadiness):
            def __init__(self):
                super().__init__()
                self.lock, self.current, self.maximum = threading.Lock(), 0, 0

            def wait(self, protocol, port, health):
                with self.lock:
                    self.current += 1
                    self.maximum = max(self.maximum, self.current)
                time.sleep(0.08)
                with self.lock:
                    self.current -= 1

        readiness = Measured()
        h = Harness(readiness=readiness)
        self.addCleanup(h.close)
        first = h.controller.up(cwd=h.worktree, only="mobile")
        second = h.controller.up(cwd=h.other, only="mobile")

        def concurrently(calls):
            readiness.maximum = 0
            with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
                for future in [executor.submit(h.controller.endpoint_activate, *call) for call in calls]:
                    future.result()
            return readiness.maximum

        self.assertEqual(concurrently([(first["identity"], "mobile")] * 2), 1)
        self.assertEqual(concurrently([(first["identity"], "mobile"), (first["identity"], "web")]), 2)
        self.assertEqual(concurrently([(first["identity"], "mobile"), (second["identity"], "mobile")]), 2)


class CommandTest(ControllerTestCase):
    def test_console_scope_retains_the_manager_and_literal_arguments(self):
        with (
            mock.patch.object(controller_module.os, "chdir"),
            mock.patch.object(controller_module.os, "execvpe", side_effect=RuntimeError("exec")) as execute,
            self.assertRaisesRegex(RuntimeError, "exec"),
        ):
            self.h.controller.run_command(cwd=self.h.worktree, command_name="console", arguments=["--label", "$literal"])
        argv = execute.call_args.args[1]
        self.assertIn("--expand-environment=no", argv)
        self.assertTrue(any(arg.startswith("--property=Requires=project-dev-") for arg in argv))
        self.assertEqual(argv[-4:], ["command", "console", "--label", "$literal"])
        secret = self.h.root / "runtime/studienbuch/instances/auth-redesign/secrets/better-auth"
        self.assertEqual(secret.readlink(), self.h.secret)

    def test_commands_reuse_a_current_instance_without_discovery(self):
        with (
            mock.patch.object(self.h.discovery, "resolve", wraps=self.h.discovery.resolve) as resolve,
            mock.patch.object(controller_module.os, "chdir"),
            mock.patch.object(controller_module.os, "execvpe") as execute,
        ):
            for argument in ("--help", "--version"):
                self.h.controller.run_command(cwd=self.h.worktree, command_name="console", arguments=[argument])
        self.assertEqual((len(self.h.services.installs), resolve.call_count, execute.call_count), (1, 1, 2))


class ResourceTest(ControllerTestCase):
    def test_resources_are_distinct_and_retained_across_the_lifecycle(self):
        self.with_requirements()
        first = self.h.controller.up(cwd=self.h.worktree)
        second = self.h.controller.up(cwd=self.h.other)
        one, two = first["resourceBindings"], second["resourceBindings"]
        self.assertNotEqual(one["database"]["port"], two["database"]["port"])
        self.assertNotEqual(one["database"]["dataDirectory"], two["database"]["dataDirectory"])
        secret_path = pathlib.Path(first["resourceSecrets"]["session-key"]["path"])
        secret = secret_path.read_text()
        self.assertNotEqual(secret, pathlib.Path(second["resourceSecrets"]["session-key"]["path"]).read_text())
        self.assertNotIn(secret.strip(), json.dumps(self.h.controller._manifest(first)))
        self.h.controller.down(cwd=self.h.worktree)
        resumed = self.h.controller.up(cwd=self.h.worktree)
        self.assertEqual(resumed["resourceBindings"], one)
        # A generated secret stays generated rather than turning into a host binding.
        self.assertEqual(resumed["resourceSecrets"], first["resourceSecrets"])
        self.assertIn("session-key", self.h.controller._manifest(resumed)["secrets"])
        self.h.controller.retire(cwd=self.h.worktree)
        self.assertEqual(secret, secret_path.read_text())

    def test_unbound_account_and_retained_other_postgres_fail_before_materialization(self):
        value = self.with_requirements()
        value["requirements"]["account"] = {
            "kind": "secret", "description": "", "required": True, "realizations": ["development"], "generate": None,
        }
        write_bundle(self.h.bundle, value)
        with self.assertRaisesRegex(ProjectError, "account.*authorized binding"):
            self.h.controller.up(cwd=self.h.worktree)
        self.assertFalse(pathlib.Path(self.h.catalog["stateRoot"]).exists())
        self.assertEqual(self.h.services.installs, [])

    def test_workspace_ports_are_private_and_retirement_keeps_the_other_workspace(self):
        value = self.with_requirements()
        value["development"]["endpoints"]["web"]["port"] = 3000
        del value["development"]["endpoints"]["database"]
        write_bundle(self.h.bundle, value)
        self.h.catalog["workspaceLauncher"] = "/workspace-launcher"

        def inspect(argv, *, cwd):
            return json.dumps({"id": cwd.name, "root": str(cwd), "visibleRoot": "/home/user/app"})

        with mock.patch.object(self.h.controller.runner, "output", side_effect=inspect), mock.patch.object(
            self.h.controller.runner, "run"
        ):
            first = self.h.controller.up(cwd=self.h.worktree)
            second = self.h.controller.up(cwd=self.h.other)
            self.assertEqual((first["internalPorts"]["web"], second["internalPorts"]["web"]), (3000, 3000))
            self.assertEqual(first["resourceBindings"]["database"]["port"], 5432)
            self.assertNotEqual(first["ports"], second["ports"])
            manifest = self.h.controller._manifest(first)
            self.assertEqual(manifest["paths"]["checkout"], "/home/user/app")
            self.assertEqual(manifest["endpoints"]["web"]["listen"], {"host": "0.0.0.0", "port": 3000})
            named = self.h.controller.up(cwd=self.h.worktree, name="other-instance")
            self.assertNotEqual(named["internalPorts"]["web"], 3000)
            self.h.controller.retire_workspace(self.h.worktree)
            self.assertEqual(self.h.controller.status(cwd=self.h.worktree)["desiredState"], "retired")
            self.assertEqual(self.h.controller.status(cwd=self.h.other)["desiredState"], "active")

    def test_plan_creates_no_state(self):
        value = self.with_requirements()
        before = sorted(self.h.root.rglob("*"))
        with mock.patch.object(self.h.controller, "inspect", return_value={"contract": value, "checkout": str(self.h.worktree)}):
            plan = self.h.controller.plan(self.h.worktree)
        self.assertTrue(plan["ready"], plan["errors"])
        self.assertIsNone(plan["instanceId"])
        self.assertEqual(plan["resources"]["database"]["source"], "native-process")
        self.assertEqual(before, sorted(self.h.root.rglob("*")))


class StatusTest(ControllerTestCase):
    def test_human_status_urls_and_logs(self):
        self.h.controller.up(cwd=self.h.worktree, only="web")
        status = self.h.controller.status(cwd=self.h.worktree)
        self.assertTrue(status["endpoints"]["web"]["socketActive"])
        output = io.StringIO()
        with mock.patch("sys.stdout", output):
            cli.print_status(status)
            cli.print_urls(self.h.controller.urls(cwd=self.h.worktree))
        self.assertIn("Bundle: pinned", output.getvalue())
        self.assertIn(f"https://auth-redesign.{DOMAIN}", output.getvalue())
        self.assertEqual(set(self.h.controller.urls(cwd=self.h.worktree, only="web")), {"web"})
        self.h.controller.logs(cwd=self.h.worktree, only="web")
        units, pattern = self.h.services.log_units[-1]
        self.assertTrue(units[0].endswith("-devenv.service"))
        self.assertEqual(pattern, r"^\[(web)\]")


class SnapshotTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        self.checkout = self.root / "checkout"
        self.checkout.mkdir()
        self.runner = mock.Mock()
        self.builder = BundleBuilder("/builder", self.runner, lambda: 1.0, lambda _message: None)

    def listing(self, *outputs):
        self.runner.run.side_effect = [subprocess.CompletedProcess([], 0, output, "") for output in outputs]

    def test_contains_only_tracked_working_copy_files(self):
        (self.checkout / ".jj").mkdir()
        source = self.checkout / "src/run.sh"
        source.parent.mkdir()
        source.write_text("echo first\n")
        source.chmod(0o755)
        (self.checkout / "node_modules").mkdir()
        (self.checkout / "node_modules/large.bin").write_bytes(b"ignored")
        self.listing("src/run.sh\0", "src/run.sh\0")
        first = self.builder.snapshot(self.checkout, self.root / "snapshots")
        self.assertFalse((first.path / "node_modules").exists())
        self.assertEqual((first.path / "src/run.sh").stat().st_mode & 0o777, 0o755)
        source.write_text("echo second\n")
        second = self.builder.snapshot(self.checkout, self.root / "snapshots")
        self.assertNotEqual(first.digest, second.digest)
        self.assertEqual(second.vcs, "jj")

    def test_preserves_gitlinks_without_submodule_contents(self):
        (self.checkout / "vendor").mkdir()
        (self.checkout / "vendor/local.txt").write_text("not source")
        digests = []
        for revision in ("a" * 40, "b" * 40):
            self.listing("vendor\0", f"160000 {revision} 0\tvendor\0")
            result = self.builder.snapshot(self.checkout, self.root / "snapshots")
            self.assertEqual(list((result.path / "vendor").iterdir()), [])
            digests.append(result.digest)
        self.assertNotEqual(*digests)

    def test_rejects_plain_directories_and_escaping_symlinks(self):
        (self.checkout / "vendor").mkdir()
        self.listing("vendor\0", "100644 abc 0\tvendor/file\0")
        with self.assertRaisesRegex(ProjectError, "neither a file nor a symlink"):
            self.builder.snapshot(self.checkout, self.root / "snapshots")
        (self.checkout / "outside").symlink_to("../../outside")
        self.listing("outside\0")
        with self.assertRaisesRegex(ProjectError, "symlink escapes"):
            self.builder.snapshot(self.checkout, self.root / "snapshots")

    def test_builds_are_cached_by_tracked_source(self):
        bundle = self.root / "bundle"
        bundle.mkdir()
        (self.checkout / "file").write_text("x")
        link = self.root / "build-link"
        self.runner.run.side_effect = lambda argv, **kwargs: subprocess.CompletedProcess(
            argv, 0, "file\0" if argv[0] == "git" else f"{bundle}\n", ""
        )
        first = self.builder.build("app", self.checkout, self.root / "bundles", link)
        second = self.builder.build("app", self.checkout, self.root / "bundles", link)
        builds = [call for call in self.runner.run.call_args_list if call.args[0][0] == "/builder"]
        self.assertEqual(len(builds), 1)
        self.assertEqual(builds[0].args[0][2:], [str(link)])
        self.assertEqual((first["cacheHit"], second["cacheHit"]), (False, True))


class DiscoveryTest(unittest.TestCase):
    def test_registered_forks_match_their_source_without_git_remotes(self):
        projects = {"app": {"repository": {"checkout": "/code/app", "url": "example/app"}}}
        for source, expected in [("/code/app", True), ("/code/unrelated", False)]:
            with self.subTest(source=source):
                records = {
                    "/workspaces/second/nested": {"root": "/workspaces/second", "sourceRoot": "/workspaces/first"},
                    "/workspaces/first/nested": {"root": "/workspaces/first/nested", "sourceRoot": source},
                }
                runner = mock.Mock()
                runner.output.side_effect = lambda argv, cwd: json.dumps(records.get(argv[-1])) if argv[0] == "/launcher" else None
                discovery = CheckoutDiscovery(projects, runner, workspace_launcher="/launcher")
                root = pathlib.Path("/workspaces/second/nested")
                with mock.patch.object(discovery, "root", return_value=root):
                    if expected:
                        self.assertEqual(discovery.resolve(root, "app"), Checkout("app", root, False, "nested", None))
                    else:
                        with self.assertRaises(ProjectError):
                            discovery.resolve(root, "app")


class SystemdUnitTest(unittest.TestCase):
    class RecordingRunner:
        def __init__(self, stdout=""):
            self.calls, self.stdout = [], stdout

        def run(self, argv, **kwargs):
            self.calls.append((list(argv), kwargs))
            return subprocess.CompletedProcess(argv, 0, self.stdout, "")

    def test_one_manager_with_socket_activated_proxies_and_scoped_credentials(self):
        h = Harness()
        self.addCleanup(h.close)
        instance = h.controller.up(cwd=h.worktree)
        names = h.controller._unit_names(instance)
        services = SystemdUserServices(h.catalog, self.RecordingRunner())
        services.install(instance, h.controller._development(instance), names)
        root = services.unit_root
        self.assertEqual(sorted(path.name for path in root.iterdir()), names.all())
        manager = (root / names.manager).read_text()
        self.assertIn("internal run-manager", manager)
        self.assertIn("StopWhenUnneeded=yes", manager)
        self.assertIn(f"LoadCredential=better-auth:{h.secret}", manager)
        proxy = (root / names.endpoints["web"].service).read_text()
        self.assertIn('systemd-socket-proxyd" --connections-max=1024 --exit-idle-time=1800s', proxy)
        self.assertIn(f"BindsTo={names.manager}", proxy)
        self.assertIn("FlushPending=yes", (root / names.endpoints["web"].socket).read_text())
        self.assertNotIn("TOP-SECRET-VALUE", "\n".join(path.read_text() for path in root.iterdir()))

    def test_warm_starts_everything_in_one_transaction_unless_active(self):
        with tempfile.TemporaryDirectory() as value:
            catalog = {"systemdUnitRoot": value}
            runner = self.RecordingRunner()
            services = SystemdUserServices(catalog, runner)
            units = ["a.service", "b.service"]
            services.warm(units)
            self.assertEqual(
                [call[0][len(services.systemctl):] for call in runner.calls],
                [["--user", "is-active", *units], ["--user", "reset-failed", *units], ["--user", "start", *units]],
            )
            active = self.RecordingRunner("active\nactive\n")
            SystemdUserServices(catalog, active).warm(units)
            self.assertEqual(len(active.calls), 1)


class CliTest(unittest.TestCase):
    def test_registry_rejects_unknown_schema(self):
        with tempfile.TemporaryDirectory() as value:
            root = pathlib.Path(value)
            store = RegistryStore(root / "registry.json", root / "routes.json")
            with store.locked() as registry:
                self.assertEqual(registry, {"schemaVersion": 3, "instances": {}})
            (root / "registry.json").write_text('{"schemaVersion": 2, "instances": {}}')
            with self.assertRaisesRegex(ProjectError, "registry schema"), store.locked():
                pass

    def test_helpers_are_stable(self):
        self.assertEqual(normalized_repository_url("git@example.test:Team/App.git"), "example.test/Team/App")
        self.assertEqual(slugify("Feature / Über cool"), "feature-ber-cool")

    def test_command_invocation_keeps_repository_arguments_opaque(self):
        self.assertEqual(
            cli.command_invocation(["-p", "app", "prod", "console", "--help"]),
            cli.CommandInvocation("prod", "app", None, "console", ["--help"]),
        )
        self.assertEqual(cli.command_invocation(["dev", "--project", "app", "seed", "-x"]).project, "app")
        self.assertIsNone(cli.command_invocation(["dev", "up", "--only", "web"]))
        self.assertIsNone(cli.command_invocation(["prod", "--help"]))

    def test_project_is_accepted_before_or_after_the_verb(self):
        parser = cli.parser()
        self.assertEqual(parser.parse_args(["-p", "app", "dev", "status"]).project, "app")
        self.assertEqual(parser.parse_args(["dev", "status", "--project", "app"]).verb_project, "app")
        with self.assertRaises(SystemExit), mock.patch("sys.stderr", io.StringIO()):
            parser.parse_args(["dev", "up", "--public"])


if __name__ == "__main__":
    unittest.main()
