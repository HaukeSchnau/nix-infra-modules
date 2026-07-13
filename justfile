fmt:
    nix fmt

quick:
    #!/usr/bin/env bash
    set -euo pipefail
    nix eval .#checks.x86_64-linux.format.drvPath >/dev/null
    nix eval .#checks.x86_64-linux.core-example.drvPath >/dev/null
    nix eval .#checks.x86_64-linux.edge-example.drvPath >/dev/null
    nix eval .#checks.x86_64-linux.fleet-generated-services-example.drvPath >/dev/null
    nix eval .#checks.x86_64-linux.edge-contract-example.drvPath >/dev/null
    nix eval .#checks.x86_64-linux.caddy-internal-ingress-example.drvPath >/dev/null
    nix eval .#checks.x86_64-linux.edge-tcp-range-example.drvPath >/dev/null
    nix eval .#checks.x86_64-linux.podman-runtime-example.drvPath >/dev/null
    nix eval .#checks.x86_64-linux.github-runner-example.drvPath >/dev/null
    nix eval .#checks.x86_64-linux.gitea-runner-example.drvPath >/dev/null
    nix build --no-link .#checks.x86_64-linux.git-mirrors-example
    nix eval .#checks.x86_64-linux.server-backup-example.drvPath >/dev/null
    nix eval .#checks.x86_64-linux.workspace-repos-home.drvPath >/dev/null
    nix eval .#checks.x86_64-linux.workspace-repos-home-no-gitlab-discovery.drvPath >/dev/null
    nix eval .#checks.x86_64-linux.workspace-repos-python.drvPath >/dev/null
    nix build --no-link .#checks.x86_64-linux.workspace-repos-discovery-failure
    nix build --no-link .#checks.x86_64-linux.workspace-repos-gitlab-discovery

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

sanitize:
    #!/usr/bin/env bash
    set -euo pipefail
    if rg -n --hidden --glob '!.git/**' --glob '!justfile' \
      -e 'schnau\.dev' \
      -e 'HaukeSchnau' \
      -e 'haukeschnau' \
      -e 'openclaw' \
      -e 'paperless' \
      -e 'tailscale_authkey' \
      -e 'TODO_PRIVATE' \
      -e 'srv-[0-9]' \
      .; then
      echo "Potential private term found in public repository" >&2
      exit 1
    fi

preflight: fmt quick scan sanitize
