import { Resource } from "alchemy";
import { isResolved } from "alchemy/Diff";
import * as Provider from "alchemy/Provider";
import * as Effect from "effect/Effect";
import * as Schema from "effect/Schema";
import { HttpClientResponse } from "effect/http";
import { baseUrl, Refusal, send } from "./Host.ts";
import type { Providers } from "./Providers.ts";

/** When a job runs: a systemd calendar such as `*-*-* 04:00`, or an interval such as `30min`. */
export type JobSchedule =
  | { readonly calendar: string; readonly randomizedDelaySec?: string }
  | { readonly interval: string; readonly randomizedDelaySec?: string };

export interface PlacementProps {
  /** The project, as the host's configuration names it. */
  readonly project: string;
  /** The host that runs the release, such as `srv-2`. */
  readonly host: string;
  /** The release's hostname and who may reach it. Without it the release has no route. */
  readonly endpoint?: { readonly hostName: string; readonly visibility: "public" | "tailnet" };
  /** Secret names the release declares, each bound to a SOPS key under the project's prefix. */
  readonly secrets?: Readonly<Record<string, string>>;
  /** Values of the release's parameters, on top of the host's. */
  readonly parameters?: Readonly<Record<string, Schema.Json | undefined>>;
  /** systemd memory limits of the release's service, up to the grant's ceiling. */
  readonly memory?: { readonly high?: string; readonly max?: string; readonly swapMax?: string };
  /** New schedules for jobs the host already runs, by name; the others keep the host's. */
  readonly jobs?: Readonly<Record<string, JobSchedule>>;
}

export interface PlacementAttributes {
  readonly project: string;
  readonly host: string;
  /** `https://<hostName>`, when the placement has an endpoint. */
  readonly url: string | undefined;
}

export type Placement = Resource<
  "Fleet.Placement",
  PlacementProps,
  PlacementAttributes,
  never,
  Providers
>;

/**
 * Where and how a release runs on a host, within the grant the host's configuration gives the
 * project. The host refuses a placement outside the grant and says why. The release itself still
 * reaches the host through CI's promotion.
 *
 * The host's API takes the project's own token from `FLEET_TOKEN`, or from the file
 * `FLEET_TOKEN_FILE` names, which is what Calder's secret `placement-token` provides.
 */
export const Placement = Resource<Placement>("Fleet.Placement");

export class PlacementRefused extends Schema.TaggedError<
  PlacementRefused,
  { readonly brand: unique symbol }
>()("PlacementRefused", {
  project: Schema.String,
  reasons: Schema.Array(Schema.String),
}) {
  override get message() {
    return `${this.project}'s placement was refused: ${this.reasons.join("; ")}`;
  }
}

// JSON leaves out the properties that are undefined.
const body = (props: PlacementProps) => ({
  endpoint: props.endpoint,
  secrets: props.secrets ?? {},
  parameters: props.parameters ?? {},
  memory: props.memory ?? {},
  jobs: props.jobs,
});

const call = (
  method: "GET" | "PUT" | "POST" | "DELETE",
  props: Pick<PlacementProps, "host" | "project">,
  path: string,
  payload?: ReturnType<typeof body>,
) =>
  Effect.gen(function* () {
    // The host's placement API: `http://<host>:18100`, unless `FLEET_URL` says otherwise.
    const url = `${yield* baseUrl(props.host, 18100, "FLEET_URL")}/placements/${props.project}${path}`;
    const response = yield* send(method, url, { payload, handled: [422] });

    if (response.status === 422) {
      const refusal = yield* HttpClientResponse.schemaBodyJson(Refusal)(response);

      return yield* PlacementRefused.make({ project: props.project, reasons: refusal.reasons });
    }

    return response;
  });

const attributes = (props: PlacementProps): PlacementAttributes => ({
  project: props.project,
  host: props.host,
  url:
    props.endpoint === undefined ? undefined : `https://${props.endpoint.hostName.toLowerCase()}`,
});

export const PlacementProvider = () =>
  Provider.succeed(
    Placement,
    Placement.Provider.of({
      list: () => Effect.succeed([]),
      diff: Effect.fn(function* ({ news, olds }) {
        if (!isResolved(news)) return undefined;

        if (news.project !== olds.project || news.host !== olds.host)
          return { action: "replace" } as const;
        // The host checks the placement against the grant now, so a dry run shows a refusal.
        yield* call("POST", news, "/plan", body(news));

        return undefined;
      }),
      read: Effect.fn(function* ({ olds }) {
        if (olds === undefined) return undefined;
        const response = yield* call("GET", olds, "");

        return response.status === 404 ? undefined : attributes(olds);
      }),
      reconcile: Effect.fn(function* ({ news }) {
        yield* call("PUT", news, "", body(news));

        return attributes(news);
      }),
      delete: Effect.fn(function* ({ olds }) {
        yield* call("DELETE", olds, "");
      }),
    }),
  );
