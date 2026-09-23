"""Matching a working directory to a Project checkout."""

from __future__ import annotations

import json
import pathlib
from collections.abc import Callable, Iterator, Mapping
from dataclasses import dataclass

from .model import CatalogProject
from .util import ProjectError, Runner, command_from_environment, normalized_repository_url


@dataclass(frozen=True)
class Checkout:
    project: str
    root: pathlib.Path
    canonical: bool
    workspace_name: str | None
    branch: str | None


# Called for checkouts that match no enrolled Project, with the checkout root
# and the requested Project name, to enroll a delegated one.
Delegate = Callable[[pathlib.Path, str | None], Checkout]


def inside(path: pathlib.Path, parent: pathlib.Path) -> bool:
    try:
        path.relative_to(parent)
        return True
    except ValueError:
        return False


class CheckoutDiscovery:
    """Finds a checkout by canonical path, workspace source, shared Git
    directory, or remote URL, in that order."""

    def __init__(
        self,
        projects: Mapping[str, CatalogProject],
        runner: Runner,
        *,
        workspace_launcher: str | None = None,
        delegate: Delegate | None = None,
    ):
        self.projects = projects
        self.runner = runner
        self.workspace_launcher = workspace_launcher
        self.delegate = delegate
        self.git = command_from_environment("PROJECT_DEVELOPMENT_GIT", "git")
        self.jj = command_from_environment("PROJECT_DEVELOPMENT_JJ", "jj")

    def root(self, cwd: pathlib.Path) -> pathlib.Path:
        value = self.runner.output([*self.git, "rev-parse", "--show-toplevel"], cwd=cwd)
        if value:
            return pathlib.Path(value).resolve()
        value = self.runner.output([*self.jj, "root"], cwd=cwd)
        return pathlib.Path(value).resolve() if value else cwd.resolve()

    def workspace_name(self, root: pathlib.Path) -> str | None:
        current = self.runner.output([*self.jj, "workspace", "root"], cwd=root)
        value = self.runner.output(
            [*self.jj, "workspace", "list", "-T", 'self.name() ++ "\\n"'], cwd=root
        )
        if not current or not value:
            return None
        current_path = pathlib.Path(current).resolve()
        for name in (line.strip() for line in value.splitlines()):
            if not name:
                continue
            candidate = self.runner.output(
                [*self.jj, "workspace", "root", "--name", name], cwd=root
            )
            if candidate and pathlib.Path(candidate).resolve() == current_path:
                return name
        return None

    def branch(self, root: pathlib.Path) -> str | None:
        return self.runner.output([*self.git, "branch", "--show-current"], cwd=root) or None

    def _common_dir(self, root: pathlib.Path) -> pathlib.Path | None:
        value = self.runner.output([*self.git, "rev-parse", "--git-common-dir"], cwd=root)
        if not value:
            return None
        path = pathlib.Path(value)
        return (root / path).resolve() if not path.is_absolute() else path.resolve()

    def _remotes(self, root: pathlib.Path) -> set[str]:
        result: set[str] = set()
        names = self.runner.output([*self.git, "remote"], cwd=root)
        for name in names.splitlines() if names else []:
            value = self.runner.output([*self.git, "remote", "get-url", name.strip()], cwd=root)
            if value:
                result.add(normalized_repository_url(value))
        value = self.runner.output([*self.jj, "git", "remote", "list"], cwd=root)
        for line in value.splitlines() if value else []:
            fields = line.split(maxsplit=1)
            if len(fields) == 2:
                result.add(normalized_repository_url(fields[1]))
        return result

    def _workspace_sources(self, root: pathlib.Path) -> Iterator[pathlib.Path]:
        """Independent workspaces inherit repository identity from their runtime record."""
        seen = {root}
        while self.workspace_launcher:
            value = self.runner.output(
                [self.workspace_launcher, "environment", "--cwd", str(root)], cwd=root
            )
            execution = json.loads(value) if value else None
            if not execution or not execution.get("sourceRoot"):
                return
            root = (
                pathlib.Path(execution["sourceRoot"]) / root.relative_to(execution["root"])
            ).resolve()
            if root in seen:
                return
            seen.add(root)
            yield root

    def _checkout(self, name: str) -> pathlib.Path:
        return pathlib.Path(self.projects[name]["repository"]["checkout"]).resolve()

    def _fallback(self, root: pathlib.Path, requested: str | None) -> Checkout:
        if self.delegate is not None:
            return self.delegate(root, requested)
        qualifier = f" for Project {requested}" if requested else ""
        raise ProjectError(f"Could not match {root} to a declared checkout{qualifier}")

    def resolve(self, cwd: pathlib.Path, requested: str | None = None) -> Checkout:
        cwd = cwd.resolve()
        if requested is not None and requested not in self.projects:
            return self._fallback(self.root(cwd), requested)

        candidates = [requested] if requested else list(self.projects)
        for name in candidates:
            canonical = self._checkout(name)
            if inside(cwd, canonical):
                delegated = self.projects[name].get("delegated", False)
                return Checkout(name, canonical, not delegated, "default", self.branch(canonical))

        root = self.root(cwd)
        for source in self._workspace_sources(root):
            for name in candidates:
                if source == self._checkout(name):
                    return Checkout(name, root, False, root.name, self.branch(root))
        common = self._common_dir(root)
        if common is not None:
            for name in candidates:
                canonical = self._checkout(name)
                if canonical.exists() and self._common_dir(canonical) == common:
                    return Checkout(name, root, False, self.workspace_name(root), self.branch(root))

        remotes = self._remotes(root)
        matches = [
            name
            for name in candidates
            if normalized_repository_url(self.projects[name]["repository"]["url"]) in remotes
        ]
        if len(matches) == 1:
            return Checkout(matches[0], root, False, self.workspace_name(root), self.branch(root))
        return self._fallback(root, requested)
