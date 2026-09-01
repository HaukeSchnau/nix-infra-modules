# CI workspace runner

`packages.ci-workspace-runner` provides the `ci-workspace-run` command. It runs
project QA in a locked, persistent workspace instead of reinstalling unchanged
dependencies for every CI job.

The runner deliberately has no knowledge of a language, package manager, or
task system. A repository owns the integration through three optional files:

- `.ci/preserve` lists rsync exclude patterns for state that should survive
  source synchronization, such as dependency or compiler caches.
- `.ci/environment` exports project-specific environment variables.
- `.ci/setup` prepares the synchronized workspace when needed.

Set `CI_PROJECT_ID` to a stable identifier and invoke the runner with a source
checkout followed by any command:

```bash
ci-workspace-run "$GITHUB_WORKSPACE" just qa
```

The cache defaults to
`${XDG_CACHE_HOME:-$HOME/.cache}/project-ci/<project>/<architecture>`. Override
its base with `CI_WORKSPACE_CACHE_ROOT`. Jobs for the same project and machine
serialize on a file lock so a workspace is never mutated while another command
uses it.

The project command runs below a small supervisor. Cancellation is forwarded to
its complete process group, including when the CI executor kills the runner's
outer process before shell traps can run.

The repository remains responsible for its QA graph. The runner only provides
workspace reuse, synchronization, locking, and lifecycle hooks.
