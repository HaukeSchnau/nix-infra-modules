import * as Config from "effect/Config";
import type * as Duration from "effect/Duration";
import * as Effect from "effect/Effect";
import * as Option from "effect/Option";
import * as Predicate from "effect/Predicate";
import * as Redacted from "effect/Redacted";
import * as Schedule from "effect/Schedule";
import * as Schema from "effect/Schema";
import { FetchHttpClient, HttpClient, HttpClientError, HttpClientRequest } from "effect/http";
import { readFile } from "node:fs/promises";

export class FleetError extends Schema.TaggedError<FleetError, { readonly brand: unique symbol }>()(
  "FleetError",
  {
    request: Schema.String,
    status: Schema.Int,
    body: Schema.String,
  },
) {
  override get message() {
    return `${this.request} answered ${this.status}: ${this.body}`;
  }
}

export class TokenFileUnreadable extends Schema.TaggedError<
  TokenFileUnreadable,
  { readonly brand: unique symbol }
>()("TokenFileUnreadable", { file: Schema.String, cause: Schema.Defect() }) {
  override get message() {
    return `FLEET_TOKEN_FILE names ${this.file}, which can't be read: ${String(this.cause)}`;
  }
}

/** What a host answers with 422: every reason it refused a request. */
export const Refusal = Schema.Struct({ reasons: Schema.Array(Schema.String) });

/** The token from `FLEET_TOKEN`, or from the file `FLEET_TOKEN_FILE` names. */
const token = Effect.gen(function* () {
  const direct = yield* Config.option(Config.Redacted("FLEET_TOKEN"));

  if (Option.isSome(direct)) return Redacted.value(direct.value);
  const file = yield* Config.String("FLEET_TOKEN_FILE");

  const contents = yield* Effect.tryPromise({
    try: () => readFile(file, "utf8"),
    catch: (cause) => TokenFileUnreadable.make({ file, cause }),
  });

  return contents.trim();
});

/** `http://<host>:<port>`, unless the environment variable `override` names another base URL. */
export const baseUrl = (host: string, port: number, override: string) =>
  Config.option(Config.String(override)).pipe(
    Effect.map(Option.getOrElse(() => `http://${host}:${port}`)),
  );

/**
 * A request to a host's API with the token. It fails with `FleetError` on a status of 300 or more,
 * except 404 and the ones in `handled`, which the caller reads from the response.
 */
export const send = (
  method: "GET" | "PUT" | "POST" | "DELETE",
  url: string,
  options: {
    readonly payload?: unknown;
    readonly headers?: Readonly<Record<string, string>>;
    readonly handled?: ReadonlyArray<number>;
  } = {},
) =>
  Effect.gen(function* () {
    const bearer = yield* token;

    const plain = HttpClientRequest.make(method)(url).pipe(
      HttpClientRequest.bearerToken(bearer),
      HttpClientRequest.setHeaders(options.headers ?? {}),
    );

    const request =
      options.payload === undefined
        ? plain
        : HttpClientRequest.bodyJsonUnsafe(plain, options.payload);

    const response = yield* HttpClient.execute(request);

    if (
      response.status >= 300 &&
      response.status !== 404 &&
      options.handled?.includes(response.status) !== true
    ) {
      return yield* FleetError.make({
        request: `${method} ${url}`,
        status: response.status,
        body: yield* response.text,
      });
    }

    return response;
  }).pipe(Effect.provide(FetchHttpClient.layer));

/**
 * Retries every 2 seconds, for up to `duration`, while the host can't be reached or `also` holds
 * for the error.
 */
export const retryTransient = <A, E, R>(
  effect: Effect.Effect<A, E, R>,
  duration: Duration.Input,
  also: (error: E) => boolean = () => false,
) =>
  Effect.retry(effect, {
    while: (error: E) =>
      (HttpClientError.isHttpClientError(error) &&
        Predicate.isTagged(error.reason, "TransportError")) ||
      also(error),
    schedule: Schedule.spaced("2 seconds").pipe(Schedule.upTo({ duration })),
  });
