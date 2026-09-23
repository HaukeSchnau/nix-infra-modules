"""Small helpers shared by the controller modules."""

from __future__ import annotations

import contextlib
import copy
import json
import os
import pathlib
import re
import shlex
import shutil
import subprocess
import tempfile
from collections.abc import Sequence
from typing import Any, TypeVar

NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,62}$")
DNS_RE = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$")

T = TypeVar("T")


class ProjectError(RuntimeError):
    """A failure the CLI reports to the user without a traceback."""


def snapshot(value: T) -> T:
    """A detached copy of registry data that can outlive the registry lock."""
    return copy.deepcopy(value)


def slugify(value: str, *, maximum: int = 48) -> str:
    value = value.lower().encode("ascii", "ignore").decode("ascii")
    value = re.sub(r"[^a-z0-9]+", "-", value).strip("-") or "workspace"
    return value[:maximum].rstrip("-") or "workspace"


def normalized_repository_url(value: str) -> str:
    """Normalize common Git transports to host/path for identity matching."""
    value = value.strip().rstrip("/")
    scp = re.match(r"^[^@/]+@([^:]+):(.+)$", value)
    if scp:
        host, path = scp.groups()
    else:
        parsed = re.match(
            r"^(?:[a-z][a-z0-9+.-]*://)?(?:[^@/]+@)?([^/]+)/(.+)$", value, re.IGNORECASE
        )
        if not parsed:
            return value.removesuffix(".git").lower()
        host, path = parsed.groups()
    return f"{host.lower()}/{path.removesuffix('.git').strip('/')}"


def write_file(path: pathlib.Path, content: str, *, mode: int = 0o600) -> bool:
    """Atomically replace a file; returns whether its content changed."""
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() and path.read_text(encoding="utf-8") == content:
        return False
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(temporary)
    return True


def atomic_json(path: pathlib.Path, value: Any, *, mode: int = 0o600) -> None:
    write_file(path, json.dumps(value, indent=2, sort_keys=True) + "\n", mode=mode)


class Runner:
    """Runs subprocesses; tests substitute a fake."""

    def run(
        self,
        argv: Sequence[str],
        *,
        cwd: pathlib.Path | None = None,
        check: bool = True,
        capture: bool = False,
        capture_stdout: bool = False,
        timeout: int | None = None,
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            list(argv),
            cwd=cwd,
            check=check,
            text=True,
            stdout=subprocess.PIPE if capture or capture_stdout else None,
            stderr=subprocess.PIPE if capture else None,
            timeout=timeout,
        )

    def output(self, argv: Sequence[str], *, cwd: pathlib.Path) -> str | None:
        try:
            return self.run(argv, cwd=cwd, capture=True).stdout.strip()
        except (OSError, subprocess.CalledProcessError):
            return None


def command_from_environment(name: str, fallback: str) -> list[str]:
    """A command line overridable through the environment, resolved on PATH."""
    command = shlex.split(os.environ.get(name, fallback))
    resolved = shutil.which(command[0])
    if resolved is not None:
        command[0] = resolved
    return command
