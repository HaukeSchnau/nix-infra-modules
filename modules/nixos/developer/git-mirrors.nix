{
  config,
  lib,
  pkgs,
  ...
}:
let
  vps = config.vps;
  cfg = vps.services.gitMirrors;

  repositoryType = lib.types.submodule (
    { name, ... }:
    {
      options = {
        gitea = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "example/demo";
          description = "Gitea repository path in owner/name form. Defaults to the attribute name.";
        };

        github = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "example-org/demo";
          description = "GitHub repository path in owner/name form. Defaults to github.owner/name.";
        };

        githubName = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "GitHub repository name when github is not set. Defaults to the Gitea repository name.";
        };

        githubOwner = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "GitHub owner override when github is not set.";
        };

        githubOwnerType = lib.mkOption {
          type = lib.types.nullOr (
            lib.types.enum [
              "user"
              "org"
            ]
          );
          default = null;
          description = "GitHub owner type override used when creating the repository.";
        };

        description = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Optional description for newly-created GitHub repositories.";
        };

        create = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Create the GitHub repository when it is missing.";
        };
      };
    }
  );

  repositories = lib.mapAttrsToList (name: repo: {
    inherit name;
    giteaPath = repo.gitea;
    githubPath = repo.github;
    inherit (repo)
      githubName
      githubOwner
      githubOwnerType
      description
      create
      ;
  }) cfg.repositories;

  configFile = pkgs.writeText "git-mirrors.json" (
    builtins.toJSON {
      gitea = {
        inherit (cfg.gitea) baseUrl apiBaseUrl username;
      };
      inherit (cfg) userAgent;
      defaults = {
        githubOwner = cfg.github.owner;
        githubOwnerType = cfg.github.ownerType;
      };
      github = {
        inherit (cfg.github) apiBaseUrl;
      };
      inherit (cfg) mirrorAll excludeRepositories;
      inherit repositories;
    }
  );

  syncScript = pkgs.writeText "git-mirrors-sync.py" ''
    import fcntl
    import json
    import os
    import shutil
    import subprocess
    import sys
    import urllib.error
    import urllib.parse
    import urllib.request


    CONFIG_FILE = os.environ["GIT_MIRRORS_CONFIG"]
    STATE_DIR = os.environ["GIT_MIRRORS_STATE_DIR"]
    RUNTIME_DIR = os.environ["GIT_MIRRORS_RUNTIME_DIR"]
    GITEA_TOKEN_FILE = os.environ["GIT_MIRRORS_GITEA_TOKEN_FILE"]
    GITHUB_TOKEN_FILE = os.environ["GIT_MIRRORS_GITHUB_TOKEN_FILE"]

    REFSPECS = [
        "+refs/heads/*:refs/heads/*",
        "+refs/tags/*:refs/tags/*",
    ]


    def read_secret(path):
        with open(path, "r", encoding="utf-8") as handle:
            return handle.read().strip()


    def quote_credential(value):
        return urllib.parse.quote(value, safe="")


    def repo_parts(path):
        owner, sep, repo = path.partition("/")
        if not sep or not owner or not repo or "/" in repo:
            raise ValueError(f"expected owner/name repository path, got {path!r}")
        return owner, repo


    def mirror_key(path):
        owner, repo = repo_parts(path)
        return f"{owner}__{repo}"


    def repo_url(base_url, path):
        return f"{base_url.rstrip('/')}/{path}.git"


    def repo_api_path(path):
        owner, repo = repo_parts(path)
        return f'/repos/{urllib.parse.quote(owner, safe="")}/{urllib.parse.quote(repo, safe="")}'


    def gitea_visibility(repo):
        return "private" if repo.get("private", True) else "public"


    def github_url(path):
        return f"https://github.com/{path}.git"


    def credential_line(url, username, password):
        parsed = urllib.parse.urlparse(url)
        if parsed.scheme != "https":
            raise ValueError(f"credential store only supports https URLs, got {url!r}")
        return (
            f"https://{quote_credential(username)}:{quote_credential(password)}"
            f"@{parsed.netloc}\n"
        )


    class Gitea:
        def __init__(self, base_url, api_base_url, token):
            self.base_url = base_url.rstrip("/")
            self.api_base_url = (api_base_url or f"{self.base_url}/api/v1").rstrip("/")
            self.token = token

        def request(self, path):
            request = urllib.request.Request(
                f"{self.api_base_url}{path}",
                headers={
                    "Accept": "application/json",
                    "Authorization": f"token {self.token}",
                    "User-Agent": cfg["userAgent"],
                },
                method="GET",
            )
            try:
                with urllib.request.urlopen(request, timeout=30) as response:
                    data = response.read()
            except urllib.error.HTTPError as error:
                message = error.read().decode("utf-8", errors="replace")
                raise RuntimeError(f"Gitea API GET {path} failed: HTTP {error.code}: {message}") from error

            if not data:
                return {}
            return json.loads(data.decode("utf-8"))

        def list_repositories(self):
            repositories = []
            page = 1
            limit = 50
            while True:
                batch = self.request(f"/user/repos?limit={limit}&page={page}")
                if not isinstance(batch, list):
                    raise RuntimeError("Gitea API /user/repos returned a non-list response")
                repositories.extend(batch)
                if len(batch) < limit:
                    return repositories
                page += 1

        def get_repository(self, path):
            return self.request(repo_api_path(path))


    class GitHub:
        def __init__(self, api_base_url, token):
            self.api_base_url = api_base_url.rstrip("/")
            self.token = token

        def request(self, method, path, payload=None, allow_not_found=False):
            body = None
            headers = {
                "Accept": "application/vnd.github+json",
                "Authorization": f"Bearer {self.token}",
                "User-Agent": cfg["userAgent"],
                "X-GitHub-Api-Version": "2022-11-28",
            }
            if payload is not None:
                body = json.dumps(payload).encode("utf-8")
                headers["Content-Type"] = "application/json"

            request = urllib.request.Request(
                f"{self.api_base_url}{path}",
                data=body,
                headers=headers,
                method=method,
            )
            try:
                with urllib.request.urlopen(request, timeout=30) as response:
                    data = response.read()
            except urllib.error.HTTPError as error:
                if allow_not_found and error.code == 404:
                    return None
                message = error.read().decode("utf-8", errors="replace")
                raise RuntimeError(f"GitHub API {method} {path} failed: HTTP {error.code}: {message}") from error

            if not data:
                return {}
            return json.loads(data.decode("utf-8"))

        def ensure_repo(self, github_path, owner_type, visibility, description, create):
            owner, repo = repo_parts(github_path)
            existing = self.request("GET", f"/repos/{owner}/{repo}", allow_not_found=True)
            desired_private = visibility == "private"

            if existing is None:
                if not create:
                    raise RuntimeError(f"GitHub repository {github_path} does not exist and create=false")

                payload = {
                    "name": repo,
                    "private": desired_private,
                    "auto_init": False,
                }
                if description:
                    payload["description"] = description

                if owner_type == "org":
                    self.request("POST", f"/orgs/{owner}/repos", payload)
                else:
                    self.request("POST", "/user/repos", payload)
                print(f"github: created {github_path} as {visibility}", flush=True)
                return

            patch = {}
            if bool(existing.get("private")) != desired_private:
                patch["private"] = desired_private
            if description is not None and existing.get("description") != description:
                patch["description"] = description
            if patch:
                self.request("PATCH", f"/repos/{owner}/{repo}", patch)
                print(f"github: updated {github_path}", flush=True)
            else:
                print(f"github: {github_path} already exists", flush=True)


    def run_git(args, cwd, credential_file, check=True, quiet=False):
        command = [
            "git",
            "-c",
            f"credential.helper=store --file={credential_file}",
            "-c",
            "gc.auto=0",
            *args,
        ]
        return subprocess.run(
            command,
            cwd=cwd,
            check=check,
            stdout=subprocess.DEVNULL if quiet else None,
            stderr=subprocess.DEVNULL if quiet else None,
            env={
                **os.environ,
                "GIT_ASKPASS": "/bin/false",
                "GIT_TERMINAL_PROMPT": "0",
            },
        )


    def resolve_repository(repo, defaults):
        source_path = repo.get("giteaPath") or repo["name"]
        _source_owner, source_repo = repo_parts(source_path)

        github_path = repo.get("githubPath")
        if not github_path:
            github_owner = repo.get("githubOwner") or defaults["githubOwner"]
            github_name = repo.get("githubName") or source_repo
            github_path = f"{github_owner}/{github_name}"
        repo_parts(github_path)

        return {
            "name": mirror_key(source_path),
            "giteaPath": source_path,
            "githubPath": github_path,
            "githubOwnerType": repo.get("githubOwnerType") or defaults["githubOwnerType"],
            "visibility": repo.get("giteaVisibility") or "private",
            "description": repo.get("description"),
            "create": repo.get("create", True),
            "empty": bool(repo.get("empty", False)),
        }


    def resolve_repositories(cfg, gitea):
        excluded = set(cfg["excludeRepositories"])
        repositories = {}

        if cfg["mirrorAll"]:
            for repo in gitea.list_repositories():
                source_path = repo.get("full_name")
                if not source_path:
                    raise RuntimeError("Gitea repository entry is missing full_name")
                repositories[source_path] = {
                    "name": source_path,
                    "giteaPath": source_path,
                    "giteaVisibility": gitea_visibility(repo),
                    "empty": bool(repo.get("empty", False)),
                }

        for repo in cfg["repositories"]:
            source_path = repo.get("giteaPath") or repo["name"]
            merged = {
                **repositories.get(source_path, {}),
                **repo,
                "giteaPath": source_path,
            }
            if "giteaVisibility" not in merged:
                gitea_repo = gitea.get_repository(source_path)
                merged["giteaVisibility"] = gitea_visibility(gitea_repo)
                merged["empty"] = bool(gitea_repo.get("empty", merged.get("empty", False)))
            repositories[source_path] = merged

        resolved = []
        seen_destinations = {}
        for source_path, repo in sorted(repositories.items()):
            if source_path in excluded:
                print(f"mirror/{source_path}: skipped by excludeRepositories", flush=True)
                continue
            mirror = resolve_repository(repo, cfg["defaults"])
            previous_source = seen_destinations.get(mirror["githubPath"])
            if previous_source is not None:
                raise RuntimeError(
                    f"{source_path} and {previous_source} both resolve to GitHub repository {mirror['githubPath']}"
                )
            seen_destinations[mirror["githubPath"]] = source_path
            resolved.append(mirror)

        return resolved


    def sync_repository(repo, cfg, credential_file):
        name = repo["name"]
        source_url = repo_url(cfg["gitea"]["baseUrl"], repo["giteaPath"])
        destination_url = github_url(repo["githubPath"])
        mirror_dir = os.path.join(STATE_DIR, "repositories", f"{name}.git")

        print(f"mirror/{name}: syncing {repo['giteaPath']} -> {repo['githubPath']}", flush=True)
        if repo["empty"]:
            print(f"mirror/{name}: source repository is empty; GitHub repository exists", flush=True)
            return

        if not os.path.isdir(os.path.join(mirror_dir, "objects")):
            if os.path.exists(mirror_dir):
                shutil.rmtree(mirror_dir)
            os.makedirs(mirror_dir, exist_ok=True)
            run_git(
                ["init", "--bare", "--initial-branch=main", mirror_dir],
                cwd=None,
                credential_file=credential_file,
            )

        has_origin = run_git(
            ["remote", "get-url", "origin"],
            cwd=mirror_dir,
            credential_file=credential_file,
            check=False,
            quiet=True,
        ).returncode == 0
        if has_origin:
            run_git(["remote", "set-url", "origin", source_url], cwd=mirror_dir, credential_file=credential_file)
        else:
            run_git(["remote", "add", "origin", source_url], cwd=mirror_dir, credential_file=credential_file)
        run_git(["fetch", "--prune", "--prune-tags", "origin", *REFSPECS], cwd=mirror_dir, credential_file=credential_file)
        run_git(["push", "--prune", destination_url, *REFSPECS], cwd=mirror_dir, credential_file=credential_file)
        print(f"mirror/{name}: ok", flush=True)


    def main():
        with open(CONFIG_FILE, "r", encoding="utf-8") as handle:
            cfg = json.load(handle)

        gitea_token = read_secret(GITEA_TOKEN_FILE)
        github_token = read_secret(GITHUB_TOKEN_FILE)

        os.makedirs(os.path.join(STATE_DIR, "repositories"), exist_ok=True)
        os.makedirs(RUNTIME_DIR, exist_ok=True)

        lock_path = os.path.join(STATE_DIR, "sync.lock")
        with open(lock_path, "w", encoding="utf-8") as lock_handle:
            fcntl.flock(lock_handle, fcntl.LOCK_EX | fcntl.LOCK_NB)

            credential_file = os.path.join(RUNTIME_DIR, "credentials")
            try:
                with open(credential_file, "w", encoding="utf-8") as handle:
                    handle.write(credential_line(cfg["gitea"]["baseUrl"], cfg["gitea"]["username"], gitea_token))
                    handle.write(credential_line("https://github.com", "x-access-token", github_token))
                os.chmod(credential_file, 0o600)

                gitea = Gitea(cfg["gitea"]["baseUrl"], cfg["gitea"]["apiBaseUrl"], gitea_token)
                github = GitHub(cfg["github"]["apiBaseUrl"], github_token)
                repositories = resolve_repositories(cfg, gitea)
                failures = []
                for repo in repositories:
                    try:
                        github.ensure_repo(
                            repo["githubPath"],
                            repo["githubOwnerType"],
                            repo["visibility"],
                            repo["description"],
                            repo["create"],
                        )
                        sync_repository(repo, cfg, credential_file)
                    except Exception as error:
                        failures.append((repo["name"], str(error)))
                        print(f"mirror/{repo['name']}: failed: {error}", file=sys.stderr, flush=True)

                if failures:
                    print("git-mirrors: failures:", file=sys.stderr, flush=True)
                    for name, message in failures:
                        print(f"- {name}: {message}", file=sys.stderr, flush=True)
                    return 1

                print(f"git-mirrors: synced {len(repositories)} repositories", flush=True)
                return 0
            finally:
                try:
                    os.remove(credential_file)
                except FileNotFoundError:
                    pass


    if __name__ == "__main__":
        raise SystemExit(main())
  '';
in
{
  options.vps.services.gitMirrors = {
    enable = lib.mkEnableOption "periodic Gitea-to-GitHub repository mirrors";

    interval = lib.mkOption {
      type = lib.types.str;
      default = "15min";
      description = "systemd timer interval for mirror reconciliation.";
    };

    onBootSec = lib.mkOption {
      type = lib.types.str;
      default = "2min";
      description = "Delay before the first mirror sync after boot.";
    };

    randomizedDelaySec = lib.mkOption {
      type = lib.types.str;
      default = "2min";
      description = "Randomized delay added by the systemd timer.";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/git-mirrors";
      description = "Persistent bare repository cache directory.";
    };

    mirrorAll = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Discover and mirror all repositories visible to the configured Gitea token.";
    };

    excludeRepositories = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "example/scratch" ];
      description = "Gitea owner/name repositories excluded from automatic and explicit mirroring.";
    };

    userAgent = lib.mkOption {
      type = lib.types.str;
      default = "nix-infra-modules-git-mirrors";
      description = "HTTP User-Agent sent to the Gitea and GitHub APIs.";
    };

    gitea = {
      baseUrl = lib.mkOption {
        type = lib.types.str;
        default = "https://git.example.net";
        description = "Base URL of the source Gitea instance.";
      };

      apiBaseUrl = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Gitea API base URL. Defaults to gitea.baseUrl + /api/v1.";
      };

      username = lib.mkOption {
        type = lib.types.str;
        default = "git";
        description = "Gitea username used with the read token for HTTPS Git fetches.";
      };

      tokenFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Path to a Gitea read token file.";
      };
    };

    github = {
      owner = lib.mkOption {
        type = lib.types.str;
        default = "example-org";
        description = "Default GitHub owner for mirror repositories.";
      };

      ownerType = lib.mkOption {
        type = lib.types.enum [
          "user"
          "org"
        ];
        default = "user";
        description = "Default GitHub owner type, used when creating repositories.";
      };

      apiBaseUrl = lib.mkOption {
        type = lib.types.str;
        default = "https://api.github.com";
        description = "GitHub API base URL.";
      };

      tokenFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Path to a GitHub token file with repo create/write access.";
      };
    };

    repositories = lib.mkOption {
      type = lib.types.attrsOf repositoryType;
      default = { };
      description = "Per-repository mirror overrides or explicit mirrors when mirrorAll is false.";
    };
  };

  config = lib.mkIf (vps.enable && cfg.enable) {
    assertions = [
      {
        assertion = cfg.mirrorAll || cfg.repositories != { };
        message = "vps.services.gitMirrors.repositories must not be empty when gitMirrors is enabled with mirrorAll=false.";
      }
      {
        assertion = cfg.gitea.tokenFile != null;
        message = "vps.services.gitMirrors.gitea.tokenFile must be set when gitMirrors is enabled.";
      }
      {
        assertion = cfg.github.tokenFile != null;
        message = "vps.services.gitMirrors.github.tokenFile must be set when gitMirrors is enabled.";
      }
    ];

    vps.services.gitMirrors.metadata.health.units = [
      "git-mirrors-sync.timer"
    ];

    users.groups.git-mirrors = { };
    users.users.git-mirrors = {
      isSystemUser = true;
      group = "git-mirrors";
      home = cfg.stateDir;
      createHome = true;
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0750 git-mirrors git-mirrors - -"
      "d ${cfg.stateDir}/repositories 0750 git-mirrors git-mirrors - -"
    ];

    systemd.services.git-mirrors-sync = {
      description = "Synchronize Gitea repositories to GitHub mirrors";
      after = [
        "network-online.target"
        "gitea.service"
      ];
      wants = [ "network-online.target" ];
      path = [
        pkgs.git
        pkgs.openssh
      ];
      environment = {
        GIT_MIRRORS_CONFIG = configFile;
        GIT_MIRRORS_STATE_DIR = cfg.stateDir;
        GIT_MIRRORS_RUNTIME_DIR = "/run/git-mirrors";
        GIT_MIRRORS_GITEA_TOKEN_FILE = cfg.gitea.tokenFile;
        GIT_MIRRORS_GITHUB_TOKEN_FILE = cfg.github.tokenFile;
      };
      serviceConfig = {
        Type = "oneshot";
        User = "git-mirrors";
        Group = "git-mirrors";
        RuntimeDirectory = "git-mirrors";
        RuntimeDirectoryMode = "0700";
        StateDirectory = "git-mirrors";
        StateDirectoryMode = "0750";
        PrivateTmp = true;
        NoNewPrivileges = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ReadWritePaths = [
          cfg.stateDir
          "/run/git-mirrors"
        ];
        ExecStart = "${pkgs.python3}/bin/python3 ${syncScript}";
      };
    };

    systemd.timers.git-mirrors-sync = {
      description = "Periodic Gitea to GitHub repository mirror sync";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = cfg.onBootSec;
        OnUnitActiveSec = cfg.interval;
        RandomizedDelaySec = cfg.randomizedDelaySec;
        Persistent = true;
        Unit = "git-mirrors-sync.service";
      };
    };
  };
}
