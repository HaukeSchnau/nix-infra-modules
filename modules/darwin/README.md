# nix-darwin Modules

`projects` makes a Mac a release host for Project repositories; see
`docs/modules/projects.md`.

The other nix-darwin exports are workstation leaves:

- `wireguard-profiles`
- `developer-fonts`
- `developer-paths`

They intentionally avoid real profile names, private paths, hostnames, and
secrets. Private workstation profiles should provide those concrete values.
