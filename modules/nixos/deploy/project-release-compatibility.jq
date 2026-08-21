def normalized_health:
  (. // {}) as $health
  | {
      paths: ($health.paths // ["/"]),
      startupTimeoutSec: ($health.startupTimeoutSec // 60),
      intervalSec: ($health.intervalSec // 2),
      requestTimeoutSec: ($health.requestTimeoutSec // 5)
    };

def normalized_ingress:
  (. // {}) as $ingress
  | {
      compression: ($ingress.compression // false),
      requestBodyMaxBytes: ($ingress.requestBodyMaxBytes // null),
      responseHeaders: ($ingress.responseHeaders // {}),
      redirects: (($ingress.redirects // []) | map(
        . as $redirect
        | {
            from: $redirect.from,
            to: $redirect.to,
            status: (
              if $redirect.status != null then $redirect.status
              elif $redirect.permanent == false then 307
              else 308
              end
            )
          }
      )),
      cacheRules: (($ingress.cacheRules // []) | map({paths, value}))
    };

def normalized_tasks:
  (. // {})
  | with_entries(
      .key as $name
      | .value = {
          action: (.value.action // $name),
          dependsOn: (.value.dependsOn // []),
          secrets: (.value.secrets // []),
          timeoutSec: (.value.timeoutSec // 900)
        }
    );

def normalized_jobs($managed_jobs):
  (. // {})
  | with_entries(
      select(.key as $name | $managed_jobs | index($name))
      | .key as $name
      | .value = {
          action: (.value.action // $name),
          secrets: (.value.secrets // [])
        }
    );

def normalized_oci:
  (. // {})
  | with_entries(
      .value = {
        image: .value.image,
        command: (.value.command // []),
        ports: (
          (.value.ports // {})
          | with_entries(.value = {
              containerPort: .value.containerPort,
              protocol: (.value.protocol // "tcp")
            })
        )
      }
    );

def release_contract($managed_jobs):
  . as $descriptor
  | ($descriptor.release // {}) as $release
  | ($release.backend // "service") as $backend
  | {
      schemaVersion: $descriptor.schemaVersion,
      project: $descriptor.project,
      release: {
        backend: $backend,
        action: ($release.action // (if $backend == "service" then "web" else null end)),
        executable: ($release.executable // (if $backend == "service" then "project-release-runtime" else null end)),
        activationExecutable: ($release.activationExecutable // null),
        stateDirectories: ($release.stateDirectories // []),
        health: ($release.health | normalized_health),
        ingress: ($release.ingress | normalized_ingress),
        maintenanceJobs: ($release.maintenanceJobs | normalized_jobs($managed_jobs)),
        preDeployTasks: ($release.preDeployTasks | normalized_tasks),
        ociAuxiliaries: ($release.ociAuxiliaries | normalized_oci)
      }
    };

def parameter_type_matches($definition; $value):
  ($definition.type // "string") as $type
  | if $type == "boolean" then $value | type == "boolean"
    elif $type == "integer" then ($value | type == "number" and floor == .)
    elif $type == "number" then $value | type == "number"
    else $value | type == "string"
    end;

($host[0]) as $host_policy
| ($candidate[0]) as $candidate_descriptor
| ($host_policy.descriptor | release_contract($host_policy.managedJobs)) as $expected_contract
| ($candidate_descriptor | release_contract($host_policy.managedJobs)) as $candidate_contract
| reduce (($candidate_descriptor.parameters // {}) | to_entries[]) as $parameter (
    {values: {}, reasons: []};
    ($parameter.value // {}) as $definition
    | ($parameter.key) as $name
    | if $host_policy.bindings.parameters | has($name) then
        ($host_policy.bindings.parameters[$name]) as $value
        | if parameter_type_matches($definition; $value) then
            .values[$name] = $value
          else
            .reasons += ["parameter " + $name + " binding does not match type " + ($definition.type // "string")]
          end
      elif $definition | has("default") then
        .values[$name] = $definition.default
      elif ($definition.required // true) then
        .reasons += ["missing required parameter binding: " + $name]
      else
        .values[$name] = null
      end
  ) as $parameters
| reduce (($candidate_descriptor.secrets // {}) | to_entries[]) as $secret (
    {values: {}, reasons: []};
    ($secret.key) as $name
    | if $host_policy.bindings.secrets | index($name) then
        .values[$name] = $name
      elif ($secret.value.required // true) then
        .reasons += ["missing required Secret binding: " + $name]
      else
        .
      end
  ) as $secrets
| ([
    if $candidate_contract == $expected_contract then empty
    else "Release topology differs from the host-compatible contract"
    end
  ] + $parameters.reasons + $secrets.reasons) as $reasons
| {
    compatible: ($reasons | length == 0),
    reasons: $reasons,
    parameters: $parameters.values,
    secrets: $secrets.values,
    expectedContract: $expected_contract,
    candidateContract: $candidate_contract
  }
