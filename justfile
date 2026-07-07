fmt:
    nix fmt

quick:
    #!/usr/bin/env bash
    set -euo pipefail
    nix eval .#checks.x86_64-linux.format.drvPath >/dev/null
    nix eval .#checks.x86_64-linux.core-example.drvPath >/dev/null
    nix eval .#checks.x86_64-linux.edge-example.drvPath >/dev/null
    nix eval .#checks.x86_64-linux.edge-tcp-range-example.drvPath >/dev/null
    nix eval .#checks.x86_64-linux.workspace-repos-home.drvPath >/dev/null
    nix eval .#checks.x86_64-linux.workspace-repos-python.drvPath >/dev/null

check:
    nix flake check --all-systems

scan:
    #!/usr/bin/env bash
    set -euo pipefail
    if command -v gitleaks >/dev/null 2>&1; then
      gitleaks detect --source . --no-git --redact
    else
      nix run nixpkgs#gitleaks -- detect --source . --no-git --redact
    fi

preflight: fmt quick scan
