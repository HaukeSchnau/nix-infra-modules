# Build source for a Project release: the repository without the files that
# only describe the Project, its development environment or CI, so editing
# them does not rebuild the application. Flake sources already omit untracked
# files such as node_modules.
{ lib }:
{
  root,
  exclude ? [ ],
}:
let
  ignored = [
    ".envrc"
    ".gitea"
    ".github"
    "AGENTS.md"
    "CLAUDE.md"
    "README.md"
    "devenv.lock"
    "devenv.nix"
    "devenv.yaml"
    "flake.lock"
    "flake.nix"
    "project.nix"
  ]
  ++ exclude;
in
lib.fileset.toSource {
  inherit root;
  fileset = lib.fileset.difference root (
    lib.fileset.unions (map (path: lib.fileset.maybeMissing (root + "/${path}")) ignored)
  );
}
