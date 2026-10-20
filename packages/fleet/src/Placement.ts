import { Resource } from "alchemy"
import { isResolved } from "alchemy/Diff"
import * as Provider from "alchemy/Provider"
import * as Config from "effect/Config"
import * as Data from "effect/Data"
import * as Effect from "effect/Effect"
import * as Option from "effect/Option"
import * as Redacted from "effect/Redacted"
import * as Schema from "effect/Schema"
import { FetchHttpClient, HttpClient, HttpClientRequest, HttpClientResponse } from "effect/http"
import { readFile } from "node:fs/promises"
import type { Providers } from "./Providers.ts"

/** When a job runs: a systemd calendar such as `*-*-* 04:00`, or an interval such as `30min`. */
export type JobSchedule =
  | { readonly calendar: string; readonly randomizedDelaySec?: string }
  | { readonly interval: string; readonly randomizedDelaySec?: string }

export interface PlacementProps {
  /** The project, as the host's configuration names it. */
  readonly project: string
  /** The host that runs the release, such as `srv-2`. */
  readonly host: string
  /** The release's hostname and who may reach it. Without it the release has no route. */
  readonly endpoint?: { readonly hostName: string; readonly visibility: "public" | "tailnet" }
  /** Secret names the release declares, each bound to a SOPS key under the project's prefix. */
  readonly secrets?: Readonly<Record<string, string>>
  /** Values of the release's parameters, on top of the host's. */
  readonly parameters?: Readonly<Record<string, unknown>>
  /** systemd memory limits of the release's service, up to the grant's ceiling. */
  readonly memory?: { readonly high?: string; readonly max?: string; readonly swapMax?: string }
  /** New schedules for jobs the host already runs, by name; the others keep the host's. */
  readonly jobs?: Readonly<Record<string, JobSchedule>>
}

export interface PlacementAttributes {
  readonly project: string
  readonly host: string
  /** `https://<hostName>`, when the placement has an endpoint. */
  readonly url: string | undefined
}

export type Placement = Resource<"Fleet.Placement", PlacementProps, PlacementAttributes, never, Providers>

/**
 * Where and how a release runs on a host, within the grant the host's configuration gives the
 * project. The host refuses a placement outside the grant and says why. The release itself still
 * reaches the host through CI's promotion.
 *
 * The host's API takes the project's own token from `FLEET_TOKEN`, or from the file
 * `FLEET_TOKEN_FILE` names, which is what Calder's secret `placement-token` provides.
 */
export const Placement = Resource<Placement>("Fleet.Placement")

export class PlacementRefused extends Data.TaggedError("PlacementRefused")<{
  readonly project: string
  readonly reasons: ReadonlyArray<string>
}> {
  override get message() {
    return `${this.project}'s placement was refused: ${this.reasons.join("; ")}`
  }
}

export class FleetError extends Data.TaggedError("FleetError")<{
  readonly request: string
  readonly status: number
  readonly body: string
}> {
  override get message() {
    return `${this.request} answered ${this.status}: ${this.body}`
  }
}

const Refusal = Schema.Struct({ reasons: Schema.Array(Schema.String) })

const token = Effect.gen(function*() {
  const direct = yield* Config.option(Config.Redacted("FLEET_TOKEN"))
  if (Option.isSome(direct)) return Redacted.value(direct.value)
  const file = yield* Config.String("FLEET_TOKEN_FILE")
  return (yield* Effect.tryPromise(() => readFile(file, "utf8"))).trim()
})

/** The host's placement API: `http://<host>:18100`, unless `FLEET_URL` says otherwise. */
const base = (host: string) =>
  Config.option(Config.String("FLEET_URL")).pipe(
    Effect.map(Option.getOrElse(() => `http://${host}:18100`)),
  )

const body = (props: PlacementProps) => ({
  ...(props.endpoint === undefined ? {} : { endpoint: props.endpoint }),
  secrets: props.secrets ?? {},
  parameters: props.parameters ?? {},
  memory: props.memory ?? {},
  ...(props.jobs === undefined ? {} : { jobs: props.jobs }),
})

const call = (method: "GET" | "PUT" | "POST" | "DELETE", props: Pick<PlacementProps, "host" | "project">, path: string, payload?: unknown) =>
  Effect.gen(function*() {
    const url = `${yield* base(props.host)}/placements/${props.project}${path}`
    const plain = HttpClientRequest.make(method)(url).pipe(HttpClientRequest.bearerToken(yield* token))
    const request = payload === undefined ? plain : HttpClientRequest.bodyJsonUnsafe(plain, payload)
    const response = yield* HttpClient.execute(request)
    if (response.status === 422) {
      const refusal = yield* HttpClientResponse.schemaBodyJson(Refusal)(response)
      return yield* new PlacementRefused({ project: props.project, reasons: refusal.reasons })
    }
    if (response.status >= 300 && response.status !== 404) {
      return yield* new FleetError({ request: `${method} ${url}`, status: response.status, body: yield* response.text })
    }
    return response
  }).pipe(Effect.provide(FetchHttpClient.layer))

const attributes = (props: PlacementProps): PlacementAttributes => ({
  project: props.project,
  host: props.host,
  url: props.endpoint === undefined ? undefined : `https://${props.endpoint.hostName.toLowerCase()}`,
})

export const PlacementProvider = () =>
  Provider.succeed(
    Placement,
    Placement.Provider.of({
      list: () => Effect.succeed([]),
      diff: Effect.fn(function*({ news, olds }) {
        if (!isResolved(news)) return undefined
        if (news.project !== olds.project || news.host !== olds.host) return { action: "replace" } as const
        // The host checks the placement against the grant now, so a dry run shows a refusal.
        yield* call("POST", news, "/plan", body(news))
        return undefined
      }),
      read: Effect.fn(function*({ olds }) {
        if (olds === undefined) return undefined
        const response = yield* call("GET", olds, "")
        return response.status === 404 ? undefined : attributes(olds)
      }),
      reconcile: Effect.fn(function*({ news }) {
        yield* call("PUT", news, "", body(news))
        return attributes(news)
      }),
      delete: Effect.fn(function*({ olds }) {
        yield* call("DELETE", olds, "")
      }),
    }),
  )
