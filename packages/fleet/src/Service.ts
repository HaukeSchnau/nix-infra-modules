import { Resource } from "alchemy"
import { Unowned } from "alchemy/AdoptPolicy"
import { isResolved } from "alchemy/Diff"
import * as Provider from "alchemy/Provider"
import { Stack } from "alchemy/Stack"
import { Stage } from "alchemy/Stage"
import * as Config from "effect/Config"
import * as Data from "effect/Data"
import type * as Duration from "effect/Duration"
import * as Effect from "effect/Effect"
import * as Option from "effect/Option"
import * as Redacted from "effect/Redacted"
import * as Schedule from "effect/Schedule"
import * as Schema from "effect/Schema"
import { HttpClientResponse } from "effect/http"
import { baseUrl, Refusal, retryTransient, send } from "./Host.ts"
import type { Providers } from "./Providers.ts"

/** A secret the host decrypts from its own SOPS file, by key, such as `{ sops: "projects/shop/mail-url" }`. */
export interface SopsKey {
  readonly sops: string
}

export interface ServiceProps {
  /** The host that runs the service, such as `core-01`. */
  readonly host: string
  /** The service's name on the host: its grant's name, or that name and a suffix, such as `shop-pr-12`. */
  readonly name: string
  /** What runs: the revision, and the store paths by name, such as `{ bundle, node }`. */
  readonly release: { readonly revision: string; readonly paths: Readonly<Record<string, string>> }
  /** The process. `{bundle}` stands for the release's path `bundle`, and the first word is a file in one of them. */
  readonly command: ReadonlyArray<string>
  /** Runs from the new release before it takes traffic, such as migrations. When it fails, the old release keeps running. */
  readonly prepare?: ReadonlyArray<string>
  /** What `fleet console <service>` runs on the host, with the operator's arguments after it. */
  readonly console?: ReadonlyArray<string>
  /** The service's hostname and who may reach it. Without it the service has no route. */
  readonly endpoint?: { readonly hostName: string; readonly visibility: "public" | "tailnet" }
  /** The path that answers 200 once the process is ready, within `timeoutSec` (60) of a start. Otherwise the host rolls back. */
  readonly health: { readonly path: string; readonly timeoutSec?: number }
  /**
   * A PostgreSQL database of the service's own. Its URL goes into `env` (`DATABASE_URL`), and
   * `majorVersion` must match the host's. Its role may hold `connections` (the host's default, 40),
   * shared by the server, `prepare` and the console. Deleting the service keeps the database
   * unless every spec the host accepted for it set `dropOnDelete`, as previews do; the host then
   * dumps it before dropping it.
   */
  readonly database?: {
    readonly env?: string
    readonly majorVersion?: number
    readonly dropOnDelete?: boolean
    readonly connections?: number
  }
  /** Environment variables. The host adds `HOST`, `PORT`, the database URL and `<SECRET>_FILE`. */
  readonly env?: Readonly<Record<string, string>>
  /**
   * Secrets by variable name: a SOPS key of the host's secrets, or a `Redacted` value the host
   * seals with its age key. The process reads each from the file `<NAME>_FILE` names.
   */
  readonly secrets?: Readonly<Record<string, SopsKey | Redacted.Redacted<string>>>
  /** systemd memory limits, within the grant's share. The service never swaps. */
  readonly memory?: { readonly max: string; readonly high?: string }
}

export interface ServiceAttributes {
  readonly host: string
  readonly name: string
  /** The revision the host runs. */
  readonly revision: string
  /** `https://<hostName>`, when the service has an endpoint. */
  readonly url: string | undefined
  /** The host's public addresses, for DNS records. */
  readonly address: { readonly ipv4: string | undefined; readonly ipv6: string | undefined }
}

export type Service = Resource<"Fleet.Service", ServiceProps, ServiceAttributes, never, Providers>

/**
 * A service the host's service controller runs within the grant the host's configuration gives:
 * its store paths, commands, endpoint, database, environment and secrets. A deploy waits for the
 * host's verdict: the new revision healthy, or the old one kept because `prepare` or the health
 * check failed.
 *
 * The host records which stack, stage and logical ID put the service. It refuses a deploy from
 * another owner unless Alchemy adopts the service, and a deletion from another owner deletes
 * nothing. Deleting stops the service and removes its route; its database stays unless
 * `database.dropOnDelete` is set. `RemovalPolicy.retain()` keeps the service running as well.
 *
 * The host's API takes the grant's token from `FLEET_TOKEN`, or from the file `FLEET_TOKEN_FILE`
 * names. `FLEET_FENCE`, when set, is the deploy lease's fencing token; the host refuses a lower one
 * than it has seen.
 */
export const Service = Resource<Service>("Fleet.Service")

export class ServiceRefused extends Data.TaggedError("ServiceRefused")<{
  readonly service: string
  readonly reasons: ReadonlyArray<string>
}> {
  override get message() {
    return `${this.service} was refused: ${this.reasons.join("; ")}`
  }
}

export class DeployFailed extends Data.TaggedError("DeployFailed")<{
  readonly service: string
  readonly revision: string
  readonly outcome: "failed" | "rolled-back" | "broken" | "no verdict"
  readonly reason: string
}> {
  override get message() {
    const what = {
      "failed": "failed, and the old revision keeps running",
      "rolled-back": "was rolled back",
      "broken": "failed, and restoring the old revision failed too, so the service is down",
      "no verdict": "got no verdict from the host",
    }[this.outcome]
    return `${this.service}: ${this.revision} ${what}: ${this.reason}`
  }
}

class Busy extends Data.TaggedError("Busy")<{ readonly service: string }> {}

/**
 * How long a deploy or deletion waits for the host, while another deploy of the service runs and
 * for its own verdict. It covers the host's longest `prepare` (20 minutes), the health check and
 * realizing.
 */
const deadline: Duration.Input = "40 minutes"

/** How long a plan or a read tries to reach the host before it fails. */
const lookup: Duration.Input = "1 minute"

const Owner = Schema.Struct({ stack: Schema.String, stage: Schema.String, fqn: Schema.String })
type Owner = typeof Owner.Type
const Deploy = Schema.Struct({
  generation: Schema.Number,
  outcome: Schema.Literals(["deploying", "active", "failed", "rolled-back", "broken"]),
  reason: Schema.NullOr(Schema.String),
})
const Status = Schema.Struct({
  owner: Schema.NullOr(Owner),
  revision: Schema.NullOr(Schema.String),
  url: Schema.NullOr(Schema.String),
  address: Schema.Struct({ ipv4: Schema.NullOr(Schema.String), ipv6: Schema.NullOr(Schema.String) }),
  deploys: Schema.Array(Deploy),
})
/** A 404 for a name whose database a deleted service left, with that service's owner. */
const Missing = Schema.Struct({ kept: Schema.optional(Schema.Struct({ owner: Schema.NullOr(Owner) })) })
const Accepted = Schema.Struct({ generation: Schema.Number })
const Plan = Schema.Struct({ changes: Schema.Array(Schema.String) })

/** The service controller's API: `http://<host>:18110`, unless `FLEET_SERVICES_URL` says otherwise. */
const url = (props: Pick<ServiceProps, "host" | "name">, path = "") =>
  Effect.map(baseUrl(props.host, 18110, "FLEET_SERVICES_URL"), (base) => `${base}/services/${props.name}${path}`)

const fence = Config.option(Config.Int("FLEET_FENCE")).pipe(Effect.map(Option.getOrUndefined))

const body = (props: ServiceProps) => ({
  release: props.release,
  command: props.command,
  ...(props.prepare === undefined ? {} : { prepare: props.prepare }),
  ...(props.console === undefined ? {} : { console: props.console }),
  ...(props.endpoint === undefined ? {} : { endpoint: props.endpoint }),
  health: props.health,
  ...(props.database === undefined ? {} : { database: props.database }),
  env: props.env ?? {},
  secrets: Object.fromEntries(
    Object.entries(props.secrets ?? {}).map(([name, secret]) => [
      name,
      Redacted.isRedacted(secret) ? { value: Redacted.value(secret) } : { sops: secret.sops },
    ]),
  ),
  memory: props.memory ?? {},
})

const refused = (props: ServiceProps) => (response: HttpClientResponse.HttpClientResponse) =>
  Effect.flatMap(
    HttpClientResponse.schemaBodyJson(Refusal)(response),
    (refusal) => new ServiceRefused({ service: props.name, reasons: refusal.reasons }),
  )

/**
 * A request that waits, up to `window`, while another deploy of the service runs (423) and while
 * the host can't be reached.
 */
const sendWaiting = (props: Pick<ServiceProps, "name">, request: ReturnType<typeof send>, window: Duration.Input = deadline) =>
  retryTransient(
    request.pipe(Effect.filterOrFail((response) => response.status !== 423, () => new Busy({ service: props.name }))),
    window,
    (error) => error._tag === "Busy",
  )

/** What the host knows of the name: the service that runs, or the owner of a database a deleted one left. */
const lookUp = (props: Pick<ServiceProps, "host" | "name">, window: Duration.Input = deadline) =>
  Effect.gen(function*() {
    const response = yield* sendWaiting(props, send("GET", yield* url(props)), window)
    if (response.status !== 404) return { running: yield* HttpClientResponse.schemaBodyJson(Status)(response) }
    return { kept: (yield* HttpClientResponse.schemaBodyJson(Missing)(response)).kept }
  })

const status = (props: Pick<ServiceProps, "host" | "name">) => Effect.map(lookUp(props), (found) => found.running)

const attributes = (props: Pick<ServiceProps, "host" | "name">, running: typeof Status.Type): ServiceAttributes => ({
  host: props.host,
  name: props.name,
  revision: running.revision ?? "",
  url: running.url ?? undefined,
  address: { ipv4: running.address.ipv4 ?? undefined, ipv6: running.address.ipv6 ?? undefined },
})

const sameOwner = (a: Owner | null, b: Owner) => a !== null && a.stack === b.stack && a.stage === b.stage && a.fqn === b.fqn

/** PUTs the spec and waits until the host reports its generation's outcome. */
const deploy = (props: ServiceProps, owner: Owner, adopt: boolean) =>
  Effect.gen(function*() {
    const payload = { ...body(props), owner, adopt, fence: yield* fence }
    const response = yield* sendWaiting(props, send("PUT", yield* url(props), { payload, handled: [422, 423] }))
    if (response.status === 422) return yield* refused(props)(response)
    if (response.status === 202) {
      const { generation } = yield* HttpClientResponse.schemaBodyJson(Accepted)(response)
      const outcome = (running: typeof Status.Type | undefined) =>
        running?.deploys.find((entry) => entry.generation === generation)
      const settled = yield* status(props).pipe(
        Effect.repeat({
          schedule: Schedule.spaced("250 millis"),
          until: (running) => outcome(running)?.outcome !== "deploying",
        }),
        Effect.timeoutOrElse({
          duration: deadline,
          orElse: () =>
            Effect.fail(
              new DeployFailed({
                service: props.name,
                revision: props.release.revision,
                outcome: "no verdict",
                reason: `generation ${generation} was still deploying after ${deadline}`,
              }),
            ),
        }),
      )
      const entry = outcome(settled)
      if (entry === undefined || entry.outcome === "deploying") {
        return yield* Effect.die(`the host lost ${props.name}'s generation ${generation}`)
      }
      if (entry.outcome !== "active") {
        return yield* new DeployFailed({
          service: props.name,
          revision: props.release.revision,
          outcome: entry.outcome,
          reason: entry.reason ?? "no reason given",
        })
      }
    }
    const running = yield* status(props)
    if (running === undefined) return yield* Effect.die(`the host lost ${props.name}`)
    return attributes(props, running)
  })

export const ServiceProvider = () =>
  Provider.effect(
    Service,
    Effect.gen(function*() {
      const stack = yield* Stack
      const stage = yield* Stage
      const ownerOf = (fqn: string): Owner => ({ stack: stack.name, stage, fqn })
      return Service.Provider.of({
        list: () => Effect.succeed([]),
        diff: Effect.fn(function*({ news, olds }) {
          if (!isResolved(news)) return undefined
          if (news.name !== olds.name || news.host !== olds.host) return { action: "replace" } as const
          // The host compares the spec with what it runs, so an unchanged service needs no deploy and
          // a refusal shows in a dry run.
          const request = send("POST", yield* url(news, "/plan"), { payload: body(news), handled: [422] })
          const response = yield* sendWaiting(news, request, lookup)
          if (response.status === 422) return yield* refused(news)(response)
          const plan = yield* HttpClientResponse.schemaBodyJson(Plan)(response)
          return { action: plan.changes.length === 0 ? "noop" : "update" } as const
        }),
        read: Effect.fn(function*({ fqn, olds }) {
          if (olds === undefined) return undefined
          const found = yield* lookUp(olds, lookup)
          // A service another stack, stage or logical ID put is not this resource's to change, and
          // neither is the database such a service left behind when it was deleted.
          if (found.running !== undefined) {
            const attrs = attributes(olds, found.running)
            return sameOwner(found.running.owner, ownerOf(fqn)) ? attrs : Unowned(attrs)
          }
          if (found.kept === undefined) return undefined
          const attrs = { host: olds.host, name: olds.name, revision: "", url: undefined, address: { ipv4: undefined, ipv6: undefined } }
          return sameOwner(found.kept.owner, ownerOf(fqn)) ? attrs : Unowned(attrs)
        }),
        reconcile: Effect.fn(function*({ fqn, news, olds, output }) {
          // An output without olds means Alchemy adopts what `read` found: the host then lets this
          // stack take the service over. Alchemy also passes one when a create resumes after an
          // interruption, from the attributes it checkpointed after that read (Apply.ts,
          // `let attr = node.state?.attr` in the create branch, alchemy 2.0.0-beta.83). Either way
          // the read already passed the ownership check, or ran with `--adopt`.
          return yield* deploy(news, ownerOf(fqn), output !== undefined && olds === undefined)
        }),
        delete: Effect.fn(function*({ fqn, olds }) {
          const payload = { owner: ownerOf(fqn), fence: yield* fence }
          yield* sendWaiting(olds, send("DELETE", yield* url(olds), { payload, handled: [423] }))
        }),
      })
    }),
  )
