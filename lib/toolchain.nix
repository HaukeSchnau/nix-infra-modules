# The Node and pnpm every TypeScript project shares, taken from the caller's nixpkgs. See
# docs/modules/toolchain.md.
{ pkgs }:
let
  nodejs = pkgs.nodejs-slim_26;
in
{
  inherit nodejs;
  # pnpm 12 is a native binary, but fetchPnpmDeps runs Node from `pnpm.nodejs-slim`.
  pnpm = pkgs.pnpm_12.override { nodejs-slim = nodejs; };
}
