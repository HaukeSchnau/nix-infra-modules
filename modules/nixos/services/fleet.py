"""fleet: what the service controller runs on this host.

Usage:
  fleet status [<service>] [--json]     every service, or one with its recent deploys
  fleet logs <service> [journalctl options...]
  fleet console <service> [arguments...]  the service's console command, as the service's user
"""

import json
import os
import sys
import time

import controller as fleet


def age(at: int) -> str:
    seconds = int(time.time()) - at
    for unit, size in (("d", 86400), ("h", 3600), ("m", 60)):
        if seconds >= size:
            return f"{seconds // size}{unit} ago"
    return f"{seconds}s ago"


def last_deploy(service: dict) -> str:
    if not service["deploys"]:
        return "-"
    entry = service["deploys"][0]
    return f"{entry['outcome']} {age(entry['at'])}"


def status(arguments: list[str]) -> int:
    as_json = "--json" in arguments
    names = [argument for argument in arguments if argument != "--json"]
    if len(names) > 1:
        return usage()
    if names and not fleet.service_dir(names[0]).is_dir():
        print(f"fleet: no service {names[0]}", file=sys.stderr)
        return 1
    services = [fleet.describe(name) for name in (names or fleet.services())]
    if as_json:
        print(json.dumps(services[0] if names else services, indent=2))
    elif names:
        detail(services[0])
    else:
        rows = [("SERVICE", "REVISION", "GEN", "STATE", "URL", "MEMORY", "LAST DEPLOY")]
        for service in services:
            rows.append((
                service["name"],
                (service["revision"] or "-")[:12],
                str(service["generation"] or "-"),
                "refused" if service["refused"] else service["state"],
                service["url"] or "-",
                service["memory"].get("max", "-"),
                last_deploy(service),
            ))
        widths = [max(len(row[column]) for row in rows) for column in range(len(rows[0]))]
        for row in rows:
            print("  ".join(cell.ljust(width) for cell, width in zip(row, widths)).rstrip())
    return 0


def detail(service: dict) -> None:
    record = fleet.active_record(service["name"])
    spec = record["spec"] if record else None
    fields = [
        ("revision", service["revision"]),
        ("generation", service["generation"]),
        ("state", service["state"]),
        ("refused", service["refused"]),
        ("unit", service["unit"]),
        ("user", service["user"]),
        ("url", service["url"] and f"{service['url']} ({service['visibility']})"),
        ("port", service["port"]),
        ("database", service["database"]),
        ("memory", ", ".join(f"{key} {value}" for key, value in sorted(service["memory"].items())) or None),
    ]
    if spec:
        fields += [
            ("paths", ", ".join(f"{key} {path}" for key, path in sorted(spec["release"]["paths"].items()))),
            ("command", " ".join(spec["command"])),
            ("prepare", spec["prepare"] and " ".join(spec["prepare"])),
            ("console", spec["console"] and " ".join(spec["console"])),
            ("health", f"{spec['health']['path']} within {spec['health']['timeoutSec']}s"),
            ("env", ", ".join(sorted(spec["env"])) or None),
            ("secrets", ", ".join(
                f"{key} ({'sops ' + source['sops'] if 'sops' in source else 'sealed value'})"
                for key, source in sorted(spec["secrets"].items())
            ) or None),
        ]
    width = max(len(label) for label, _ in fields)
    for label, value in fields:
        if value is not None:
            print(f"{label.ljust(width)}  {value}")
    print("\ndeploys:")
    for entry in service["deploys"]:
        line = f"  {entry['generation']:>4}  {entry['revision'][:12]:<12}  {entry['outcome']:<11}  {age(entry['at'])}"
        print(line)
        for reason in (entry["reason"] or "").splitlines():
            print(f"        {reason}")


def logs(arguments: list[str]) -> int:
    if not arguments:
        return usage()
    name, options = arguments[0], arguments[1:]
    journalctl = fleet.CONFIG["bin"]["journalctl"]
    os.execv(journalctl, [journalctl, "--unit", fleet.unit(name), *options])


def console(arguments: list[str]) -> int:
    if not arguments:
        return usage()
    name, extra = arguments[0], arguments[1:]
    record = fleet.active_record(name) if fleet.service_dir(name).is_dir() else None
    if record is None:
        print(f"fleet: {name} runs no generation", file=sys.stderr)
        return 1
    if record["spec"]["console"] is None:
        print(f"fleet: {name}'s spec has no console command", file=sys.stderr)
        return 1
    terminal = "--pty" if sys.stdin.isatty() and sys.stdout.isatty() else "--pipe"
    args = fleet.transient(name, record, f"fleet-console-{name}-{os.getpid()}.service", record["spec"]["console"] + extra, [terminal])
    os.execv(args[0], args)


def usage() -> int:
    print(__doc__.strip(), file=sys.stderr)
    return 64


def main() -> int:
    fleet.load_config()
    command, arguments = (sys.argv[1], sys.argv[2:]) if len(sys.argv) > 1 else (None, [])
    if os.geteuid() != 0 and command in ("status", "console"):
        print("fleet: run as root, which reads the services' state", file=sys.stderr)
        return 1
    return {"status": status, "logs": logs, "console": console}.get(command, lambda _: usage())(arguments)


if __name__ == "__main__":
    sys.exit(main())
