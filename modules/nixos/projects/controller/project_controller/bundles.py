"""Checkout-built development bundles.

`project dev bundle refresh` copies the tracked files of a checkout into a
content-addressed snapshot and builds the prepared bundle from it, so ignored
dependency trees never enter the build. Builds are cached by snapshot digest.
"""

from __future__ import annotations

import contextlib
import fcntl
import hashlib
import json
import os
import pathlib
import shutil
import stat
import subprocess
import tempfile
from collections.abc import Callable, Iterator
from dataclasses import dataclass

from .model import Provenance
from .util import ProjectError, Runner, atomic_json

BUILDER_VERSION = 2
BUILD_TIMEOUT_SEC = 15 * 60


@dataclass(frozen=True)
class SourceSnapshot:
    path: pathlib.Path
    digest: str
    vcs: str
    file_count: int


class BundleBuilder:
    def __init__(
        self,
        builder: str,
        runner: Runner,
        now: Callable[[], float],
        report: Callable[[str], None],
    ):
        self.builder = builder
        self.runner = runner
        self.now = now
        self.report = report

    def _tracked_paths(self, checkout: pathlib.Path) -> tuple[str, list[str]]:
        if (checkout / ".jj").exists():
            vcs, command = "jj", ["jj", "file", "list", "-T", 'path ++ "\\0"']
        else:
            vcs, command = "git", ["git", "ls-files", "-z", "--cached"]
        try:
            result = self.runner.run(command, cwd=checkout, capture=True)
        except (OSError, subprocess.CalledProcessError) as error:
            detail = getattr(error, "stderr", None) or str(error)
            raise ProjectError(f"Could not list {vcs.upper()}-tracked source files: {detail.strip()}") from error
        return vcs, sorted(set(filter(None, result.stdout.split("\0"))))

    def _gitlink(self, checkout: pathlib.Path, tracked: str) -> str:
        """The commit of a submodule entry; its local contents are never copied."""
        result = self.runner.run(
            ["git", "--literal-pathspecs", "ls-files", "--stage", "-z", "--", tracked],
            cwd=checkout,
            capture=True,
        )
        entries = result.stdout.rstrip("\0").split("\0")
        header, separator, entry_path = entries[0].partition("\t")
        fields = header.split()
        if (
            len(entries) != 1
            or not separator
            or entry_path != tracked
            or len(fields) != 3
            or fields[0] != "160000"
            or fields[2] != "0"
        ):
            raise ProjectError(f"Tracked source is neither a file nor a symlink: {tracked!r}")
        return fields[1]

    def snapshot(self, checkout: pathlib.Path, root: pathlib.Path) -> SourceSnapshot:
        """Copies tracked files into root/<digest>, refusing paths that escape the checkout."""
        checkout = checkout.resolve()
        vcs, tracked_paths = self._tracked_paths(checkout)
        root.mkdir(parents=True, exist_ok=True, mode=0o700)
        temporary = pathlib.Path(tempfile.mkdtemp(prefix=".snapshot-", dir=root))
        digest = hashlib.sha256()
        try:
            for tracked in tracked_paths:
                relative = pathlib.PurePosixPath(tracked)
                if relative.is_absolute() or not relative.parts or any(
                    part in ("", ".", "..") for part in relative.parts
                ):
                    raise ProjectError(f"Tracked source path escapes the checkout: {tracked!r}")
                source = checkout.joinpath(*relative.parts)
                if not os.path.lexists(source):
                    # Git keeps deleted working-tree files in its index; omit them.
                    continue
                try:
                    source.parent.resolve().relative_to(checkout)
                except ValueError as error:
                    raise ProjectError(f"Tracked source path escapes the checkout: {tracked!r}") from error
                metadata = source.lstat()
                target = temporary.joinpath(*relative.parts)
                target.parent.mkdir(parents=True, exist_ok=True)
                digest.update(f"{tracked}\0{stat.S_IMODE(metadata.st_mode):o}\0".encode())
                if stat.S_ISLNK(metadata.st_mode):
                    link = os.readlink(source)
                    if pathlib.Path(link).is_absolute():
                        raise ProjectError(f"Tracked symlink has an absolute target: {tracked!r}")
                    try:
                        (source.parent / link).resolve().relative_to(checkout)
                    except ValueError as error:
                        raise ProjectError(f"Tracked symlink escapes the checkout: {tracked!r}") from error
                    digest.update(b"symlink\0" + os.fsencode(link))
                    os.symlink(link, target)
                elif stat.S_ISREG(metadata.st_mode):
                    digest.update(b"file\0")
                    with source.open("rb") as source_stream, target.open("wb") as target_stream:
                        while chunk := source_stream.read(1024 * 1024):
                            digest.update(chunk)
                            target_stream.write(chunk)
                    shutil.copystat(source, target, follow_symlinks=False)
                elif stat.S_ISDIR(metadata.st_mode):
                    digest.update(b"gitlink\0" + self._gitlink(checkout, tracked).encode())
                    target.mkdir()
                else:
                    raise ProjectError(f"Tracked source is neither a file nor a symlink: {tracked!r}")
                digest.update(b"\0")
            final = root / digest.hexdigest()
            if final.exists():
                shutil.rmtree(temporary)
            else:
                try:
                    temporary.rename(final)
                except FileExistsError:
                    shutil.rmtree(temporary)
            return SourceSnapshot(final, digest.hexdigest(), vcs, len(tracked_paths))
        except Exception:
            shutil.rmtree(temporary, ignore_errors=True)
            raise

    @staticmethod
    @contextlib.contextmanager
    def locked(root: pathlib.Path) -> Iterator[None]:
        root.mkdir(parents=True, exist_ok=True, mode=0o700)
        with (root / ".lock").open("a+") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            yield

    def build(self, project: str, checkout: pathlib.Path, root: pathlib.Path, out_link: pathlib.Path) -> Provenance:
        """Builds (or reuses) the bundle for the checkout's tracked files under root.

        `out_link` roots the build output until the caller retains it.
        """
        with self.locked(root):
            self.report("Snapshotting tracked source...")
            source = self.snapshot(checkout, root / "sources")
            key = {
                "builderVersion": BUILDER_VERSION,
                "builder": self.builder,
                "project": project,
                "sourceDigest": source.digest,
            }
            cache_key = hashlib.sha256(json.dumps(key, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
            record_path = root / "builds" / f"{cache_key}.json"
            with contextlib.suppress(OSError, KeyError, TypeError, json.JSONDecodeError):
                record = json.loads(record_path.read_text(encoding="utf-8"))
                if pathlib.Path(record["bundlePath"]).exists():
                    self.report("Using cached Development bundle.")
                    return {**record, "kind": "checkout", "cacheHit": True}
            self.report(f"Building Development bundle from {source.file_count} tracked files...")
            try:
                result = self.runner.run(
                    [self.builder, str(source.path), str(out_link)],
                    cwd=source.path,
                    capture_stdout=True,
                    timeout=BUILD_TIMEOUT_SEC,
                )
            except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
                detail = getattr(error, "stderr", None) or str(error)
                raise ProjectError(f"Could not realize Development bundle: {detail.strip()}") from error
            outputs = [line for line in result.stdout.splitlines() if line.startswith("/")]
            if len(outputs) != 1:
                raise ProjectError("Development bundle build did not produce exactly one output")
            record = {
                **key,
                "bundlePath": outputs[0],
                "vcs": source.vcs,
                "fileCount": source.file_count,
                "builtAt": self.now(),
            }
            atomic_json(record_path, record)
            return {**record, "kind": "checkout", "cacheHit": False}

    def export(self, checkout: pathlib.Path) -> pathlib.Path:
        """Evaluates the checkout's declarations and returns the contract JSON."""
        result = self.runner.run([self.builder, str(checkout), "--export"], capture_stdout=True, check=False)
        paths = result.stdout.splitlines() if result.returncode == 0 else []
        if len(paths) != 1:
            raise ProjectError("Could not export the Project contract; see the build error above")
        return pathlib.Path(paths[0])

    def retain(self, path: pathlib.Path, root: pathlib.Path) -> None:
        """Keeps a bundle alive against garbage collection through an indirect root."""
        if root.is_symlink() and root.resolve() == path.resolve():
            return
        root.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        try:
            self.runner.run(
                ["nix-store", "--realise", str(path), "--add-root", str(root), "--indirect"],
                capture_stdout=True,
            )
        except (OSError, subprocess.CalledProcessError) as error:
            raise ProjectError(f"Could not retain Development bundle {path}: {error}") from error
