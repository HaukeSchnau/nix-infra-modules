fmt:
    nix fmt

quick:
    #!/usr/bin/env bash
    set -euo pipefail
    nix eval .#checks.x86_64-linux.format.drvPath >/dev/null
    nix eval .#checks.x86_64-linux.core-example.drvPath >/dev/null
    nix eval .#checks.x86_64-linux.edge-example.drvPath >/dev/null
    nix eval .#checks.x86_64-linux.edge-tcp-range-example.drvPath >/dev/null

check:
    nix flake check --all-systems

scan:
    gitleaks detect --source . --no-git --redact

preflight: fmt quick scan
