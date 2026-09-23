#!/usr/bin/env python3
"""Run a prepared devenv graph and bind Project demand to its native manager.

Each prepared bundle runs this file as its entrypoint:

    manager               the manager unit: run devenv's process scheduler
    control acquire|release TOKEN [WORKLOAD...]
                          add or drop demand for workloads (endpoint activation)
    command NAME [ARG...] run a declared task after its prerequisites

It is standalone (no package imports) because bundles embed it by path.
"""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import pathlib
import shlex
import signal
import socket
import subprocess
import sys
import threading
import time
import uuid
from collections.abc import Callable, Iterable, Mapping, Sequence
from typing import Any

# TODO: Replace `devenv daemon-processes` and its JSON socket protocol when
# devenv exposes a public prepared-manager command. The 2.3.1 standalone task
# runner has no API server. devenv.nix asserts the pinned CLI matches.
PROTOCOL_DEVENV_VERSION = "2.3.1"

# Match devenv 2.3.1 build_environment.rs: these belong to the caller, not to
# the derivation that captured the shell exports.
PROTECTED_VARIABLES = frozenset({
    "BASHOPTS", "HOME", "NIX_BUILD_TOP", "NIX_ENFORCE_PURITY", "NIX_LOG_FD", "NIX_REMOTE", "PPID",
    "SHELLOPTS", "SSL_CERT_FILE", "TERM", "TZ", "UID", "PWD", "OLDPWD", "TMPDIR", "TMP", "TEMP",
    "TEMPDIR", "BASH_ENV", "SHELL", "out",
})
FINISHED_PHASES = frozenset({"not_started", "stopped", "exited", "gave_up"})


def read_json(path: str | pathlib.Path) -> Any:
    return json.loads(pathlib.Path(path).read_text())


def write_json(path: pathlib.Path, value: Any) -> None:
    temporary = path.with_suffix(".new")
    temporary.write_text(json.dumps(value))
    temporary.chmod(0o600)
    temporary.replace(path)


def wait_child(child: subprocess.Popen[Any], forward: Callable[[int], None] | None = None) -> int:
    """Waits for a child, forwarding SIGTERM and SIGINT to it."""
    previous = {
        signum: signal.signal(signum, lambda received, _frame: (forward or child.send_signal)(received))
        for signum in (signal.SIGTERM, signal.SIGINT)
    }
    try:
        status = child.wait()
        return status if status >= 0 else 128 - status
    finally:
        for signum, handler in previous.items():
            signal.signal(signum, handler)


def with_command_barriers(tasks: list[dict[str, Any]], commands: Mapping[str, str], runtime: pathlib.Path, capture: str) -> list[dict[str, Any]]:
    """Adds a barrier process per command so the native scheduler finishes its
    prerequisites and records their environment before the caller runs it."""
    by_name = {task["name"]: task for task in tasks}
    result = list(tasks)
    for name, task_name in commands.items():
        task = by_name[task_name]
        predecessors = [
            predecessor["name"] + ("@" + successor.split("@", 1)[1] if "@" in successor else "")
            for predecessor in by_name.values()
            for successor in predecessor.get("before", [])
            if successor.split("@")[0] == task_name
        ]
        capture_name = f"project:command-environment-{name}"
        result.append({
            "name": capture_name,
            "command": capture,
            "after": [*task.get("after", []), *predecessors],
            "env": {"PROJECT_COMMAND_ENVIRONMENT": str(runtime / f"command-{name}.json")},
        })
        result.append({
            "name": f"devenv:processes:project-command-{name}",
            "type": "process",
            "command": "exec sleep infinity",
            "after": [capture_name],
            "process": {"ready": {"exec": "true"}},
        })
    return result


class Graph:
    """The prepared task graph with `after` and `before` edges merged."""

    def __init__(self, tasks: Iterable[Mapping[str, Any]]):
        self.by_name = {task["name"]: task for task in tasks}
        self.dependencies: dict[str, list[str]] = {
            name: [dependency.split("@")[0] for dependency in task.get("after", [])]
            for name, task in self.by_name.items()
        }
        for name, task in self.by_name.items():
            for successor in task.get("before", []):
                self.dependencies[successor.split("@")[0]].append(name)

    def process_closure(self, roots: Iterable[str]) -> list[str]:
        """Processes the roots need, dependencies first; devenv schedules the tasks."""
        seen: set[str] = set()
        result: list[str] = []

        def visit(name: str) -> None:
            if name in seen:
                return
            seen.add(name)
            for dependency in self.dependencies[name]:
                visit(dependency)
            if self.by_name[name].get("type") == "process":
                result.append(name.removeprefix("devenv:processes:"))

        for root in roots:
            visit(root)
        return result


class NativeManager:
    """Client for the socket of `devenv daemon-processes`."""

    def __init__(self, runtime: pathlib.Path):
        self.socket = runtime / "native.sock"

    def request(self, command: str, **arguments: Any) -> dict[str, Any]:
        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(30)
            connection.connect(str(self.socket))
            connection.sendall((json.dumps({"command": command, **arguments}) + "\n").encode())
            response: dict[str, Any] = json.loads(connection.makefile().readline())
        if response.get("status") == "error":
            raise RuntimeError(response.get("message", "devenv reported an error"))
        if command == "start" and (response["outcome"]["unknown"] or response["outcome"]["failed"]):
            raise RuntimeError(f"devenv could not schedule processes: {response['outcome']}")
        return response

    def attach(self) -> Iterable[dict[str, Any]]:
        with socket.socket(socket.AF_UNIX) as connection:
            connection.connect(str(self.socket))
            connection.sendall(b'{"command":"attach"}\n')
            for line in connection.makefile():
                yield json.loads(line)


def demanded(demands: Mapping[str, Sequence[str]]) -> list[str]:
    return [root for roots in demands.values() for root in roots]


def activation_script(prepared: Mapping[str, Any], environ: Mapping[str, str]) -> list[str]:
    """Shell lines restoring the captured devenv environment for this caller."""
    lines: list[str] = []
    for name, variable in prepared["variables"].items():
        if name in PROTECTED_VARIABLES or name.startswith(("AGENT_EXEC_", "PROJECT_")):
            continue
        kind, value = variable["type"], variable.get("value")
        if kind in {"var", "exported"}:
            lines.append(f"{name}={shlex.quote(value)}")
            if kind == "exported":
                lines.append(f"export {name}")
        elif kind == "array":
            lines.append(f"declare -a {name}=({shlex.join(value)})")
        elif kind == "associative":
            items = " ".join(f"[{shlex.quote(key)}]={shlex.quote(item)}" for key, item in value.items())
            lines.append(f"declare -A {name}=({items})")
    for name, body in prepared.get("bashFunctions", {}).items():
        lines.append(f"{name} () {{\n{body}\n}}")
    for name in ("PATH", "XDG_DATA_DIRS"):
        # The caller's search paths stay reachable after devenv's.
        lines.append(f'export {name}="${{{name}:-}}":{shlex.quote(environ.get(name, ""))}')
    return lines


class Prepared:
    def __init__(self, config_file: str, inside: bool = False):
        self.config_file = config_file
        self.config = read_json(config_file)
        self.manifest = read_json(os.environ["PROJECT_RUNTIME_FILE"])
        self.paths = self.manifest["paths"]
        self.runtime = pathlib.Path("/tmp/devenv-runtime" if inside else self.paths["runtime"] + "/devenv")
        self.runtime.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.tasks = with_command_barriers(
            read_json(self.config["tasks"]), self.config["commands"], self.runtime, self.config["captureEnvironment"]
        )
        self.graph = Graph(self.tasks)
        self.native = NativeManager(self.runtime)

    def wait_manager(self, timeout: float = 900, child: subprocess.Popen[Any] | None = None) -> None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                self.native.request("list")
                return
            except (OSError, ValueError):
                if child is not None and child.poll() is not None:
                    raise RuntimeError(f"Prepared devenv manager exited with status {child.returncode}")
                time.sleep(0.1)
        raise RuntimeError("Prepared devenv manager did not become available")

    def demand(self, token: str, roots: list[str] | None = None) -> None:
        """Records (roots) or drops (None) a token's demand, starting and
        stopping processes so the running set matches all demand."""
        if roots is not None:
            self.wait_manager()
        elif not self.native.socket.exists():
            return
        with (self.runtime / "demand.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            path = self.runtime / "demand.json"
            demands = read_json(path) if path.exists() else {}
            previous = self.graph.process_closure(demanded(demands))
            if roots is None:
                demands.pop(token, None)
            else:
                demands[token] = roots
            needed = self.graph.process_closure(demanded(demands))
            if needed:
                self.native.request("start", names=needed)
            write_json(path, demands)
            for name in reversed(previous):
                if name not in needed:
                    self.stop_process(name)

    def stop_process(self, name: str) -> None:
        try:
            self.native.request("stop", name=name)
        except RuntimeError:
            # TODO: Remove deferred stops when the native API can cancel process
            # starts still waiting for prerequisites; collect_demand retries.
            return
        if name.startswith("project-command-"):
            (self.runtime / f"command-{name.removeprefix('project-command-')}.json").unlink(missing_ok=True)

    def wait_process(self, name: str, timeout: float = 900) -> None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            phase = self.native.request("status", name=name)["info"]["phase"]
            if phase == "ready":
                return
            if phase in {"stopped", "exited", "gave_up"}:
                raise RuntimeError(f"devenv process {name} failed before readiness: {phase}")
            time.sleep(0.1)
        raise RuntimeError(f"devenv process {name} did not become ready")

    def enter(self, action: str, arguments: Sequence[str] = ()) -> int:
        """Re-runs this program inside the prepared environment and mount namespace."""
        cache = pathlib.Path(self.paths["cache"]) / "devenv"
        (cache / "state").mkdir(mode=0o700, parents=True, exist_ok=True)
        rerun = [sys.executable, __file__, "--config", self.config_file]
        if os.environ.get("PROJECT_EXECUTION_FILE") and not os.environ.get("PROJECT_WORKSPACE_ENTERED"):
            # A workspace instance first joins its workspace namespaces.
            execution = read_json(os.environ["PROJECT_EXECUTION_FILE"])
            child = subprocess.Popen(
                [
                    os.environ["PROJECT_WORKSPACE_LAUNCHER"], "project-run", "--cwd", execution["checkout"],
                    "--file", os.environ["PROJECT_EXECUTION_FILE"], "--", *rerun, "--enter", action, *arguments,
                ],
                env={**os.environ, "PROJECT_EXECUTION_ACTION": action},
            )
            return wait_child(child)
        environment = {
            **os.environ,
            "XDG_CACHE_HOME": self.paths["cache"],
            "TMPDIR": "/tmp",
            "AGENT_EXEC_ACTIVATING": self.config["root"],
            "PROJECT_DEVENV_MANAGED": "1",
        }
        activation = activation_script(read_json(self.config["environment"]), os.environ)
        shell = (
            "set -e\n{\n" + "\n".join(activation) + '\neval "${shellHook:-}"\n} >&2\nexec '
            + shlex.join([*rerun, "--inside", action, *arguments])
        )
        if os.environ.get("PROJECT_WORKSPACE_ENTERED"):
            # agent-exec already joined the workspace namespaces and mounted the instance paths.
            command = [self.config["bash"], "-c", shell]
        else:
            command = [
                self.config["bwrap"], "--die-with-parent",
                # The manager's systemd cgroup owns its children. Keep host PIDs so
                # persistent database PID files stay valid after a crash.
                *([] if action == "manager" else ["--unshare-pid"]),
                "--bind", "/", "/", "--dev-bind", "/dev", "/dev", "--proc", "/proc", "--tmpfs", "/tmp",
                *(argument for path in self.paths.values() for argument in ("--bind", path, path)),
                "--ro-bind", os.environ["PROJECT_RUNTIME_FILE"], os.environ["PROJECT_RUNTIME_FILE"],
                "--bind", self.paths["checkout"], self.config["root"],
                "--bind", str(cache), self.config["root"] + "/.devenv",
                "--bind", str(self.runtime), "/tmp/devenv-runtime",
                "--chdir", self.paths["checkout"],
                "--", self.config["bash"], "-c", shell,
            ]
        child = subprocess.Popen(command, env=environment)

        def stop_manager(signum: int) -> None:
            # Let the native manager apply process-specific shutdown signals
            # before stopping the outer mount namespace and systemd unit.
            try:
                active = {
                    process["name"] for process in self.native.request("list")["processes"]
                    if process["phase"] not in FINISHED_PHASES
                }
                for name in reversed(self.graph.process_closure(self.graph.by_name)):
                    if name in active:
                        try:
                            self.native.request("stop", name=name)
                        except RuntimeError:
                            continue  # A restarting process may exit after the snapshot.
            except (OSError, RuntimeError):
                pass
            finally:
                child.send_signal(signum)

        return wait_child(child, stop_manager if action == "manager" else None)

    def task(self, name: str) -> None:
        subprocess.run(
            [
                self.config["runner"], "run", name, "--task-file", self.config["tasks"],
                "--cache-dir", os.environ["DEVENV_STATE"], "--runtime-dir", str(self.runtime / "preparation"),
                "--on-idle", "exit",
            ],
            check=True,
        )

    def forward_logs(self) -> None:
        """Copies process output to the manager's journal, prefixed with the process name."""
        try:
            for event in self.native.attach():
                if event.get("event") == "log":
                    print(f"[{event['name']}] {event['line']}", flush=True)
        except OSError:
            pass

    def collect_demand(self) -> None:
        """Drops demand of killed command callers and finishes deferred stops."""
        while True:
            time.sleep(1)
            try:
                for path in self.runtime.glob("command:*.lock"):
                    with path.open("a") as lock:
                        try:
                            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        except BlockingIOError:
                            continue
                        self.demand(path.stem)
                        path.unlink(missing_ok=True)
                with (self.runtime / "demand.lock").open("a") as lock:
                    fcntl.flock(lock, fcntl.LOCK_EX)
                    needed = self.graph.process_closure(demanded(read_json(self.runtime / "demand.json")))
                    for process in self.native.request("list")["processes"]:
                        if process["name"] not in needed and process["phase"] in {"ready", "starting"}:
                            self.stop_process(process["name"])
            except OSError:
                pass

    def manager(self) -> int:
        for path in self.runtime.glob("command-*.json"):
            path.unlink()
        self.task("project:capture-environment")
        environment = {
            name: value
            for name, value in read_json(self.runtime / "prepared-environment.json").items()
            if not name.startswith("DEVENV_TASK")
        }
        write_json(self.runtime / "prepared-environment.json", environment)
        # The attach API only carries process output; one-shot tasks log
        # through an inherited descriptor to the same journal.
        log_fd = os.dup(sys.stdout.fileno())
        environment["PROJECT_DEVENV_LOG_FD"] = str(log_fd)
        config_path = self.runtime / "manager.json"
        write_json(config_path, {
            "tasks": [*self.tasks, {"name": "project:prepared"}],
            "roots": ["project:prepared"],
            "run_mode": "before",
            "runtime_dir": str(self.runtime),
            "cache_dir": os.environ["DEVENV_STATE"],
            "env": environment,
            "bash": self.config["bash"],
            "exit_on_idle": False,
        })
        write_json(self.runtime / "demand.json", {})
        child = subprocess.Popen(
            [self.config["devenv"], "--no-tui", "daemon-processes", str(config_path)], pass_fds=(log_fd,)
        )
        os.close(log_fd)
        try:
            self.wait_manager(30, child)
            threading.Thread(target=self.forward_logs, daemon=True).start()
            threading.Thread(target=self.collect_demand, daemon=True).start()
            if self.config["background"]:
                self.demand("background", [self.config["workloads"][name] for name in self.config["background"]])
            if notify_socket := os.environ.get("NOTIFY_SOCKET"):
                with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as connection:
                    address = notify_socket.replace("@", "\0", 1) if notify_socket.startswith("@") else notify_socket
                    connection.sendto(b"READY=1", address)
            return wait_child(child)
        finally:
            if child.poll() is None:
                child.terminate()
                child.wait(timeout=30)

    def command(self, name: str, arguments: Sequence[str]) -> int:
        token = f"command:{uuid.uuid4().hex}"
        barrier = f"project-command-{name}"
        path = self.runtime / f"{token}.lock"
        # The held lock tells collect_demand this caller is still alive.
        with path.open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            self.demand(token, [f"devenv:processes:{barrier}"])
            try:
                self.wait_process(barrier)
                return self.enter("command", [name, *arguments])
            finally:
                self.demand(token)
                path.unlink(missing_ok=True)

    def execute_command(self, name: str, arguments: Sequence[str]) -> None:
        task = self.graph.by_name[self.config["commands"][name]]
        environment = {
            key: value
            for key, value in {**os.environ, **read_json(self.runtime / f"command-{name}.json")}.items()
            if not key.startswith("DEVENV_TASK") and key not in ("PROJECT_DEVENV_LOG_FD", "PROJECT_COMMAND_ENVIRONMENT")
        }
        environment.update(task.get("env", {}))
        if task.get("input") is not None:
            environment["DEVENV_TASK_INPUT"] = json.dumps(task["input"])
        if task.get("cwd"):
            os.chdir(task["cwd"])
        os.execve(task["command"], [task["command"], *arguments], environment)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    parser.add_argument("--inside", action="store_true")
    parser.add_argument("--enter", action="store_true")
    parser.add_argument("action", choices=["manager", "control", "command"])
    parser.add_argument("arguments", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    prepared = Prepared(args.config, args.inside)
    if args.enter:
        return prepared.enter(args.action, args.arguments)
    if args.action == "control":
        operation, token, *names = args.arguments
        roots = [prepared.config["workloads"][name] for name in names] if operation == "acquire" else None
        prepared.demand(token, roots)
        for root in roots or []:
            if prepared.graph.by_name[root].get("type") == "process":
                prepared.wait_process(root.removeprefix("devenv:processes:"))
        return 0
    if args.action == "command":
        name, *arguments = args.arguments
        if args.inside:
            prepared.execute_command(name, arguments)
        return prepared.command(name, arguments)
    if not args.inside:
        return prepared.enter(args.action)
    return prepared.manager()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"project devenv: {error}", file=sys.stderr)
        sys.exit(1)
