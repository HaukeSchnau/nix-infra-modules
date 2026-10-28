import * as Config from "effect/Config"
import * as Data from "effect/Data"
import * as Effect from "effect/Effect"
import * as Option from "effect/Option"
import * as Redacted from "effect/Redacted"
import * as Schema from "effect/Schema"
import { FetchHttpClient, HttpClient, HttpClientRequest } from "effect/http"
import { readFile } from "node:fs/promises"

export class FleetError extends Data.TaggedError("FleetError")<{
  readonly request: string
  readonly status: number
  readonly body: string
}> {
  override get message() {
    return `${this.request} answered ${this.status}: ${this.body}`
  }
}

/** What a host answers with 422: every reason it refused a request. */
export const Refusal = Schema.Struct({ reasons: Schema.Array(Schema.String) })

/** The token from `FLEET_TOKEN`, or from the file `FLEET_TOKEN_FILE` names. */
const token = Effect.gen(function*() {
  const direct = yield* Config.option(Config.Redacted("FLEET_TOKEN"))
  if (Option.isSome(direct)) return Redacted.value(direct.value)
  const file = yield* Config.String("FLEET_TOKEN_FILE")
  return (yield* Effect.tryPromise(() => readFile(file, "utf8"))).trim()
})

/** `http://<host>:<port>`, unless the environment variable `override` names another base URL. */
export const baseUrl = (host: string, port: number, override: string) =>
  Config.option(Config.String(override)).pipe(Effect.map(Option.getOrElse(() => `http://${host}:${port}`)))

/**
 * A request to a host's API with the token. It fails with `FleetError` on a status of 300 or more,
 * except 404 and the ones in `handled`, which the caller reads from the response.
 */
export const send = (
  method: "GET" | "PUT" | "POST" | "DELETE",
  url: string,
  options: { readonly payload?: unknown; readonly headers?: Readonly<Record<string, string>>; readonly handled?: ReadonlyArray<number> } = {},
) =>
  Effect.gen(function*() {
    const plain = HttpClientRequest.make(method)(url).pipe(
      HttpClientRequest.bearerToken(yield* token),
      HttpClientRequest.setHeaders(options.headers ?? {}),
    )
    const request = options.payload === undefined ? plain : HttpClientRequest.bodyJsonUnsafe(plain, options.payload)
    const response = yield* HttpClient.execute(request)
    if (response.status >= 300 && response.status !== 404 && !options.handled?.includes(response.status)) {
      return yield* new FleetError({ request: `${method} ${url}`, status: response.status, body: yield* response.text })
    }
    return response
  }).pipe(Effect.provide(FetchHttpClient.layer))
