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
      streamCloseDelaySec: ($ingress.streamCloseDelaySec // null),
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
          failureMode: (.value.failureMode // "fail"),
          secrets: (.value.secrets // []),
          timeoutSec: (.value.timeoutSec // 900)
        }
    );

def task_plan($tasks):
  reduce range(0; (($tasks | length) + 1)) as $_ (
    {order: [], remaining: ($tasks | keys | sort)};
    . as $state
    | [
        $state.remaining[]
        | . as $name
        | select((($tasks[$name].dependsOn - $state.order) | length) == 0)
      ] as $ready
    | .order += $ready
    | .remaining -= $ready
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

def normalized_commands:
  (. // {})
  | with_entries(
      .key as $name
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

def release_contract:
  . as $descriptor
  | ($descriptor.release // {}) as $release
  | ($release.backend // "service") as $backend
  | {
      schemaVersion: $descriptor.schemaVersion,
      project: $descriptor.project,
      release: ({
        backend: $backend,
        action: ($release.action // (if $backend == "service" then "web" else null end)),
        executable: ($release.executable // (if $backend == "service" then "project-release-runtime" else null end)),
        stateDirectories: ($release.stateDirectories // []),
        ingress: ($release.ingress | normalized_ingress),
        ociAuxiliaries: ($release.ociAuxiliaries | normalized_oci)
      } + if $backend == "static" then {
        activationExecutable: ($release.activationExecutable // null)
      } else {} end)
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
| ($host_policy.descriptor | release_contract) as $expected_contract
| ($candidate_descriptor | release_contract) as $candidate_contract
| ($candidate_descriptor.release.health | normalized_health) as $health
| ($candidate_descriptor.release.preDeployTasks | normalized_tasks) as $tasks
| ($candidate_descriptor.release.maintenanceJobs | normalized_jobs($host_policy.managedJobs)) as $jobs
| ($candidate_descriptor.release.commands | normalized_commands) as $commands
| (task_plan($tasks)) as $task_plan
| [
    $tasks
    | to_entries[]
    | .key as $name
    | .value.dependsOn[]
    | . as $dependency
    | select($tasks | has($dependency) | not)
    | "pre-deploy task " + $name + " depends on undeclared task: " + $dependency
  ] as $missing_task_dependencies
| [
    $tasks
    | to_entries[]
    | .key as $name
    | .value.secrets[]
    | . as $secret
    | select(($candidate_descriptor.secrets // {}) | has($secret) | not)
    | "pre-deploy task " + $name + " references undeclared Secret: " + $secret
  ] as $missing_task_secrets
| [
    $host_policy.managedJobs[]
    | . as $name
    | select($jobs | has($name) | not)
    | "host-managed maintenance job is not declared by the candidate: " + $name
  ] as $missing_managed_jobs
| [
    $jobs
    | to_entries[]
    | .key as $name
    | .value.secrets[]
    | . as $secret
    | select(($candidate_descriptor.secrets // {}) | has($secret) | not)
    | "maintenance job " + $name + " references undeclared Secret: " + $secret
  ] as $missing_job_secrets
| [
    $commands
    | to_entries[]
    | .key as $name
    | .value.secrets[]
    | . as $secret
    | select(($candidate_descriptor.secrets // {}) | has($secret) | not)
    | "command " + $name + " references undeclared Secret: " + $secret
  ] as $missing_command_secrets
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
  ]
  + $missing_task_dependencies
  + $missing_task_secrets
  + $missing_managed_jobs
  + $missing_job_secrets
  + $missing_command_secrets
  + (if ($task_plan.remaining | length) == 0 then [] else ["pre-deploy task dependency graph contains a cycle"] end)
  + $parameters.reasons
  + $secrets.reasons) as $reasons
| {
    compatible: ($reasons | length == 0),
    reasons: $reasons,
    parameters: $parameters.values,
    secrets: $secrets.values,
    releasePlan: {
      activationExecutable: ($candidate_descriptor.release.activationExecutable // null),
      commands: $commands,
      health: $health,
      maintenanceJobs: $jobs,
      preDeployTasks: $tasks,
      preDeployOrder: $task_plan.order
    },
    expectedContract: $expected_contract,
    candidateContract: $candidate_contract
  }
