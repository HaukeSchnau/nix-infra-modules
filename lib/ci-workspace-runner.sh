#!/usr/bin/env bash
set -euo pipefail

supervise_command() {
  local child_pid="" cancelling=""
  local -a descendants=()

  # Adds the command's current descendants to `descendants`. Some test tools
  # create their own sessions and would otherwise escape group cleanup. A
  # single process snapshot keeps cancellation responsive under pressure.
  # shellcheck disable=SC2329 # Called from forward_signal, which the traps invoke.
  capture_descendants() {
    local parent_pid descendant_pid index pid ppid
    local -a pending=("$child_pid")
    local -A children_by_parent=()

    while read -r pid ppid; do
      [[ -n "$pid" && -n "$ppid" ]] || continue
      children_by_parent[$ppid]="${children_by_parent[$ppid]:-} $pid"
    done < <(ps -eo pid=,ppid= 2>/dev/null || true)

    for ((index = 0; index < ${#pending[@]}; index++)); do
      parent_pid="${pending[$index]}"
      for descendant_pid in ${children_by_parent[$parent_pid]:-}; do
        descendants+=("$descendant_pid")
        pending+=("$descendant_pid")
      done
    done
  }

  # Prints the captured descendants and command-session members that are
  # still running. Zombies are finished; their parents only have not reaped them.
  # shellcheck disable=SC2329 # Called from forward_signal, which the traps invoke.
  running_processes() {
    {
      if ((${#descendants[@]} > 0)); then
        ps -o pid=,stat= -p "$(IFS=,; echo "${descendants[*]}")" 2>/dev/null || true
      fi
      ps -o pid=,stat= -s "$child_pid" 2>/dev/null || true
    } | awk '$2 !~ /^Z/ { print $1 }' | sort -u
  }

  # Sends the cancel signal to the command's session and descendants, then
  # kills whatever still runs after CI_CANCEL_GRACE_SECONDS. Some tools keep
  # working after TERM: TypeScript 7's native tsc finishes its whole check
  # first, so a cancelled job could otherwise leave work behind for hours.
  # shellcheck disable=SC2329 # Called indirectly by the signal traps below.
  forward_signal() {
    [[ -n "$child_pid" && -z "$cancelling" ]] || return 0
    cancelling=1
    local pid deadline
    local -a survivors=()

    capture_descendants
    for pid in "${descendants[@]}"; do
      kill -s "$1" "$pid" 2>/dev/null || true
    done
    kill -s "$1" -- "-$child_pid" 2>/dev/null || true

    deadline=$((SECONDS + ${CI_CANCEL_GRACE_SECONDS:-10}))
    while ((SECONDS < deadline)); do
      [[ -n "$(running_processes)" ]] || return 0
      sleep 0.2
    done
    capture_descendants
    mapfile -t survivors < <(running_processes)
    for pid in "${survivors[@]}"; do
      kill -s KILL "$pid" 2>/dev/null || true
    done
    kill -s KILL -- "-$child_pid" 2>/dev/null || true
  }

  trap 'forward_signal TERM' TERM
  trap 'forward_signal INT' INT
  trap 'forward_signal HUP' HUP

  setsid "$@" &
  child_pid=$!

  set +e
  wait "$child_pid"
  local status=$?
  while kill -0 "$child_pid" 2>/dev/null; do
    wait "$child_pid"
    status=$?
  done
  set -e

  return "$status"
}

if [[ "${1:-}" == "--internal-supervise" ]]; then
  shift
  supervise_command "$@"
  exit $?
fi

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

workspace_slot="${CI_WORKSPACE_SLOT:-}"
if [[ -n "$workspace_slot" && ! "$workspace_slot" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "CI_WORKSPACE_SLOT must contain only letters, numbers, dots, underscores, and hyphens" >&2
  exit 2
fi

if [[ ! "${CI_CANCEL_GRACE_SECONDS:-10}" =~ ^[0-9]+$ ]]; then
  echo "CI_CANCEL_GRACE_SECONDS must be a whole number of seconds" >&2
  exit 2
fi

cache_base="${CI_WORKSPACE_CACHE_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/project-ci}"
cache_root="$cache_base/$project_id/$(uname -m)"
if [[ -n "$workspace_slot" ]]; then
  cache_root="$cache_root/$workspace_slot"
fi
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

runner_path="$0"
if [[ "$runner_path" != */* ]]; then
  runner_path="$(command -v "$runner_path")"
fi
runner_path="$(realpath "$runner_path")"

supervisor_pid=""
# shellcheck disable=SC2329 # Called indirectly by the signal traps below.
forward_signal() {
  if [[ -n "$supervisor_pid" ]]; then
    kill -s "$1" -- "-$supervisor_pid" 2>/dev/null || true
  fi
}

trap 'forward_signal TERM' TERM
trap 'forward_signal INT' INT
trap 'forward_signal HUP' HUP

# The supervisor receives TERM from the kernel even if the CI executor kills
# this runner without giving its shell traps a chance to run.
setsid setpriv --pdeathsig TERM "$runner_path" --internal-supervise "$@" &
supervisor_pid=$!

set +e
wait "$supervisor_pid"
status=$?
while kill -0 "$supervisor_pid" 2>/dev/null; do
  wait "$supervisor_pid"
  status=$?
done
set -e

exit "$status"
