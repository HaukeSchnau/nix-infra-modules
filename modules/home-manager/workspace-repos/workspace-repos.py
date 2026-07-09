#!/usr/bin/env python3
import argparse
import json
import os
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.parse import urlparse


CONFIG_PATH = Path("~/.config/workspace-repos/config.json").expanduser()
DEFAULT_EXCLUDE_DIRS = {
    ".cache",
    ".cargo",
    ".direnv",
    ".gradle",
    ".local",
    ".npm",
    ".pnpm-store",
    ".venv",
    "Backups",
    "Library",
    "Project-Archive",
    "build",
    "dist",
    "node_modules",
    "target",
    "vendor",
    "venv",
}


@dataclass(frozen=True)
class Repo:
    path: str
    url: str
    bookmark: str | None = None
    source: str | None = None


def eprint(*values: object) -> None:
    print(*values, file=sys.stderr)


def home() -> Path:
    return Path.home().resolve()


def expand_home_path(value: str) -> Path:
    path = Path(os.path.expandvars(os.path.expanduser(value)))
    if path.is_absolute():
        return path.resolve()
    return (home() / path).resolve()


def relative_to_home(path: Path) -> str:
    try:
        return path.resolve().relative_to(home()).as_posix()
    except ValueError:
        return path.resolve().as_posix()


def command_exists(command: str) -> bool:
    return shutil.which(command) is not None


def run(
    args: list[str],
    *,
    cwd: Path | None = None,
    check: bool = True,
    timeout: int | None = None,
    quiet: bool = False,
) -> subprocess.CompletedProcess[str]:
    if not quiet:
        location = f" [{cwd}]" if cwd else ""
        print("$ " + " ".join(args) + location)

    result = subprocess.run(
        args,
        cwd=cwd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
    )
    if check and result.returncode != 0:
        message = result.stderr.strip() or result.stdout.strip()
        raise RuntimeError(f"{' '.join(args)} failed: {message}")
    return result


def load_json(path: Path) -> dict[str, Any]:
    if not path.exists():
        raise SystemExit(f"workspace-repos: config not found: {path}")
    with path.open() as handle:
        return json.load(handle)


def load_config(path: Path) -> dict[str, Any]:
    config = load_json(path)
    inventory = config.get("inventory", config)
    if inventory.get("version") != 1:
        raise SystemExit("workspace-repos: unsupported inventory version")
    inventory.setdefault("roots", [])
    inventory.setdefault("gitlab_groups", [])
    inventory.setdefault("repositories", [])
    config["inventory"] = inventory
    return config


def repo_from_dict(value: dict[str, Any], source: str | None = None) -> Repo:
    path = value.get("path")
    url = value.get("url")
    if not isinstance(path, str) or not path:
        raise ValueError(f"repository entry has invalid path: {value!r}")
    if not isinstance(url, str) or not url:
        raise ValueError(f"repository entry has invalid url: {value!r}")
    bookmark = value.get("bookmark")
    if bookmark is not None and not isinstance(bookmark, str):
        bookmark = None
    return Repo(path=path, url=url, bookmark=bookmark, source=source)


def repo_to_dict(repo: Repo) -> dict[str, str]:
    result = {
        "path": repo.path,
        "url": repo.url,
    }
    if repo.bookmark:
        result["bookmark"] = repo.bookmark
    return result


def configured_repos(inventory: dict[str, Any]) -> list[Repo]:
    repos: list[Repo] = []
    for entry in inventory["repositories"]:
        repos.append(repo_from_dict(entry, "inventory"))
    return sorted(dedupe_repos(repos).values(), key=lambda repo: repo.path)


def is_relative_to_path(path: Path, base: Path) -> bool:
    try:
        path.relative_to(base)
        return True
    except ValueError:
        return False


def gitlab_managed_base_paths(inventory: dict[str, Any]) -> list[Path]:
    bases: list[Path] = []
    for group_config in inventory["gitlab_groups"]:
        base_path = group_config.get("base_path")
        if isinstance(base_path, str) and base_path:
            bases.append(expand_home_path(base_path))
    return bases


def is_gitlab_managed_path(path: Path, inventory: dict[str, Any]) -> bool:
    resolved = path.resolve()
    return any(
        resolved == base or is_relative_to_path(resolved, base)
        for base in gitlab_managed_base_paths(inventory)
    )


def is_gitlab_managed_repo(repo: Repo, inventory: dict[str, Any]) -> bool:
    return is_gitlab_managed_path(expand_home_path(repo.path), inventory)


def dedupe_repos(repos: list[Repo]) -> dict[str, Repo]:
    deduped: dict[str, Repo] = {}
    for repo in repos:
        existing = deduped.get(repo.path)
        if existing is not None and not git_urls_equivalent(existing.url, repo.url):
            eprint(
                "workspace-repos: conflicting urls for "
                f"{repo.path}: {existing.url} != {repo.url}; keeping first"
            )
            continue
        deduped.setdefault(repo.path, repo)
    return deduped


def git_origin_url(path: Path) -> str | None:
    result = run(
        ["git", "-C", str(path), "remote", "get-url", "origin"],
        check=False,
        quiet=True,
    )
    if result.returncode != 0:
        return None
    url = result.stdout.strip()
    return url or None


def normalized_git_url(value: str | None) -> tuple[str, int | None, str] | None:
    if not value:
        return None

    port = None
    if "://" in value:
        parsed = urlparse(value)
        host = parsed.hostname or parsed.netloc
        port = parsed.port
        path = parsed.path.lstrip("/")
    elif "@" in value and ":" in value:
        host_part, path = value.split(":", 1)
        host = host_part.rsplit("@", 1)[-1]
    else:
        return None

    if port == 22:
        port = None
    if path.endswith(".git"):
        path = path[:-4]
    return (host.lower(), port, path.strip("/").lower())


def git_urls_equivalent(left: str | None, right: str | None) -> bool:
    if left == right:
        return True
    normalized_left = normalized_git_url(left)
    normalized_right = normalized_git_url(right)
    return normalized_left is not None and normalized_left == normalized_right


def git_default_bookmark(path: Path) -> str | None:
    result = run(
        [
            "git",
            "-C",
            str(path),
            "symbolic-ref",
            "--short",
            "refs/remotes/origin/HEAD",
        ],
        check=False,
        quiet=True,
    )
    if result.returncode != 0:
        return None
    ref = result.stdout.strip()
    if ref.startswith("origin/"):
        return ref.removeprefix("origin/")
    return ref or None


def is_repo_dir(path: Path) -> bool:
    return (path / ".git").exists() or (path / ".jj").is_dir()


def is_empty_dir(path: Path) -> bool:
    return path.is_dir() and not any(path.iterdir())


def has_jj(path: Path) -> bool:
    return (path / ".jj").is_dir()


def has_git(path: Path) -> bool:
    return (path / ".git").exists()


def ensure_origin(path: Path, url: str) -> None:
    current = git_origin_url(path)
    if git_urls_equivalent(current, url):
        return
    if current is None:
        run(["git", "-C", str(path), "remote", "add", "origin", url])
        return
    eprint(f"workspace-repos: updating origin for {relative_to_home(path)}")
    run(["git", "-C", str(path), "remote", "set-url", "origin", url])


def clone_repo(repo: Repo, destination: Path, timeout: int | None) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    args = ["jj", "git", "clone", "--colocate"]
    if repo.bookmark:
        args.extend(["--branch", repo.bookmark])
    args.extend([repo.url, str(destination)])
    run(args, timeout=timeout)


def reconcile_repo(
    repo: Repo,
    *,
    fetch: bool,
    timeout: int | None,
) -> None:
    destination = expand_home_path(repo.path)

    if not destination.exists():
        print(f"clone {repo.path}")
        clone_repo(repo, destination, timeout)
    elif not destination.is_dir():
        raise RuntimeError(f"{destination} exists but is not a directory")
    elif has_jj(destination):
        print(f"ok jj {repo.path}")
    elif has_git(destination):
        print(f"init jj {repo.path}")
        run(["jj", "git", "init", "--colocate", str(destination)], timeout=timeout)
    elif is_empty_dir(destination):
        print(f"clone into empty {repo.path}")
        clone_repo(repo, destination, timeout)
    else:
        raise RuntimeError(
            f"{destination} exists, but is neither empty nor a Git/JJ repository"
        )

    if not has_git(destination):
        raise RuntimeError(f"{destination} is not a colocated Git repository")

    ensure_origin(destination, repo.url)

    if fetch:
        print(f"fetch {repo.path}")
        run(
            ["jj", "-R", str(destination), "git", "fetch", "--remote", "origin"],
            timeout=timeout,
        )


def discover_local_repos(inventory: dict[str, Any]) -> list[Repo]:
    repos: list[Repo] = []
    for root_value in inventory["roots"]:
        root = expand_home_path(root_value)
        if not root.exists():
            eprint(
                "workspace-repos: skip missing root "
                f"{root} (relative roots are resolved from {home()})"
            )
            continue
        if is_gitlab_managed_path(root, inventory):
            eprint(
                "workspace-repos: skip GitLab-managed local root "
                f"{root}; use gitlab_groups discovery for this tree"
            )
            continue
        for current, dir_names, _file_names in os.walk(root, followlinks=False):
            current_path = Path(current)
            dir_names[:] = [
                name
                for name in dir_names
                if not is_gitlab_managed_path(current_path / name, inventory)
            ]
            if is_repo_dir(current_path):
                url = git_origin_url(current_path)
                if url:
                    repos.append(
                        Repo(
                            path=relative_to_home(current_path),
                            url=url,
                            bookmark=git_default_bookmark(current_path),
                            source="local",
                        )
                    )
                dir_names[:] = []
                continue

            dir_names[:] = [
                name
                for name in dir_names
                if name not in DEFAULT_EXCLUDE_DIRS and not name.startswith(".")
            ]
    return repos


def gitlab_namespace_path(project: dict[str, Any], group: str) -> str:
    path_with_namespace = str(project.get("path_with_namespace") or "")
    prefix = group.strip("/") + "/"
    if path_with_namespace.startswith(prefix):
        return path_with_namespace.removeprefix(prefix)
    path = str(project.get("path") or "")
    return path or path_with_namespace.rsplit("/", 1)[-1]


def discover_gitlab_group(group_config: dict[str, Any]) -> list[Repo]:
    if not command_exists("glab"):
        eprint("workspace-repos: glab not found; skipping GitLab group discovery")
        return []

    group = group_config["group"]
    base_path = group_config["base_path"]
    include_archived = bool(group_config.get("include_archived", False))
    preserve_namespace = bool(group_config.get("preserve_namespace", True))

    projects: list[dict[str, Any]] = []
    per_page = 100
    page = 1

    while True:
        args = [
            "glab",
            "repo",
            "list",
            "--group",
            group,
            "--include-subgroups",
            "--output",
            "json",
            "--per-page",
            str(per_page),
            "--page",
            str(page),
        ]
        if not include_archived:
            args.append("--archived=false")

        result = run(args, check=False, quiet=True)
        if result.returncode != 0:
            eprint(
                "workspace-repos: GitLab discovery failed for "
                f"{group}: {result.stderr.strip() or result.stdout.strip()}"
            )
            return []

        try:
            page_projects = json.loads(result.stdout)
        except json.JSONDecodeError as error:
            eprint(f"workspace-repos: could not parse glab JSON for {group}: {error}")
            return []

        if not page_projects:
            break
        projects.extend(page_projects)
        if len(page_projects) < per_page:
            break
        page += 1

    repos: list[Repo] = []
    for project in projects:
        if project.get("archived") and not include_archived:
            continue
        url = project.get("ssh_url_to_repo") or project.get("http_url_to_repo")
        if not url:
            continue
        if preserve_namespace:
            local_tail = gitlab_namespace_path(project, group)
        else:
            local_tail = str(project.get("path") or "").strip("/")
        if not local_tail:
            continue
        bookmark = project.get("default_branch")
        repos.append(
            Repo(
                path=(Path(base_path) / local_tail).as_posix(),
                url=str(url),
                bookmark=str(bookmark) if bookmark else None,
                source=f"gitlab:{group}",
            )
        )
    return repos


def discover_gitlab_groups(inventory: dict[str, Any]) -> list[Repo]:
    repos: list[Repo] = []
    for group_config in inventory["gitlab_groups"]:
        group = group_config.get("group")
        base_path = group_config.get("base_path")
        if not isinstance(group, str) or not group:
            eprint(f"workspace-repos: invalid GitLab group config: {group_config!r}")
            continue
        if not isinstance(base_path, str) or not base_path:
            eprint(f"workspace-repos: invalid GitLab base path: {group_config!r}")
            continue
        repos.extend(discover_gitlab_group(group_config))
    return repos


def merged_discovered_repos(
    inventory: dict[str, Any],
    *,
    include_local: bool,
    include_gitlab: bool,
) -> list[Repo]:
    repos = [
        repo
        for repo in configured_repos(inventory)
        if include_gitlab or not is_gitlab_managed_repo(repo, inventory)
    ]
    if include_local:
        repos.extend(discover_local_repos(inventory))
    if include_gitlab:
        repos.extend(discover_gitlab_groups(inventory))
    return sorted(dedupe_repos(repos).values(), key=lambda repo: repo.path)


def write_inventory(config: dict[str, Any], repos: list[Repo]) -> Path:
    inventory = dict(config["inventory"])
    inventory["repositories"] = [repo_to_dict(repo) for repo in repos]
    output_path = expand_home_path(config["writable_inventory_path"])
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("w") as handle:
        json.dump(inventory, handle, indent=2, sort_keys=True)
        handle.write("\n")
    print(f"wrote {output_path}")
    return output_path


def maybe_commit_inventory(path: Path) -> None:
    repo_root_path = Path(
        run(["jj", "-R", str(path.parent), "root"], quiet=True).stdout.strip()
    )
    changed = [
        line.strip()
        for line in run(
            ["jj", "-R", str(repo_root_path), "diff", "--name-only"],
            quiet=True,
        ).stdout.splitlines()
        if line.strip()
    ]
    if not changed:
        print("inventory unchanged; nothing to commit")
        return

    inventory_relpath = path.resolve().relative_to(repo_root_path).as_posix()
    if changed != [inventory_relpath]:
        raise RuntimeError(
            "refusing to commit inventory because the working copy has other changes: "
            + ", ".join(changed)
        )

    run(["jj", "-R", str(repo_root_path), "status"])
    run(
        [
            "jj",
            "-R",
            str(repo_root_path),
            "commit",
            "-m",
            "chore: update workspace repo inventory",
        ]
    )


def command_sync(args: argparse.Namespace, config: dict[str, Any]) -> int:
    inventory = config["inventory"]
    include_gitlab = args.discover_gitlab_groups
    repos = merged_discovered_repos(
        inventory,
        include_local=False,
        include_gitlab=include_gitlab,
    )
    if args.write:
        write_inventory(config, repos)

    failures = 0
    for repo in repos:
        try:
            reconcile_repo(repo, fetch=args.fetch, timeout=args.timeout)
        except Exception as error:
            failures += 1
            eprint(f"workspace-repos: {repo.path}: {error}")
            if not args.activation:
                continue
    if failures:
        eprint(f"workspace-repos: {failures} repos failed")
    return 0 if args.activation or failures == 0 else 1


def command_fetch(args: argparse.Namespace, config: dict[str, Any]) -> int:
    failures = 0
    for repo in configured_repos(config["inventory"]):
        destination = expand_home_path(repo.path)
        if not destination.exists():
            eprint(f"workspace-repos: missing {repo.path}; run sync")
            failures += 1
            continue
        try:
            print(f"fetch {repo.path}")
            run(
                ["jj", "-R", str(destination), "git", "fetch", "--remote", "origin"],
                timeout=args.timeout,
            )
        except Exception as error:
            failures += 1
            eprint(f"workspace-repos: {repo.path}: {error}")
    return 0 if failures == 0 else 1


def command_doctor(args: argparse.Namespace, config: dict[str, Any]) -> int:
    failures = 0
    repos = merged_discovered_repos(
        config["inventory"],
        include_local=False,
        include_gitlab=args.discover_gitlab_groups,
    )
    for repo in repos:
        destination = expand_home_path(repo.path)
        problems: list[str] = []
        if not destination.exists():
            problems.append("missing")
        else:
            if not has_jj(destination):
                problems.append("not initialized with jj")
            if not has_git(destination):
                problems.append("not colocated with git")
            current = git_origin_url(destination)
            if not git_urls_equivalent(current, repo.url):
                problems.append(f"origin is {current or '<missing>'}")
        if problems:
            failures += 1
            print(f"[fail] {repo.path}: {', '.join(problems)}")
        else:
            print(f"[ok]   {repo.path}")
    return 0 if failures == 0 else 1


def command_capture(args: argparse.Namespace, config: dict[str, Any]) -> int:
    repos = merged_discovered_repos(
        config["inventory"],
        include_local=True,
        include_gitlab=not args.skip_gitlab_groups,
    )
    if args.write:
        output_path = write_inventory(config, repos)
        eprint(f"workspace-repos: captured {len(repos)} repositories")
        if args.commit:
            maybe_commit_inventory(output_path)
    else:
        eprint(
            "workspace-repos: dry run; pass --write to update "
            f"{config.get('writable_inventory_path', '<configured inventory path>')}"
        )
        eprint(f"workspace-repos: discovered {len(repos)} repositories")
        for repo in repos:
            print(json.dumps(repo_to_dict(repo), sort_keys=True))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Reconcile declared workspace repositories.")
    parser.add_argument(
        "--config",
        type=Path,
        default=CONFIG_PATH,
        help=f"Config path. Default: {CONFIG_PATH}",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    sync = subparsers.add_parser("sync", help="Clone missing repos and ensure JJ colocation.")
    sync.add_argument("--activation", action="store_true", help="Do not fail the caller.")
    sync.add_argument("--discover-gitlab-groups", action="store_true")
    sync.add_argument("--write", action="store_true", help="Write discovered repos first.")
    sync.add_argument("--fetch", dest="fetch", action="store_true", default=True)
    sync.add_argument("--no-fetch", dest="fetch", action="store_false")
    sync.add_argument("--timeout", type=int, default=120)
    sync.set_defaults(func=command_sync)

    fetch = subparsers.add_parser("fetch", help="Fetch all managed repositories.")
    fetch.add_argument("--timeout", type=int, default=120)
    fetch.set_defaults(func=command_fetch)

    doctor = subparsers.add_parser("doctor", help="Check managed repository state.")
    doctor.add_argument("--discover-gitlab-groups", action="store_true")
    doctor.set_defaults(func=command_doctor)

    capture = subparsers.add_parser("capture", help="Discover repos and optionally write inventory.")
    capture.add_argument("--write", action="store_true")
    capture.add_argument("--commit", action="store_true")
    capture.add_argument("--skip-gitlab-groups", action="store_true")
    capture.set_defaults(func=command_capture)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    config = load_config(args.config.expanduser())
    return args.func(args, config)


if __name__ == "__main__":
    raise SystemExit(main())
