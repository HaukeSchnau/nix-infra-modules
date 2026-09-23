"""Polling an endpoint until it answers."""

from __future__ import annotations

import socket
import time
from collections.abc import Callable
from typing import Any

from .util import ProjectError, Runner, command_from_environment


class ProtocolReadiness:
    def __init__(self, runner: Runner, sleep: Callable[[float], None] = time.sleep):
        self.runner = runner
        self.sleep = sleep
        self.curl = command_from_environment("PROJECT_DEVELOPMENT_CURL", "curl")

    def _poll(self, probe: Callable[[], bool], health: dict[str, Any], target: str) -> None:
        deadline = time.monotonic() + health["startupTimeoutSec"]
        while not probe():
            if time.monotonic() >= deadline:
                raise ProjectError(f"Endpoint readiness timed out at {target}")
            self.sleep(health["intervalSec"])

    def wait(self, protocol: str, port: int, health: dict[str, Any]) -> None:
        """Waits until every health path answers (HTTP) or the port accepts (TCP)."""
        if protocol == "tcp":

            def connects() -> bool:
                try:
                    with socket.create_connection(("127.0.0.1", port), timeout=health["requestTimeoutSec"]):
                        return True
                except OSError:
                    return False

            self._poll(connects, health, f"127.0.0.1:{port}")
            return
        for path in health["paths"]:
            url = f"http://127.0.0.1:{port}{path}"
            argv = [*self.curl, "--fail", "--silent", "--output", "/dev/null",
                    "--max-time", str(health["requestTimeoutSec"]), url]
            self._poll(lambda: self.runner.run(argv, check=False).returncode == 0, health, url)
