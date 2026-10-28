# @schnau/fleet

Alchemy provider for hosts that run nix-infra-modules. The host's configuration gives a
repository a grant; the repository's stack declares what runs within it.

- `Fleet.Service` runs a service through the host's
  [service controller](../../docs/modules/services.md): store paths, commands, an endpoint, a
  database, environment and secrets. No NixOS switch is involved.
- `Fleet.Placement` places a release that the host compiles as a Project release. See
  [Placements](../../docs/modules/app-deployments.md#placements).

## Fleet.Service

```ts
import * as Fleet from "@schnau/fleet"
import { RemovalPolicy } from "alchemy"

const service = yield* Fleet.Service("Server", {
  host: "srv-2",
  name: "shop-beta",
  release: { revision, paths: { bundle, node } },
  command: ["{node}/bin/node", "{bundle}/server/main.mjs", "serve"],
  prepare: ["{node}/bin/node", "{bundle}/server/main.mjs", "prepare"],
  console: ["{node}/bin/node", "{bundle}/server/main.mjs", "console"],
  endpoint: { hostName: "beta.shop.example.net", visibility: "public" },
  health: { path: "/api/health/ready" },
  database: { majorVersion: 18 },
  env: { PUBLIC_URL: "https://beta.shop.example.net" },
  secrets: { MAIL_URL: "projects/shop/mail-url", AUTH_SECRET: authSecret.value },
  memory: { max: "1G" },
}).pipe(RemovalPolicy.retain(stage === "prod"))

service.url // https://beta.shop.example.net
service.address.ipv4 // the host's public address, for a DNS record
```

- `diff` asks the host what the spec would change (`POST /services/<name>/plan`). An unchanged
  service needs no deploy, and a spec outside the grant fails in a dry run with the host's
  reasons (`ServiceRefused`).
- `reconcile` puts the spec and waits for the host's verdict. When `prepare` fails, or the new
  revision fails its health check, the host keeps or restores the old revision, and the deploy
  fails with `DeployFailed` and the reason.
- `delete` stops the service and drops its database. A database that must outlive the stack, such
  as prod's, keeps it with `RemovalPolicy.retain()`.
- A secret is a SOPS key name of the host's secrets, or a `Redacted` value, which the host seals
  with its age key. The process reads each from the file `<NAME>_FILE` names.
- `release.paths` names several store paths, such as an architecture-independent bundle and the
  host's Node. They must be in a cache the host substitutes from.

The provider talks to `http://<host>:18110` (`FLEET_SERVICES_URL` overrides it). It sends
`FLEET_FENCE`, the deploy lease's fencing token, when that is set; the host refuses a lower one
than it has seen.

## Fleet.Placement

```ts
const placement = yield* Fleet.Placement("Release", {
  project: "shop",
  host: "srv-2",
  endpoint: { hostName: "shop.example.net", visibility: "public" },
  secrets: { apiKey: "projects/shop/api-key" },
  jobs: { backup: { calendar: "*-*-* 04:00" } },
})
```

The provider talks to `http://<host>:18100` (`FLEET_URL` overrides it). A placement the grant
doesn't allow fails with `PlacementRefused` and the host's reasons; on an update, the dry run
already shows them.

## Setup

Add `Fleet.providers()` to the stack's providers. Both resources take the grant's token from
`FLEET_TOKEN`, or from the file `FLEET_TOKEN_FILE` names. The host derives it as
HMAC-SHA256 of the grant's name, so it opens that grant's services and placement only.

The package is published to `https://git.schnau.dev/api/packages/schnau/npm/`:

```ini
# .npmrc
@schnau:registry=https://git.schnau.dev/api/packages/schnau/npm/
```

Build with `pnpm build`; publish with `pnpm publish` against that registry.
