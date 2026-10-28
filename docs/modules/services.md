# Services

`vps.services.serviceController` runs services that repositories declare at runtime, with no NixOS
switch. The host's configuration gives each repository a grant. The repository's Alchemy stack
declares its services with `Fleet.Service` from [`@schnau/fleet`](../../packages/fleet), and the
controller runs them within the grant.

```nix
{
  vps.services.serviceController = {
    enable = true;
    grantKeyFile = config.sops.secrets."app-deployments/placement-key".path;
    postgresql.package = pkgs.postgresql_18;
    addresses.ipv4 = "203.0.113.10";
    grants.shop = {
      hostNames = [ "*.shop.example.net" ];
      public = true;
      services = 6;
      memoryMax = "4G";
      secretPrefixes = [ "projects/shop/" ];
      databases = true;
    };
  };
}
```

A grant limits:

- `hostNames`: exact names, or `*.example.org` for every name below example.org.
- `public`: whether a service may be reachable from the internet. Otherwise only the tailnet
  reaches it.
- `services`: how many services the grant runs at once.
- `memoryMax`: the memory its services share. Each service then sets `memory.max`, and the sum
  stays within the ceiling.
- `secretPrefixes`: the SOPS keys its services may read. Sealed values need no prefix.
- `databases`: whether its services may have a PostgreSQL database each.

A service belongs to the grant it is named after: grant `shop` holds `shop`, `shop-beta` and
`shop-pr-12`. Grant names may not overlap that way.

The module enables PostgreSQL once a grant allows databases, and `postgresql.package` is then
required, so the major version never follows `system.stateVersion` unnoticed. With sops-nix, the
controller reads `sops.defaultSopsFile` and `sops.age.keyFile` unless `sopsFile` and `ageKeyFile`
say otherwise.

## The API

The controller listens on port 18110, opened on `tailscale0`:

```console
PUT    /services/<name>        apply a spec; 202 with its generation, or 200 when nothing changed
POST   /services/<name>/plan   what a spec would change, without applying it
GET    /services/<name>        what runs, its owner, grant violations and recent deploys
DELETE /services/<name>        stop the service and remove its route; see below for its database
```

A request carries `Authorization: Bearer <token>`: the grant's token, `HMAC-SHA256(key, grant)`
with the key in `grantKeyFile`, or the token in `tokenFile`, which opens every service. An empty
token or key opens nothing. Placements derive project tokens from the same kind of key, so one key
serves both.

A refusal answers 422 with every reason; reasons never quote a secret's value or SOPS key. A PUT
or DELETE while the service deploys answers 423, and the client tries again.

Besides the spec, a PUT may carry:

- `owner`, the `{stack, stage, fqn}` that puts the service. The controller records it and refuses
  a PUT from another owner, unless the PUT also says `adopt: true`, which Alchemy sends only when
  it adopts the service.
- `fence`, the deploy lease's fencing token. The controller remembers the highest fence per
  service, also after a deletion, and answers 409 to a lower one.

DELETE takes the same `owner` and `fence` in its body. A DELETE from another owner deletes nothing
and answers `{"deleted": false}`.

```json
{
  "release": {
    "revision": "4f2c1e9",
    "paths": { "bundle": "/nix/store/...-shop-bundle", "node": "/nix/store/...-nodejs-slim-26.4.0" }
  },
  "command": ["{node}/bin/node", "{bundle}/server/main.mjs", "serve"],
  "prepare": ["{node}/bin/node", "{bundle}/server/main.mjs", "prepare"],
  "console": ["{node}/bin/node", "{bundle}/server/main.mjs", "console"],
  "endpoint": { "hostName": "beta.shop.example.net", "visibility": "public" },
  "health": { "path": "/api/health/ready", "timeoutSec": 60 },
  "database": { "env": "DATABASE_URL", "majorVersion": 18, "dropOnDelete": false },
  "env": { "PUBLIC_URL": "https://beta.shop.example.net" },
  "secrets": { "AUTH_SECRET": { "value": "..." }, "MAIL_URL": { "sops": "projects/shop/mail-url" } },
  "memory": { "max": "1G" },
  "owner": { "stack": "Shop", "stage": "beta", "fqn": "Server" },
  "fence": 1793209550123
}
```

`{bundle}` stands for the release's path `bundle`. A command's first word is a file in one of the
paths. The process gets the spec's `env`, plus `HOST` and `PORT` for its loopback listener, the
database URL, and `<NAME>_FILE` for each secret, a file in its credentials directory.

## A deploy

1. The PUT checks the spec against the grant, writes it as a new generation, and returns its
   number. A spec equal to the active one changes nothing and answers 200 at once. While a
   service deploys, both its generations count against the grant: their hostnames, and the
   larger of their memory limits.
2. The controller realizes the store paths from the host's substituters, creates the database and
   role `fleet-<name>` when the spec asks for one, and writes the secrets into
   `/run/fleet/<name>/<generation>/`.
3. It runs `prepare` as the service's user, with the new release's environment and credentials.
   When `prepare` fails, the active generation keeps running untouched, and the deploy's outcome
   is `failed` with the end of its output. `prepare` may run for `prepareTimeoutSec`, at most 20
   minutes; Fleet.Service waits 40 minutes for a verdict.
4. It cuts over: a drop-in in `/run/systemd/system/fleet-service@<name>.service.d/` gives the
   template unit the new command, environment, credentials and memory limits, and the unit
   restarts.
5. It waits for the health path to answer 200. If it doesn't within `timeoutSec`, the process
   exits, or anything else after the cutover fails, the controller puts the previous drop-in
   back, and the outcome is `rolled-back`. A first deploy has nothing to go back to: it stops,
   and the outcome is `failed`.

The client polls `GET /services/<name>` until its generation's outcome is `active`, `failed` or
`rolled-back`. A `prepare` that a rolled-back release ran stays applied, so migrations have to
expand and contract.

## Deleting

A DELETE writes a tombstone first, then stops the service and removes its drop-in, route and
state. The service's database and role stay, unless every generation's spec set
`database.dropOnDelete`, as a preview's does. Then the controller dumps the database into
`<backup.directory>/deleted/fleet-<name>-<time>.dump` and drops it only after the dump succeeded.
Those dumps stay for `backup.deletedRetentionDays`. A deletion a restart interrupted finishes at
the next start.

`Fleet.Service` sends `dropOnDelete` only where the stack sets it. `RemovalPolicy.retain()` keeps
everything, including the running service, because Alchemy then never deletes.

## Isolation

Every service runs as a `DynamicUser` with the stable name `fleet-<name>`, which is also its
PostgreSQL role, so peer authentication works. The template unit hardens it: `ProtectSystem` is
strict, the service has no state directory, it never swaps (`MemorySwapMax=0`), and it may bind
only its own port. `prepare` and the console bind none.

Only a service's own role may connect to its database: the controller revokes `CONNECT` and
`TEMPORARY` from `PUBLIC`. Each role may hold `postgresql.connectionLimit` connections (25), and a
new database is refused once the services' limits would exceed `max_connections` less 10, which
stay for the superuser, the dumps and operators. Raise
`services.postgresql.settings.max_connections` for more services.

## On the host

```console
fleet status                    every service: revision, generation, state, URL, memory, last deploy
fleet status <service>          one service, with its owner, grant violations and recent deploys
fleet logs <service> [-f ...]   journalctl for the service
fleet console <service> [args]  the spec's console command, as the service's user
```

- State lives in `/var/lib/fleet/services/<name>/`: the active generation's spec with sealed
  secret values, the service's port, its owner and its recent deploys. Fences live in
  `/var/lib/fleet/fences/`. Secret values are sealed with the host's age key (`ageKeyFile`).
- At start, and every five minutes, the controller writes again what a boot empties from `/run`
  (credentials and drop-ins) and starts services that aren't running. It never stops a running
  service. When a switch shrinks a grant below what runs, the service keeps running, `fleet
  status` shows the violations, and its next PUT is refused until it fits again. When a secret
  can't be decrypted, the service keeps the credentials it has. Every five minutes it only
  decrypts credentials that are missing; a changed SOPS file arrives with a switch, which
  restarts the controller.
- `routesFile` lists the active services' routes, `{name, hostName, visibility, upstreamPort}`.
  The host's runtime ingress serves them with its default proxy. The grant has checked each
  hostname, so the ingress has to accept names below any parent from this source.
- `fleet-dump.timer` dumps every service's database nightly with `pg_dump -Fc` into
  `/var/backup/fleet`, which `server.backup` picks up when it is enabled. Kept databases of
  deleted services are dumped too.
- Services get loopback ports from `portRange`, 18300 to 18499 by default.

## Checks

`checks.<system>.service-controller` is a NixOS VM test. It deploys a service, rolls back a
revision whose health check fails and one whose process exits, keeps the old revision when
`prepare` fails, checks the grant's refusals and owners, deletes a preview with its database and a
service without it, checks isolation, shrinks the grant under a running service through a switch,
loses the age key, dumps, reboots, and prints `fleet status`. Its SOPS file is a path in the
repository, as with sops-nix. `service-controller-unit` tests the grant checks and the
controller's decisions against a stubbed systemd.
