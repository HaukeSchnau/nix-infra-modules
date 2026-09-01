{ pkgs }:

pkgs.writeShellApplication {
  name = "ci-workspace-run";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.procps
    pkgs.rsync
    pkgs.util-linux
  ];
  text = builtins.readFile ./ci-workspace-runner.sh;
}
