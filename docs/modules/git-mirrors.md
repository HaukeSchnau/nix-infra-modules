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

## Ref Ownership

The sync mirrors branches and tags. It overwrites or deletes a GitHub ref only
while that ref still holds what the mirror last pushed there. Each mirror's
bare repository records those values under `refs/remotes/github/`, and every
push carries a `--force-with-lease` for the value the sync just read from
GitHub.

Once someone else pushes to a mirrored ref on GitHub, such as an upstream
maintainer editing a pull request branch in a fork, the sync keeps their
version and logs it. The mirror takes the ref back when Gitea catches up to
GitHub or builds on top of GitHub's commit. If Gitea rewrites a ref that
someone changed on GitHub, the sync leaves GitHub alone and fails that
repository until a person reconciles the two. Deleting such a ref in Gitea
leaves it on GitHub, and refs that only ever existed on GitHub are never
touched.

A mirror without a record, such as one created before the record existed,
treats a GitHub ref as its own when the ref points at a commit it fetched from
Gitea.

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
