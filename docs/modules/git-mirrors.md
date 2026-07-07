# Git Mirrors

`nixosModules.gitMirrors` periodically mirrors repositories from Gitea to
GitHub.

## Public Owns

- repository discovery from the configured Gitea API
- per-repository mapping and GitHub repository creation policy
- a bare repository cache under `stateDir`
- a locked one-shot sync service and systemd timer
- the file-path token interface for Gitea and GitHub credentials

## Private Owns

- real Gitea and GitHub URLs
- token secret names and secret recipients
- default GitHub owner and owner type
- repository exclusions and placement on real hosts

## Example

```nix
{
  vps.enable = true;
  vps.services.gitMirrors = {
    enable = true;
    mirrorAll = false;
    gitea = {
      baseUrl = "https://git.example.net";
      username = "mirror";
      tokenFile = "/run/secrets/gitea-token";
    };
    github = {
      owner = "example-org";
      tokenFile = "/run/secrets/github-token";
    };
    repositories.demo.githubName = "demo-mirror";
  };
}
```

Private adapters should map SOPS, agenix, or another secret system to
`gitea.tokenFile` and `github.tokenFile`. The public module never needs to know
real secret names.

## Operational Notes

The rendered mirror config lives in the Nix store. Repository names, mirror
destinations, descriptions, and source URLs are therefore host-visible
configuration, not secrets.

The sync logs also include repository paths and API error messages. Keep
private repo inventory policy in the private adapter, and use
`excludeRepositories` when `mirrorAll = true` would include repositories that
should not be mirrored.

GitHub mirror visibility follows the source Gitea repository visibility unless
a private wrapper changes that policy.
