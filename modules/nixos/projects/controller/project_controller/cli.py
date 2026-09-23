"""The `project` command.

    project [-p PROJECT] inspect|plan|export
    project [-p PROJECT] dev <lifecycle verb | declared command> ...
    project [-p PROJECT] prod <status | declared command> ...
    project obs ...
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import shutil
import subprocess
import sys
from collections.abc import Sequence
from dataclasses import dataclass
from typing import Any

from .controller import Controller
from .registry import load_catalog
from .util import ProjectError, command_from_environment

LIFECYCLE_ACTIONS = {"bundle", "down", "list", "logs", "reconcile", "relocate", "retire", "restart", "status", "up", "urls"}


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(prog="project")
    result.add_argument("-p", "--project", help="select a Project instead of discovering it from the checkout")
    top = result.add_subparsers(dest="concept", required=True)
    top.add_parser("inspect", help="print the checkout's Project contract")
    plan = top.add_parser("plan", help="resolve the contract against host policy without creating state")
    plan.add_argument("--name")
    export = top.add_parser("export", help="build the checkout's contract JSON")
    export.add_argument("--json", action="store_true")

    dev = top.add_parser(
        "dev",
        help="manage Development instances or run a declared command",
        description="Manage Development instances. An action not listed below runs a repository-declared command.",
    )
    actions = dev.add_subparsers(dest="action", required=True)

    def scoped(name: str, help: str, *, only: bool = False, json_output: bool = False) -> argparse.ArgumentParser:
        command = actions.add_parser(name, help=help)
        command.add_argument("--project", dest="verb_project", help=argparse.SUPPRESS)
        command.add_argument("--name", help="a named instance instead of the checkout's default")
        if only:
            command.add_argument("--only", help="limit to one workload")
        if json_output:
            command.add_argument("--json", action="store_true")
        return command

    scoped("up", "start the instance and wait until it is ready", only=True, json_output=True)
    scoped("down", "pause the instance, or stop one workload's endpoints with --only", only=True)
    scoped("restart", "down, then up", only=True)
    scoped("status", "show the instance and its endpoints", json_output=True)
    scoped("urls", "show endpoint URLs", only=True, json_output=True)
    scoped("logs", "show recent logs", only=True)
    scoped("retire", "stop the instance and unpublish it; data is retained")
    bundle = actions.add_parser("bundle", help="inspect or change the instance's prepared bundle")
    bundle.add_argument(
        "bundle_action",
        choices=["status", "refresh", "reset"],
        help="refresh builds from the checkout; reset returns to the pinned bundle",
    )
    bundle.add_argument("--project", dest="verb_project", help=argparse.SUPPRESS)
    bundle.add_argument("--name")
    bundle.add_argument("--json", action="store_true")
    actions.add_parser("list", help="list instances").add_argument("--project", dest="verb_project", help=argparse.SUPPRESS)
    relocate = actions.add_parser("relocate", help="rebind a retained instance to a checkout")
    relocate.add_argument("instance_id")
    relocate.add_argument("checkout", type=pathlib.Path)
    actions.add_parser("reconcile", help="repair instances (run by a timer)")

    prod = top.add_parser("prod", help="run a command against the active Release")
    prod.add_argument("command")
    prod.add_argument("arguments", nargs=argparse.REMAINDER)
    top.add_parser("obs", help="explore Development traces, logs, and metrics")

    internal = top.add_parser("internal", help=argparse.SUPPRESS)
    internal_actions = internal.add_subparsers(dest="internal_action", required=True)
    internal_actions.add_parser("retire-workspace").add_argument("--root", required=True, type=pathlib.Path)
    internal_actions.add_parser("run-manager").add_argument("--identity", required=True)
    for name in ("endpoint-activate", "endpoint-finished"):
        command = internal_actions.add_parser(name)
        command.add_argument("--identity", required=True)
        command.add_argument("--endpoint", required=True)
    return result


@dataclass(frozen=True)
class CommandInvocation:
    realization: str
    project: str | None
    name: str | None
    command: str
    arguments: list[str]


def global_project(argv: Sequence[str]) -> tuple[str | None, list[str]]:
    arguments = list(argv)
    if len(arguments) >= 2 and arguments[0] in ("-p", "--project"):
        return arguments[1], arguments[2:]
    if arguments and arguments[0].startswith("--project="):
        return arguments[0].split("=", 1)[1], arguments[1:]
    return None, arguments


def command_invocation(argv: Sequence[str]) -> CommandInvocation | None:
    """A repository-declared command, or None for the host's own verbs.

    Everything after the command name is forwarded unchanged.
    """
    project, arguments = global_project(argv)
    if len(arguments) < 2 or arguments[0] not in ("dev", "prod") or arguments[1] in ("-h", "--help"):
        return None
    realization = arguments[0]
    if realization == "dev" and arguments[1] in LIFECYCLE_ACTIONS:
        return None
    command_parser = argparse.ArgumentParser(prog=f"project {realization}")
    command_parser.add_argument("--project")
    if realization == "dev":
        command_parser.add_argument("--name")
    command_parser.add_argument("command")
    command_parser.add_argument("arguments", nargs=argparse.REMAINDER)
    parsed = command_parser.parse_args(arguments[1:])
    return CommandInvocation(
        realization, parsed.project or project, getattr(parsed, "name", None), parsed.command, parsed.arguments
    )


def print_urls(urls: dict[str, str], *, heading: str | None = None) -> None:
    if heading:
        print(heading)
    for endpoint, url in sorted(urls.items()):
        print(f"{endpoint}: {url}")


def print_status(status: dict[str, Any]) -> None:
    bundle = status["bundle"]
    print(f"Instance: {status['instanceKey']}")
    print(f"ID: {status['id']}")
    print(f"Desired state: {status['desiredState']}")
    print(f"Bundle: {bundle['kind']}{'' if bundle['available'] else ' (missing; run `project dev bundle refresh`)'}")
    for endpoint, value in sorted(status["endpoints"].items()):
        address = value.get("url") or f"{value['listen']['host']}:{value['listen']['port']}"
        print(f"{endpoint}: {address} [{value['lifecycle']['phase']}]")


def print_bundle_status(status: dict[str, Any]) -> None:
    print(f"Bundle: {status['kind']}")
    print(f"Available: {'yes' if status['available'] else 'no'}")
    provenance = status["provenance"]
    if provenance.get("sourceDigest"):
        print(f"Source: {provenance['sourceDigest']}")
    if provenance.get("bundlePath"):
        print(f"Path: {provenance['bundlePath']}")


def run_release(controller: Controller, invocation: CommandInvocation, cwd: pathlib.Path) -> None:
    """Hands `project prod` to the release adapter, which runs as the service user."""
    project, arguments = invocation.project, invocation.arguments
    if invocation.command == "status":
        status_parser = argparse.ArgumentParser(prog="project prod status")
        status_parser.add_argument("--project")
        status_parser.add_argument("--json", action="store_true")
        parsed = status_parser.parse_args(arguments)
        project = parsed.project or project
        arguments = ["--json"] if parsed.json else []
    if project is None:
        project = controller.discovery.resolve(cwd).project
    elif project not in controller.projects:
        raise ProjectError(f"Unknown Project: {project}")
    if invocation.command == "status":
        tool, invocation_arguments = "project-release-status", [project, *arguments]
    else:
        tool, invocation_arguments = "project-release-command", [project, invocation.command, *arguments]
    executable = shutil.which(tool)
    if executable is None:
        raise ProjectError(f"{tool} is unavailable on this host")
    sudo = command_from_environment("PROJECT_RELEASE_SUDO", "/run/wrappers/bin/sudo")
    os.execvpe(sudo[0], [*sudo, "-n", executable, *invocation_arguments], os.environ)


def main(argv: Sequence[str] | None = None) -> int:
    raw = list(sys.argv[1:] if argv is None else argv)
    try:
        _, rest = global_project(raw)
        if rest and rest[0] == "obs":
            executable = shutil.which("project-observability")
            if executable is None:
                raise ProjectError("observability tooling is unavailable on this host")
            os.execv(executable, [executable, *rest[1:]])
        controller = Controller(load_catalog())
        cwd = pathlib.Path.cwd()
        invocation = command_invocation(raw)
        if invocation is not None:
            if invocation.realization == "prod":
                run_release(controller, invocation, cwd)
            controller.run_command(
                cwd=cwd,
                command_name=invocation.command,
                arguments=invocation.arguments,
                project=invocation.project,
                name=invocation.name,
            )
            return 0

        args = parser().parse_args(raw)
        project = getattr(args, "verb_project", None) or args.project
        json_output = bool(getattr(args, "json", False))
        if not json_output:
            controller.report = lambda message: print(message, file=sys.stderr)
        scope = {"cwd": cwd, "project": project, "name": getattr(args, "name", None)}
        if args.concept == "export":
            path = controller.export(cwd)
            print(json.dumps({"path": str(path)}) if json_output else f"Exported {path}")
            return 0
        if args.concept in ("inspect", "plan"):
            value: Any = controller.plan(cwd, args.name) if args.concept == "plan" else controller.inspect(cwd)
            print(json.dumps(value, indent=2, sort_keys=True))
            return 1 if args.concept == "plan" and not value["ready"] else 0
        if args.concept == "internal":
            if args.internal_action == "retire-workspace":
                controller.retire_workspace(args.root)
                return 0
            if args.internal_action == "run-manager":
                controller.run_manager(args.identity)
                return 0
            handler = controller.endpoint_activate if args.internal_action == "endpoint-activate" else controller.endpoint_finished
            print(json.dumps(handler(args.identity, args.endpoint), indent=2, sort_keys=True))
            return 0

        action = args.action
        only = getattr(args, "only", None)
        if action == "up":
            value = controller.up(**scope, only=only)
        elif action == "down":
            value = controller.down(**scope, only=only)
        elif action == "restart":
            value = controller.restart(**scope, only=only)
        elif action == "status":
            value = controller.status(**scope)
        elif action == "urls":
            value = controller.urls(**scope, only=only)
        elif action == "logs":
            controller.logs(**scope, only=only)
            return 0
        elif action == "bundle":
            if args.bundle_action == "refresh":
                controller.refresh_bundle(**scope)
            elif args.bundle_action == "reset":
                controller.reset_bundle(**scope)
            value = controller.bundle_status(**scope)
        elif action == "list":
            value = controller.list_instances(project)
        elif action == "retire":
            value = controller.retire(**scope)
        elif action == "relocate":
            value = controller.relocate(args.instance_id, args.checkout)
        else:
            value = controller.reconcile()

        if json_output:
            print(json.dumps(value, indent=2, sort_keys=True))
        elif action == "up":
            print_urls(controller.urls(**scope, only=only), heading="Ready:")
        elif action == "status":
            print_status(value)
        elif action == "urls":
            print_urls(value)
        elif action == "bundle":
            print_bundle_status(value)
        else:
            print(json.dumps(value, indent=2, sort_keys=True))
        return 0
    except ProjectError as error:
        print(f"project: {error}", file=sys.stderr)
        return 1
    except subprocess.CalledProcessError as error:
        print(
            f"project: runtime command failed with exit status {error.returncode}; "
            "inspect `project dev logs` for startup details",
            file=sys.stderr,
        )
        return 1
