#!/usr/bin/env bash
# Run every compiler-phase test against the reference Carp compiler.
# Keep this as the single source of truth for the phase suite: CI and local
# assurance both call this script.
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
reference=${CARP_REFERENCE:-carp}
jobs=${CARP_PHASE_JOBS:-1}

if [[ "$(uname -s)" == "Linux" ]]; then
  ulimit -s 524288
fi

run_phase_test() {
  # Carp's default executable path is relative to the current directory.
  # Remove it so a failed compile cannot execute a stale test artifact.
  rm -rf out
  "$reference" -x "$1"
}

cd "$repo_root"

run_module_tests() {
  for directory in \
    carp-graph carp-c-abi carp-primitives carp-surface carp-module carp-ct-env \
    carp-ct-eval carp-ir carp-resolve carp-types carp-infer carp-specialize \
    carp-backend carp-expand
  do
    (
      cd "$repo_root/$directory"
      for test_file in test/*.carp; do
        printf '== %s/%s\n' "$directory" "$test_file"
        run_phase_test "$test_file"
      done
    )
  done
}

run_root_tests() {
  (
    cd "$repo_root"
    run_phase_test test/carp-compiler.carp
    run_phase_test carp-session/test/carp-session.carp
    run_phase_test carp-session/test/core.carp
    rm -rf out
    "$reference" -x --log-memory carp-session/test/memory.carp
  )
}

case "$jobs" in
  1)
    run_module_tests
    run_root_tests
    ;;
  2)
    run_module_tests &
    module_pid=$!
    run_root_tests &
    root_pid=$!

    set +e
    wait "$module_pid"
    module_status=$?
    wait "$root_pid"
    root_status=$?
    set -e

    if [[ "$module_status" -ne 0 || "$root_status" -ne 0 ]]; then
      printf 'phase suites failed: modules=%d root=%d\n' \
        "$module_status" "$root_status" >&2
      exit 1
    fi
    ;;
  *)
    printf 'CARP_PHASE_JOBS must be 1 or 2, got %s\n' "$jobs" >&2
    exit 2
    ;;
esac
