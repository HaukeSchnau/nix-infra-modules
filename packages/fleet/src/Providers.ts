import * as Provider from "alchemy/Provider"
import * as Layer from "effect/Layer"
import { Placement, PlacementProvider } from "./Placement.ts"
import { Service, ServiceProvider } from "./Service.ts"

export class Providers extends Provider.ProviderCollection<Providers>()("Fleet") {}

/** The Fleet resources. They read `FLEET_TOKEN` or `FLEET_TOKEN_FILE` when they run. */
export const providers = () =>
  Layer.effect(Providers, Provider.collection([Placement, Service])).pipe(
    Layer.provide(Layer.mergeAll(PlacementProvider(), ServiceProvider())),
  )
