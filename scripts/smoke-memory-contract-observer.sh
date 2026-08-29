#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
compiler=${CARP_COMPILER:-"$repo_root/out/carp-compiler"}
core=${CARP_CORE_DIR:-"$repo_root/../Carp/core"}
c_compiler=${CC:-cc}

if [ ! -x "$compiler" ]; then
  echo "missing Meta-Carp compiler: $compiler" >&2
  exit 1
fi
if [ ! -f "$core/Core.carp" ]; then
  echo "missing Carp Core: $core (set CARP_CORE_DIR)" >&2
  exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM

"$compiler" -c "$core" -o "$work/observer.c" \
  "$repo_root/test/fixtures/memory-contract-observer.carp"
"$c_compiler" -std=gnu99 -DCARP_MEMORY_CONTRACT_TRACE \
  -I"$core" -I"$repo_root/test/fixtures" \
  -o "$work/observer" "$work/observer.c" -lm
"$work/observer"

echo "memory contract observer smoke: falsified false no-effect annotation"
