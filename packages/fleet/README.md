# @schnau/fleet

Alchemy provider for placing a release on a host that runs nix-infra-modules' app
deployments. The host's configuration gives the project a grant; the repository's stack
declares where and how its release runs within it. See
[Placements](../../docs/modules/app-deployments.md#placements).

```ts
import * as Fleet from "@schnau/fleet"

const placement = yield* Fleet.Placement("Release", {
  project: "shop",
  host: "srv-2",
  endpoint: { hostName: "shop.example.net", visibility: "public" },
  secrets: { apiKey: "projects/shop/api-key" },
  jobs: { backup: { calendar: "*-*-* 04:00" } },
})
```

Add `Fleet.providers()` to the stack's providers. The provider talks to
`http://<host>:18100` (`FLEET_URL` overrides it) with the project's token from
`FLEET_TOKEN`, or from the file `FLEET_TOKEN_FILE` names. A placement the grant doesn't
allow fails with `PlacementRefused` and the host's reasons; on an update, the dry run
already shows them.

The package is published to `https://git.schnau.dev/api/packages/schnau/npm/`:

```ini
# .npmrc
@schnau:registry=https://git.schnau.dev/api/packages/schnau/npm/
```

Build with `pnpm build`; publish with `pnpm publish` against that registry.
