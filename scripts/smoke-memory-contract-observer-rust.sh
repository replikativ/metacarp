#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
compiler=${CARP_COMPILER:-"$repo_root/out/carp-compiler"}
core=${CARP_CORE_DIR:-"$repo_root/../Carp/core"}
c_compiler=${CC:-cc}
rust_compiler=${RUSTC:-rustc}

if [ ! -x "$compiler" ]; then
  echo "missing Meta-Carp compiler: $compiler" >&2
  exit 1
fi
if [ ! -f "$core/Core.carp" ]; then
  echo "missing Carp Core: $core (set CARP_CORE_DIR)" >&2
  exit 1
fi
if ! command -v "$rust_compiler" >/dev/null 2>&1; then
  echo "missing Rust compiler: $rust_compiler (set RUSTC)" >&2
  exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM

"$compiler" -c "$core" -o "$work/observer.c" \
  "$repo_root/test/fixtures/memory-contract-observer-rust.carp"
"$rust_compiler" --crate-type staticlib -C panic=abort \
  -o "$work/observer-rust.a" \
  "$repo_root/test/fixtures/memory-contract-observer-rust.rs"
"$c_compiler" -std=gnu99 -DCARP_MEMORY_CONTRACT_TRACE \
  -I"$core" -I"$repo_root/test/fixtures" \
  -o "$work/observer" "$work/observer.c" "$work/observer-rust.a" \
  -ldl -lpthread -lm
"$work/observer"

echo "Rust memory contract observer smoke: falsified false no-effect annotation"
