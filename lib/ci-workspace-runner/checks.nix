{
  pkgs,
  runner,
}:

{
  ci-workspace-runner =
    pkgs.runCommand "ci-workspace-runner-check"
      {
        nativeBuildInputs = [
          pkgs.procps
          runner
        ];
      }
      ''
        source="$TMPDIR/source"
        cache="$TMPDIR/cache"
        workspace="$cache/example/$(uname -m)/workspace"

        mkdir -p "$source/.ci"
        printf 'persistent/\n' > "$source/.ci/preserve"
        printf 'export PROJECT_VALUE=from-environment\n' > "$source/.ci/environment"
        printf '#!/usr/bin/env bash\nset -euo pipefail\nprintf setup > setup.txt\n' > "$source/.ci/setup"
        chmod +x "$source/.ci/setup"
        printf first > "$source/current.txt"
        printf stale > "$source/stale.txt"

        CI_PROJECT_ID=example CI_WORKSPACE_CACHE_ROOT="$cache" \
          ci-workspace-run "$source" sh -c \
          'test "$PROJECT_VALUE" = from-environment && test "$(cat setup.txt)" = setup && test "$(cat current.txt)" = first'

        mkdir -p "$workspace/persistent"
        printf retained > "$workspace/persistent/marker"
        rm "$source/stale.txt"
        printf second > "$source/current.txt"

        CI_PROJECT_ID=example CI_WORKSPACE_CACHE_ROOT="$cache" \
          ci-workspace-run "$source" sh -c \
          'test "$(cat current.txt)" = second && test ! -e stale.txt && test "$(cat persistent/marker)" = retained'

        if CI_PROJECT_ID='../escape' CI_WORKSPACE_CACHE_ROOT="$cache" \
          ci-workspace-run "$source" true; then
          echo "invalid project identifier unexpectedly succeeded" >&2
          exit 1
        fi

        CI_PROJECT_ID=example CI_WORKSPACE_SLOT=second CI_WORKSPACE_CACHE_ROOT="$cache" \
          ci-workspace-run "$source" sh -c \
          'test "$CI_CACHE_ROOT" = "'"$cache"'/example/'"$(uname -m)"'/second"'
        test -f "$cache/example/$(uname -m)/second/workspace/current.txt"

        if CI_PROJECT_ID=example CI_WORKSPACE_SLOT='../escape' CI_WORKSPACE_CACHE_ROOT="$cache" \
          ci-workspace-run "$source" true; then
          echo "invalid workspace slot unexpectedly succeeded" >&2
          exit 1
        fi

        child_pid_file="$TMPDIR/child.pid"
        CHILD_PID_FILE="$child_pid_file" CI_PROJECT_ID=example CI_WORKSPACE_CACHE_ROOT="$cache" \
          ci-workspace-run "$source" sh -c \
          'setsid sleep 30 & child_pid=$!; printf "%s\n" "$child_pid" > "$CHILD_PID_FILE"; wait "$child_pid"' &
        runner_pid=$!

        for _ in $(seq 1 100); do
          if test -s "$child_pid_file"; then
            break
          fi
          sleep 0.01
        done
        test -s "$child_pid_file"
        child_pid="$(cat "$child_pid_file")"

        # Gitea can terminate the outer Nix process without delivering a
        # catchable signal to the workspace runner itself.
        kill -KILL "$runner_pid"
        set +e
        wait "$runner_pid"
        runner_status=$?
        set -e

        test "$runner_status" -eq 137
        for _ in $(seq 1 100); do
          if ! kill -0 "$child_pid" 2>/dev/null; then
            break
          fi
          sleep 0.01
        done
        if kill -0 "$child_pid" 2>/dev/null; then
          echo "cancelled command left child process $child_pid running" >&2
          exit 1
        fi

        if CI_PROJECT_ID=example CI_CANCEL_GRACE_SECONDS=soon CI_WORKSPACE_CACHE_ROOT="$cache" \
          ci-workspace-run "$source" true; then
          echo "invalid cancel grace period unexpectedly succeeded" >&2
          exit 1
        fi

        # TypeScript 7's native tsc catches TERM and keeps checking. Ignored
        # signals survive exec, so the command's children, one of them in its
        # own session, keep running after TERM as well.
        pids_file="$TMPDIR/term-ignoring.pids"
        PIDS_FILE="$pids_file" CI_CANCEL_GRACE_SECONDS=1 CI_PROJECT_ID=example CI_WORKSPACE_CACHE_ROOT="$cache" \
          ci-workspace-run "$source" sh -c \
          'trap "" TERM; sleep 300 & same=$!; setsid sleep 300 & own=$!; echo "$$ $same $own" > "$PIDS_FILE"; wait' &
        runner_pid=$!

        for _ in $(seq 1 100); do
          if test -s "$pids_file"; then
            break
          fi
          sleep 0.01
        done
        test -s "$pids_file"
        read -r -a term_ignoring_pids < "$pids_file"

        kill -TERM "$runner_pid"
        for _ in $(seq 1 100); do
          if ! kill -0 "$runner_pid" 2>/dev/null; then
            break
          fi
          sleep 0.1
        done
        if kill -0 "$runner_pid" 2>/dev/null; then
          echo "cancelled runner kept waiting for a command that ignores TERM" >&2
          exit 1
        fi
        set +e
        wait "$runner_pid"
        runner_status=$?
        set -e

        test "$runner_status" -eq 137
        for pid in "''${term_ignoring_pids[@]}"; do
          if ps -o stat= -p "$pid" | grep -q '^[^Z]'; then
            echo "cancelled command left TERM-ignoring process $pid running" >&2
            exit 1
          fi
        done

        touch "$out"
      '';
}
