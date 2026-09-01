{
  pkgs,
  runner,
}:

{
  ci-workspace-runner =
    pkgs.runCommand "ci-workspace-runner-check"
      {
        nativeBuildInputs = [ runner ];
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

        touch "$out"
      '';
}
