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

def is_required:
  if has("required") then .required else true end;

def release_requirements:
  (.requirements // {}) | with_entries(select((.value.realizations // ["development", "release"]) | index("release")));

def with_requirement_secrets:
  . as $descriptor
  | ($descriptor | release_requirements) as $requirements
  | .secrets = (
      ((.secrets // {}) | with_entries(select(
        .key as $name
        | (($descriptor.requirements // {}) | has($name) | not) or ($requirements | has($name))
      )))
      + ($requirements | with_entries(select(.value.kind == "secret")
        | .value = {required: (.value | is_required), description: (.value.description // "")}))
    );

def nonempty_string: type == "string" and length > 0;
def absolute_path: type == "string" and startswith("/");
def binding_shape:
  if .kind == "postgresql" then
      ((keys - ["kind", "majorVersion", "host", "port", "database", "user", "url", "dataDirectory"]) | length == 0)
      and (.port | type == "number" and floor == . and . >= 1 and . <= 65535)
      and ([.host, .database, .user, .url] | all(nonempty_string))
      and (if has("dataDirectory") then (.dataDirectory | absolute_path) else true end)
    elif .kind == "directory" then
      ((keys - ["kind", "path", "persistent"]) | length == 0)
      and (.path | absolute_path) and (.persistent | type == "boolean")
    elif .kind == "secret" then
      ((keys - ["kind", "credential"]) | length == 0)
      and (.credential | type == "string" and test("^[A-Za-z0-9_.-]+$") and . != "." and . != "..")
    else false end;

def bind_requirements($available; $secrets):
  reduce (release_requirements | to_entries[]) as $entry (
    {values: {}, reasons: []};
    $entry.key as $name
    | $entry.value as $requirement
    | $available[$name] as $binding
    | if $binding == null then
        if ($requirement | is_required) then .reasons += ["missing required resource binding: " + $name] else . end
      elif ($binding | type) != "object" then
        .reasons += ["resource " + $name + " binding must be an object"]
      elif $binding.kind != $requirement.kind then
        .reasons += ["resource " + $name + " requires kind " + $requirement.kind]
      elif $requirement.kind == "postgresql" and (($requirement.majorVersions // [$requirement.majorVersion]) | index($binding.majorVersion) | not) then
        .reasons += ["resource " + $name + " requires PostgreSQL " + (($requirement.majorVersions // [$requirement.majorVersion]) | tostring)]
      elif $requirement.kind == "directory" and $binding.persistent != (if $requirement | has("persistent") then $requirement.persistent else true end) then
        .reasons += ["resource " + $name + " has incompatible persistence"]
      elif ($binding | binding_shape | not) then
        .reasons += ["resource " + $name + " has malformed binding fields"]
      elif $requirement.kind == "secret" and (($secrets | has($binding.credential // "")) | not) then
        .reasons += ["resource " + $name + " requires a bound credential"]
      else .values[$name] = $binding
      end
  );

($host[0]) as $host_policy
| ($candidate[0] | with_requirement_secrets) as $candidate_descriptor
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
      elif ($definition | is_required) then
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
      elif ($secret.value | is_required) then
        .reasons += ["missing required Secret binding: " + $name]
      else
        .
      end
  ) as $secrets
| ($candidate_descriptor | bind_requirements(($host_policy.bindings.resources // {}); $secrets.values)) as $resources
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
  + $secrets.reasons
  + $resources.reasons) as $reasons
| {
    compatible: ($reasons | length == 0),
    reasons: $reasons,
    parameters: $parameters.values,
    secrets: $secrets.values,
    bindings: $resources.values,
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
