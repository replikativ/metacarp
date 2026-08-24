# Cargo adapter interoperability

Meta-Carp consumes Rust through a stable C ABI. It never depends on Rust's
unstable native ABI. A Cargo adapter is a `cdylib` or `staticlib` crate whose
public boundary consists of `extern "C"` functions, `#[repr(C)]` values, and
opaque handles with explicit destruction.

## Versioned adapter descriptor

The portable descriptor is data, not executable shell text. Its first protocol
version has this logical shape (EDN is illustrative; the session wire format is
canonical CBOR):

```clojure
{:format 1
 :manifest "rust/example/Cargo.toml"
 :package "example-adapter"
 :profile :release
 :features []
 :library {:linux "target/release/libexample_adapter.so"
           :macos "target/release/libexample_adapter.dylib"
           :windows "target/release/example_adapter.dll"}
 :include-dirs ["include"]
 :bindings ["bindings/Example.carp"]}
```

Paths are resolved relative to the descriptor. The library path is explicit:
Cargo package names, target names, platform suffixes, workspaces, and custom
target directories make guessing it unreliable. A single string is also
accepted for host-specific descriptors. `features` are individual Cargo
feature names, never a shell fragment.

The Carp binding module owns the typed declarations and ownership modes:

```clojure
(system-include "example.h")
(defmodule Example
  (register inspect (Fn [(Ref Item)] Double) "example_inspect" [shared])
  (register mutate! (Fn [(Ref Item)] ()) "example_mutate" [unique]))
```

Resolution validates the mode list. The ownership pass propagates `unique`
through ordinary Carp calls and keeps explicit foreign uniqueness strict.

## Build and cache contract

The host invokes Cargo with an argument vector, not a shell command:

```text
cargo build --manifest-path <manifest> --package <package> --release
            [--features <comma-separated-features>]
```

Successful artifacts are installed or copied to an immutable content-addressed
path before loading. The cache key includes the descriptor, canonical manifest
path, selected package/profile/features, `Cargo.lock`, relevant Rust sources,
target triple, and Cargo/Rust compiler identity. A failed build never replaces
the active artifact.

The standalone compiler and the resident session consume the same result:

- binding modules to load;
- include directories for C compilation;
- native libraries/link arguments;
- the adapter identity used by incremental cache keys.

The command-line driver initially exposes repeatable `--include` and `--link`
inputs. The Cargo builder and future `(cargo/import ...)` form normalize to
those inputs. Carpaccio becomes another client of this contract rather than a
separate Cargo implementation.

The repository contains a dependency-free executable fixture. It demonstrates
that this is native Carp FFI, not a Carpaccio-only facility:

```sh
cargo build --release --manifest-path examples/rust-cargo/Cargo.toml
out/carp-compiler -b --optimize -c "$CARP_DIR/core" \
  --include examples/rust-cargo/include \
  --link examples/rust-cargo/target/release/libmetacarp_rust_example.so \
  -o /tmp/metacarp-rust-example examples/rust-cargo/main.carp
/tmp/metacarp-rust-example # prints 42
```

`scripts/run-rust-cargo-example.sh` performs the platform-sensitive form of
this smoke test. Cargo's own incremental target cache is used in this first
slice. `carpaccio.cargo/build!` consumes the canonical-CBOR descriptor with an argument
vector, fingerprints the output, headers, binding modules, lockfile, and Rust
toolchain, then installs immutable inputs. `carpaccio.cargo/import!` also loads
the binding modules and registers the include/library inputs with the REPL
runtime.

## Rust consuming Carp

The inverse package contains two crates:

- `<name>-sys` bundles generated C, headers, raw Rust declarations, and a
  `build.rs` using the `cc` crate;
- `<name>` exposes safe wrappers derived from the ownership manifest.

`SharedBorrow`, `UniqueBorrow`, `Take`, owned results, and `borrows-from` edges
map respectively to shared references, mutable references, consuming methods,
RAII owners, and explicit Rust lifetime relationships. Unsupported or
ambiguous contracts remain in the unsafe `-sys` layer. Published crates bundle
generated C so their consumers do not need Carp installed; CI regenerates with
a pinned compiler and rejects drift.

## Safety boundary

- Rust panics must not unwind across the C boundary.
- Rust-specific containers, trait objects, and default enums never cross it.
- A library cannot be unloaded while native handles or returned borrows remain.
- Callbacks require an explicit lifetime/thread/unwind contract and are outside
  the first adapter version.
- Cargo build execution is an explicit host action, never performed by parsing
  an untrusted Carp module implicitly.

## Unmodified crates and compilation tiers

An upstream crate does not need to know about Carpaccio. The primary importer
resolves an exact package/version with Cargo, extracts its public API into the
same canonical-CBOR type and ownership model, and generates a private adapter
crate. An upstream attribute/procedural macro is only an optional fast path.
Rustdoc JSON is a useful initial extractor when pinned to a known toolchain;
the stable Cargo metadata and compiler-artifact streams remain the package and
artifact discovery boundary. Source-only parsing is insufficient after cfg,
macro expansion, type resolution, and monomorphization.

Generic roots may request explicit concrete arguments. Primitive arguments and
recursive structural forms such as `(Vec u32)`, `(Option u64)`, and
`(Result u32 i32)`, plus borrowed `Ref`/`MutRef` slice and container forms, are
substituted through the rustdoc signature; an
unambiguous public crate type may be named directly. The concrete result still
has to satisfy the normal ABI-layout and ownership checks, so this does not
turn an unresolved generic contract into an unchecked FFI boundary.

Associated `Read::Error` and `Write::Error` projections remain rejected by
default. An explicit debug-string error mode can normalize them to an affine
owned UTF-8 buffer. A `Vec<u8>` writer mode constructs a native writer inside
the adapter and returns its storage as an affine buffer, allowing generic
buffer-oriented serializers to remain zero-copy at the host boundary.

The REPL-facing API is intended to have two phases:

```clojure
(cargo/api "some-numerics" "2.4.0")
(cargo/import! "some-numerics" "2.4.0"
  {:roots ['some_numerics/process]})
```

`cargo/api` returns tools.analyzer-shaped EDN backed by canonical CBOR.
`cargo/import!` generates wrappers only for selected concrete roots. Generic
functions require requested instantiations; APIs that cannot yet be represented
are reported rather than guessed.

Root selection is optional. With no `:roots`, the importer considers the full
public rustdoc API and generates the safely representable subset. Explicit
roots remain useful as a code-size, build-latency, safety-surface, and AOT
reachability boundary; they are not required for ordinary REPL exploration.

An explicit Carpaccio `defshared` descriptor can now authorize a zero-copy
mapping for a public, plain `#[repr(C)]` Rust record:

```clojure
(defshared RustPoint [x Double y Double])
(cargo/import! "some-numerics" "2.4.0"
  {:roots ['some_numerics/norm 'some_numerics/translate]
   :shared-types {'some_numerics/RustPoint RustPoint$type}})
```

The importer checks rustdoc's representation, generics, field visibility,
order, names, and primitive widths against the Coffi/Panama layout. Generated
Rust reconstructs `&T` or `&mut T` from the C pointer, while the Carp binding
marks the corresponding `(Ref T)` parameter `shared` or `unique`. Unsupported
or layout-unstable records are rejected rather than copied implicitly.

The same mapping can now be synthesized without a handwritten `defshared`:

```clojure
(def imported
  (cargo/import! "some-numerics" "2.4.0"
    {:roots ['some_numerics/norm 'some_numerics/translate]
     :types :auto}))

(get (:types imported) ["some_numerics" "Point"])
;; => generated SharedType named Cargo_some_numerics_types/Point
```

The automatic tier accepts public, non-generic `repr(C)` records recursively
composed of supported fixed-width primitive fields, nested admitted records,
and fixed arrays. It also accepts one-field `repr(transparent)` newtypes for
pointer-based interop. Rust `bool` fields become checked shared values that only
accept JVM booleans and write 0/1. Inline arrays are represented exactly in
Coffi/C memory but do not yet receive Carp field accessors, since Carp's
`StaticArray` is not an inline C-array representation.
`:type-report` retains the rejected structs as `:opaque` candidates with explicit reasons. Generated
Rust exports size, alignment, and field-offset facts, which Carpaccio checks
against Coffi before the first native generation can be invoked.

The rustdoc projection attaches inherent and trait methods to their owner.
Trait paths are `crate/Type/Trait/method`; borrowed impls add `ref` or `ref-mut`.
Standard traits use stable public paths, and concrete associated types such as
`Iterator::Item` are substituted from the impl. `classify-methods` recovers
constructor, shared-borrow, unique-borrow, and consuming operations from the
`Self` receiver. Shared and unique borrowed methods on admitted shared records
can be selected as adapter roots.

Opaque structs and enums are represented as nominal Carp `void*` owner types.
Concrete generic instantiations have distinct nominal names, destructor
symbols, and Rust types. A generated constructor returns `Box<T>::into_raw`; borrowed methods use
`(Ref Owner)` and receive a pointer cell from which Rust reconstructs `&T` or
`&mut T`; a consuming method reconstructs the box and moves out `T`; and the
generated `delete` implementation calls a panic-contained Rust destructor.
Consequently normal Carp scope exit, early return, and unused-result planning
all use the same ownership pass as native Carp values. The representation has
one extra pointer load on borrowed calls, chosen to preserve the language's
existing `Ref` and `unique` invariants rather than teaching the checker that a
by-value pointer is secretly a borrow.

The JVM side mirrors this with a checked `RustOwner`: its native cell
is passed for borrows, `take` transitions atomically to `:consumed`, and explicit
close or runtime shutdown invokes the destructor once. Owners keep the adapter
runtime alive and cannot cross runtime generations. Cross-thread moves/unique
calls require extracted `Send`; shared borrows require `Sync`; absent evidence
remains confined. Borrowed opaque results retain `:borrows-from` edges and
lease their source owner on the JVM. By-value slice/string views in standalone
Carp use a nominal C carrier with a phantom `(Ref Owner lifetime)` type
argument. The existing nested-lifetime analysis consequently retains the owner
without changing the C representation or adding runtime bookkeeping.
Retained generic owners use the same mechanism: for example,
`Reader<&[u8]>` carries a phantom reference to its source array. Rust storage is
erased to an adapter-internal `'static` spelling, while `borrows-from` and the
phantom type preserve the real lexical lifetime in Carp. The Clojure importer
requires `pinned-slice`/`pinned-utf8` for such retained inputs.

For iterative development, `cargo/import-local!` accepts an unmodified local
`Cargo.toml` and runs the same extraction/generation path. Rust source files,
the manifest, lockfile, and build script participate in its analysis identity,
so REPL reevaluation cannot retain stale rustdoc layouts after source edits.

An unmodified `roaring` 0.11.4 import is the first large-crate stress fixture.
The pre-trait no-roots baseline built 53 callable roots and rejected 36 with
structured reasons. Unsigned and pointer-sized scalars are supported, and scalar
`Option<T>` is lowered through a generated `repr(C)` carrier rather than Rust's
unstable enum ABI. Clojure decodes it to value-or-`nil`; generated Carp helpers
decode it to `Maybe T`. Owned Roaring iteration now runs through
`IntoIterator::into_iter` and `Iterator::next`; borrowed iteration uses a JVM
source lease. Concrete scalar ranges, primitive slices, UTF-8 `&str`, and
scalar `Result<T,E>` use generated stable carriers or expanded scalar ABIs.
Generic `RangeBounds` and callback/vtable I/O remain later work. Retained
slices through concrete generic owners and owned string/vector projection are
implemented.

There are three compilation tiers over one manifest and ownership IR:

1. **Dynamic:** a small immutable adapter generation for fast feedback.
2. **Session aggregate:** one incrementally rebuilt Cargo adapter containing
   the active Rust dependency graph and composite wrappers. Rust values do not
   cross between unrelated adapter generations; raw ABI memory may cross when
   its schema identity agrees.
3. **AOT image:** one pinned Carp library plus an aggregate Rust adapter built
   with `:build-mode :aggregate` (fat LTO and one codegen unit by default) or an
   explicit `:lto`/`:codegen-units` policy. Carp-to-Carp and Rust-to-Rust calls stay
   direct; crossings remain coarse C-ABI calls.

New generations load atomically. Clojure vars select the newest Panama handles,
while opaque values retain their originating generation until destruction.
Libraries cannot unload while calls, handles, or returned borrows remain live.

The normal performance rule is to move loops and pipelines behind a native
root rather than cross Panama or the C ABI per element. A generated composite
Rust wrapper lets Rust optimize calls spanning several crates. Cross-language
LLVM LTO for Carp-generated C is a later optional tier, since it requires a
compatible Clang/rustc LLVM toolchain and is not necessary for coarse kernels.

## Implementation sequence

Primitive/shared record adapters, recursive automatic layouts, layout
attestation, inherent/trait method projection, opaque owners, slices, UTF-8
inputs, scalar `Option`/`Result`, concrete ranges, auto-trait thread policies,
owned iterators, and JVM borrowed-result leases are implemented.
Concrete generic opaque owners, explicit enclosing-impl specialization, and
phantom retained-source types are also implemented.

1. Keep the existing descriptor-path importer as a deterministic fixture and
   explicit escape hatch; canonical CBOR is authoritative and EDN is legacy.
2. Consume Cargo's machine-readable artifact messages instead of guessing a
   `target/` library path.
3. Resolve `(name, exact-version, features, target)` with `cargo metadata` and
   cache its canonical package graph.
4. Implement `cargo/api` from pinned rustdoc JSON, preserving generics,
   lifetimes, repr attributes, methods, and source identity in CBOR.
5. Generate conservative adapters for primitives, shared/unique references,
   slices, strings, `repr(C)` values, opaque owners, `Option`, and `Result`.
6. Add root-selected `cargo/import!` and reject unsupported APIs with a useful
   per-item explanation.
7. Aggregate active packages and generated composite wrappers into one Cargo
   session crate, rebuilding in the background and atomically swapping it.
8. Add an explicit reproducible AOT image command with ThinLTO/fat-LTO and
   codegen-unit controls, followed by boundary and kernel benchmarks.
