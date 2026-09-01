#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: ci-workspace-run <source-workspace> <command> [args...]" >&2
  exit 2
fi

source_workspace="$(realpath "$1")"
shift

project_id="${CI_PROJECT_ID:-}"
if [[ ! "$project_id" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "CI_PROJECT_ID must contain only letters, numbers, dots, underscores, and hyphens" >&2
  exit 2
fi

cache_base="${CI_WORKSPACE_CACHE_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/project-ci}"
cache_root="$cache_base/$project_id/$(uname -m)"
workspace="$cache_root/workspace"
preserve_file="$source_workspace/.ci/preserve"

install -d "$workspace"
exec 9>"$cache_root/workspace.lock"
flock 9

rsync_args=(
  --archive
  --delete
)
if [[ -f "$preserve_file" ]]; then
  while IFS= read -r pattern || [[ -n "$pattern" ]]; do
    if [[ -z "$pattern" || "$pattern" == \#* ]]; then
      continue
    fi
    rsync_args+=(--exclude "$pattern")
  done < "$preserve_file"
fi

sync_started=$SECONDS
rsync "${rsync_args[@]}" "$source_workspace/" "$workspace/"
printf '[ci-workspace] source sync: %ss\n' "$((SECONDS - sync_started))"
cd "$workspace"

export CI_CACHE_ROOT="$cache_root"
if [[ -f .ci/environment ]]; then
  # Repositories own their tool-specific environment.
  # shellcheck source=/dev/null
  source .ci/environment
fi

if [[ -x .ci/setup ]]; then
  setup_started=$SECONDS
  .ci/setup
  printf '[ci-workspace] project setup: %ss\n' "$((SECONDS - setup_started))"
fi

child_pid=""
# shellcheck disable=SC2329 # Called indirectly by the signal traps below.
forward_signal() {
  if [[ -n "$child_pid" ]]; then
    kill -s "$1" -- "-$child_pid" 2>/dev/null || true
  fi
}

trap 'forward_signal TERM' TERM
trap 'forward_signal INT' INT

# Keep the project command in its own process group so CI cancellation reaches
# nested task runners and their workers, not only the immediate child.
setsid "$@" &
child_pid=$!

set +e
wait "$child_pid"
status=$?
while kill -0 "$child_pid" 2>/dev/null; do
  wait "$child_pid"
  status=$?
done
set -e

exit "$status"
