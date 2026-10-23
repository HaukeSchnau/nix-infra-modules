{
  config,
  lib,
  pkgs,
  ...
}:
let
  vps = config.vps;
  cfg = vps.services.gitMirrors;
  serviceMetadata = import ../fleet/service-metadata.nix { inherit lib; };

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
        inherit (cfg.github) baseUrl apiBaseUrl;
      };
      inherit (cfg) mirrorAll excludeRepositories;
      inherit repositories;
    }
  );

  syncScript = ./git_mirrors_sync.py;
in
{
  imports = [ ../fleet/foundation.nix ];

  options.vps.services.gitMirrors = {
    enable = lib.mkEnableOption "periodic Gitea-to-GitHub repository mirrors";

    metadata = serviceMetadata.mkOptions {
      displayName = "Git Mirrors";
      category = "Developer";
    };

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
      type = lib.types.path;
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
      baseUrl = lib.mkOption {
        type = lib.types.str;
        default = "https://github.com";
        description = "GitHub web and Git remote base URL.";
      };

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
