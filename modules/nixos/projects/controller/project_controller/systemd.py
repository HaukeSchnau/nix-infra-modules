"""The request-activated user-systemd units of Development instances."""

from __future__ import annotations

import contextlib
import os
import pathlib
from collections.abc import Sequence

from .model import Catalog, Development, Instance
from .units import UnitNames
from .util import ProjectError, Runner, command_from_environment, write_file


def _quote(value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace('"', '\\"').replace("%", "%%")
    return f'"{escaped}"'


def _credentials(development: Development) -> list[str]:
    result: list[str] = []
    for name, secret in sorted(development["secrets"].items()):
        if not pathlib.Path(secret["path"]).is_absolute():
            raise ProjectError(f"Secret {name} must use an absolute path")
        result.append(f"LoadCredential={name}:{secret['path']}")
    return result


class SystemdUserServices:
    """One devenv manager per instance, plus a socket and proxy per endpoint.

    The socket accepts the first request; the proxy asks the controller to
    activate the endpoint, then forwards to the process until it is idle.
    """

    def __init__(self, catalog: Catalog, runner: Runner):
        self.catalog = catalog
        self.runner = runner
        self.systemctl = command_from_environment("PROJECT_DEVELOPMENT_SYSTEMCTL", "systemctl")
        self.journalctl = command_from_environment("PROJECT_DEVELOPMENT_JOURNALCTL", "journalctl")
        self.unit_root = pathlib.Path(catalog["systemdUnitRoot"])

    def _systemctl(self, *arguments: str, check: bool = True, capture: bool = False):
        return self.runner.run([*self.systemctl, "--user", *arguments], check=check, capture=capture)

    def is_active(self, unit: str) -> bool:
        return self._systemctl("is-active", "--quiet", unit, check=False).returncode == 0

    def _write(self, unit: str, lines: Sequence[str]) -> bool:
        self.unit_root.mkdir(parents=True, exist_ok=True, mode=0o700)
        return write_file(self.unit_root / unit, "\n".join(lines))

    def install(self, instance: Instance, development: Development, names: UnitNames) -> None:
        controller = _quote(self.catalog["controllerExecutable"])
        identity = _quote(instance["identity"])
        common = [
            "[Service]",
            "UMask=0077",
            f"Environment=PROJECT_DEVELOPMENT_CATALOG={_quote(self.catalog['catalogFile'])}",
        ]
        preparation_timeout = development["preparation"].get("timeoutSec", 900)
        background = any(
            workload["lifecycle"] == "background" for workload in development["workloads"].values()
        )
        execution = instance.get("execution")
        changed = self._write(
            names.manager,
            [
                "[Unit]",
                f"Description=Project Development {instance['instanceKey']} devenv manager",
                *([] if background else ["StopWhenUnneeded=yes"]),
                "",
                *common,
                "Type=notify",
                "NotifyAccess=all",
                "KillMode=mixed",
                *([f"Slice=agent-env-{execution['id']}.slice"] if execution else []),
                "SuccessExitStatus=130 143",
                f"TimeoutStartSec={preparation_timeout + 30}",
                f"ExecStart={controller} internal run-manager --identity {identity}",
                "Restart=on-failure",
                "RestartSec=3s",
                "TimeoutStopSec=30s",
                *_credentials(development),
                "",
            ],
        )
        for name, endpoint in sorted(development["endpoints"].items()):
            units = names.endpoints[name]
            ports = instance["ports"][name]
            timeout = preparation_timeout + endpoint["health"]["startupTimeoutSec"] + 30
            changed |= self._write(
                units.socket,
                [
                    "[Unit]",
                    f"Description=Project Development {instance['instanceKey']} Endpoint {name}",
                    "",
                    "[Socket]",
                    f"ListenStream=127.0.0.1:{ports['frontend']}",
                    "Accept=no",
                    "FlushPending=yes",
                    "NoDelay=yes",
                    f"Service={units.service}",
                    "",
                ],
            )
            changed |= self._write(
                units.service,
                [
                    "[Unit]",
                    f"Description=Activate Project Development {instance['instanceKey']} Endpoint {name}",
                    f"Requires={units.socket}",
                    f"After={units.socket} {names.manager}",
                    f"BindsTo={names.manager}",
                    "StartLimitIntervalSec=2min",
                    "StartLimitBurst=10",
                    "",
                    *common,
                    "Type=exec",
                    f"TimeoutStartSec={timeout}",
                    f"ExecStartPre={controller} internal endpoint-activate --identity {identity} --endpoint {_quote(name)}",
                    f"ExecStart={_quote(self.catalog['socketProxyExecutable'])} --connections-max=1024 --exit-idle-time={development['idleTimeoutSec']}s 127.0.0.1:{ports['backend']}",
                    f"ExecStopPost={controller} internal endpoint-finished --identity {identity} --endpoint {_quote(name)}",
                    "TimeoutStopSec=30s",
                    "",
                ],
            )
        if changed:
            self._systemctl("daemon-reload")

    def start(self, units: Sequence[str]) -> None:
        """Starts units in one transaction; a failure concerns only this instance."""
        if not units:
            return
        # Units that never ran are not loaded; that is not worth reporting.
        self._systemctl("reset-failed", *units, check=False, capture=True)
        if self._systemctl("start", *units, check=False).returncode != 0:
            raise ProjectError(f"Could not start {', '.join(units)}; see `project dev logs`")

    def warm(self, units: Sequence[str]) -> None:
        if not units:
            return
        state = self._systemctl("is-active", *units, check=False, capture=True)
        if state.stdout.splitlines() == ["active"] * len(units):
            return
        # One transaction lets systemd start independent endpoints in parallel.
        self.start(units)

    def stop(self, unit: str) -> None:
        self._systemctl("stop", unit, check=False)

    def remove(self, units: Sequence[str]) -> None:
        if units:
            stopped = self._systemctl("stop", *units, check=False, capture=True)
            if stopped.returncode != 0:
                remaining = [unit for unit in units if self.is_active(unit)]
                if remaining:
                    raise ProjectError("Could not stop Development units: " + ", ".join(remaining))
        changed = False
        for unit in units:
            with contextlib.suppress(FileNotFoundError):
                (self.unit_root / unit).unlink()
                changed = True
        if changed:
            self._systemctl("daemon-reload")

    def logs(self, units: Sequence[str], pattern: str | None = None) -> None:
        if not units:
            raise ProjectError("This Development instance has no workloads")
        # User-unit messages can live in the system journal, so match their
        # identity instead of limiting journalctl to user scope.
        args = [*self.journalctl, "--no-pager", "--lines=100", f"_UID={os.getuid()}"]
        if pattern is not None:
            args.append(f"--grep={pattern}")
        args.extend(f"_SYSTEMD_USER_UNIT={unit}" for unit in dict.fromkeys(units))
        # grep finds nothing on a quiet process; that is not an error.
        self.runner.run(args, check=pattern is None)
