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
required, so the major version never follows `system.stateVersion` unnoticed.

## The API

The controller listens on port 18110, opened on `tailscale0`:

```console
PUT    /services/<name>        apply a spec; 202 with its generation, or 200 when nothing changed
POST   /services/<name>/plan   what a spec would change, without applying it
GET    /services/<name>        what runs, and the outcomes of recent deploys
DELETE /services/<name>        stop the service, drop its database, remove its route
```

A request carries `Authorization: Bearer <token>`: the grant's token, `HMAC-SHA256(key, grant)`
with the key in `grantKeyFile`, or the token in `tokenFile`, which opens every service.
Placements derive project tokens from the same kind of key, so one key serves both.

A refusal answers 422 with every reason. A PUT while the service deploys answers 423, and the
client tries again. A spec may carry `fence`, and `DELETE` an `X-Fleet-Fence` header: the
controller remembers the highest fence per service and answers 409 to a lower one, which comes
from a replaced deploy lease.

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
  "database": { "env": "DATABASE_URL", "majorVersion": 18 },
  "env": { "PUBLIC_URL": "https://beta.shop.example.net" },
  "secrets": { "AUTH_SECRET": { "value": "..." }, "MAIL_URL": { "sops": "projects/shop/mail-url" } },
  "memory": { "max": "1G" }
}
```

`{bundle}` stands for the release's path `bundle`. A command's first word is a file in one of the
paths. The process gets the spec's `env`, plus `HOST` and `PORT` for its loopback listener, the
database URL, and `<NAME>_FILE` for each secret, a file in its credentials directory.

## A deploy

1. The PUT checks the spec against the grant, writes it as a new generation, and returns its
   number. A spec equal to the active one changes nothing and answers 200 at once.
2. The controller realizes the store paths from the host's substituters, creates the database and
   role `fleet-<name>` when the spec asks for one, and writes the secrets into
   `/run/fleet/<name>/<generation>/`.
3. It runs `prepare` as the service's user, with the new release's environment and credentials.
   When `prepare` fails, the active generation keeps running untouched, and the deploy's outcome
   is `failed` with the end of its output.
4. It cuts over: a drop-in in `/run/systemd/system/fleet-service@<name>.service.d/` gives the
   template unit the new command, environment, credentials and memory limits, and the unit
   restarts.
5. It waits for the health path to answer 200. If it doesn't within `timeoutSec`, or the process
   exits, the controller puts the previous drop-in back, and the outcome is `rolled-back`.

The client polls `GET /services/<name>` until its generation's outcome is `active`, `failed` or
`rolled-back`.

Every service runs as a `DynamicUser` with the stable name `fleet-<name>`, which is also its
PostgreSQL role, so peer authentication works. The template unit hardens it. `ProtectSystem` is
strict, and the service has no state directory, since its state lives in its database.

## On the host

```console
fleet status                    every service: revision, generation, state, URL, memory, last deploy
fleet status <service>          one service, with its recent deploys and their reasons
fleet logs <service> [-f ...]   journalctl for the service
fleet console <service> [args]  the spec's console command, as the service's user
```

- State lives in `/var/lib/fleet/services/<name>/`: the active generation's spec with sealed
  secret values, the service's port, its fence and its recent deploys. Secret values are sealed
  with the host's age key (`ageKeyFile`).
- At start, and every five minutes, the controller writes again what a boot empties from `/run`
  (credentials and drop-ins) and starts services that aren't running. A service its grant no
  longer allows stops, and keeps its state and database.
- `routesFile` lists the active services' routes, `{name, hostName, visibility, upstreamPort,
  site}`, and each `site` is a Caddy snippet in `sitesDirectory`. The host's runtime ingress serves
  them as another route source.
- `fleet-dump.timer` dumps every service's database nightly with `pg_dump -Fc` into
  `/var/backup/fleet`, which `server.backup` picks up when it is enabled.
- Services get loopback ports from `portRange`, 18300 to 18499 by default.

## Checks

`checks.<system>.service-controller` is a NixOS VM test. It deploys a service, rolls back a
revision whose health check fails, keeps the old revision when `prepare` fails, checks the
grant's refusals, deletes a preview with its database, dumps, reboots, and prints `fleet status`.
`service-controller-unit` tests the grant checks.
