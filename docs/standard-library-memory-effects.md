# Standard-library memory effects and runtime hosts

Status: research contract. This follows `allocator-parametric-memory.md` and
defines the next compiler/standard-library seam. It does not change source
semantics or select a JVM/native backend yet.

Studied locally against Zig `origin/master` at `e266901590`, TigerBeetle
`0baa07d3b`, and Valhalla `lworld` at `775bcc5bdf2`.

## The standard library is part of the program

Allocation analysis is unsound if it stops at a library call. Current Carp
Core and generated C contain allocation in at least these families:

- array literals, `allocate`, growth, copying, and generated deletion;
- `Box.init`, `Box.copy`, and `Box.unbox`;
- closure environments and closure copies;
- String construction, slicing/copying, formatting, parsing, and conversion;
- Pattern, IO, and native support buffers;
- collection algorithms implemented through allocating arrays or strings;
- user templates and foreign C whose effects are presently opaque.

`CARP_MALLOC` is a lowering detail, not an effect system. Replacing its macro
cannot reveal whether an operation may allocate, relocate existing storage,
fail, invalidate a borrow, retain memory, or call a safepoint.

The compiler must derive a transitive summary for every reachable
specialization, including Core, templates, generated functions, and foreign
calls. An unresolved leaf prevents a proof of `noalloc`.

## What Zig gets right

Current Zig collections separate representation from allocation authority.
The default `ArrayList` representation does not retain an allocator; operations
which may grow receive one. It exposes distinct contracts:

```text
append(gpa, x)             may allocate and returns OOM
appendBounded(x)           uses existing capacity or returns OOM
appendAssumeCapacity(x)    proven/preconditioned no-allocation operation
initBuffer(span)           externally managed fixed storage
```

`ensureTotalCapacity` and `ensureTotalCapacityPrecise` make scheduling and
growth policy explicit. `clearRetainingCapacity` separates logical clearing
from physical release. Hash maps have the same unmanaged/allocator-at-growth
shape. Collection pointer locks dynamically catch operations that would
invalidate extant element pointers.

`FixedBufferAllocator` demonstrates why logical and physical reclamation must
differ: it assigns aligned subranges of a supplied buffer, but an individual
free normally recovers space only for the most recent allocation. Its
thread-safe form changes the concurrency law without changing the byte
allocator interface.

We should borrow these semantic distinctions, but not require programmers to
encode every proof by manually selecting an `AssumeCapacity` spelling. When
capacity analysis proves the precondition, the ordinary operation can lower to
the no-allocation path. Explicit variants remain useful for API boundaries and
diagnostics.

## What TigerBeetle adds

TigerBeetle's `StaticAllocator` permits allocation/resizing during `init`,
rejects every allocator call in `static`, and permits release during `deinit`.
The replica preallocates buffers and collection capacity, seals the allocator,
then reuses storage during steady-state execution. This is not “no allocation
ever”; it is a checked temporal protocol:

```text
init -> seal -> steady-state -> teardown
```

Meta-Carp should make the phase a compile-time effect/capability where
possible, with an asserting handler as the runtime backstop:

```text
seal : Allocating alpha r -> Static alpha r
run  : Static alpha r * Input -> Static alpha r * Output
```

A steady-state call graph is admissible only when its transitive allocation
effect is empty and its bounded collections cannot exceed their reserved
capacities. This applies equally to a database replica, an audio callback, an
interrupt handler, a render loop, or an MCU control loop.

## Memory effect row

Ownership and memory effects are related but distinct. Moving an owner need not
allocate; growing an array may relocate bytes without changing its logical
owner. The initial effect vocabulary should include:

```text
alloc(alpha, layout, count, failure)
resize(alpha, owner, old-layout, new-layout, mobility, failure)
free(alpha, owner)
reset(alpha)
read(place) / write(place)
invalidate(place-or-loan)
root/unroot(alpha, place)
safepoint(alpha)
collect(alpha)
pin/unpin(alpha, place)
promote(alpha, beta, owner, failure)
reserve/commit/map/protect(address-space, extent, policy)
foreign(effect-summary | unknown)
```

Effects form a set/inclusion lattice for conservative inference. Quantitative
facts use their own abstract domains rather than being flattened into a flag:

```text
allocation count: 0 | exact n | interval [l,u] | symbolic f(inputs) | unknown
byte extent:       exact | aligned symbolic layout | interval | unknown
capacity:          exact | lower bound | upper bound | unknown
phase:             init | static | teardown | unconstrained
evidence:          declared | inferred | lowering-checked | measured | proved
```

The effect row is parameterized by allocator/storage-handler provenance. A
function can therefore be `noalloc` with respect to one handler while still
performing GC root operations or writes to caller-provided storage.

## Proposed Core collection surface

The source surface can remain Lisp-like and dynamic while Core makes the
resolved contracts explicit:

```text
Array alpha A

with-capacity : Cap alpha -> Int
                -> Result(Array alpha A, OOM)
from-buffer   : BorrowUnique (Span alpha A n)
                -> BufferArray alpha A n
reserve!      : Cap alpha -> RefUnique(Array alpha A) -> Int
                -> Result(Unit, OOM)
push!         : Cap alpha -> RefUnique(Array alpha A) -> A
                -> Result(Unit, OOM)
push-bounded! : RefUnique(BufferArray alpha A n) -> A
                -> Result(Unit, Full)
push-proved!  : RefUnique(Array alpha A) -> A -> Unit
clear!        : RefUnique(Array alpha A) -> Unit
release       : Cap alpha -> Array alpha A -> Unit
```

The compiler may elaborate an ambient lexical capability into the explicit
Core parameter. `push-proved!` is normally an optimization result; users need
it directly only at a hard no-allocation boundary.

Strings should follow the same split. Non-allocating formatting writes to a
`Sink`/bounded buffer and reports `Full`; an allocating convenience wrapper
creates a growable buffer. `copy` becomes `clone-in alpha` in explicit Core.
Collection combinators should expose producer/consumer structure so fusion,
destination passing, and escape analysis can remove intermediate arrays.

## Library effect manifests

Every primitive/template/foreign definition needs a checked manifest adjacent
to its implementation, not a name-based compiler exception:

```text
Array.push-back!:
  effects: [resize(alpha, argument 0, may-move, OOM)]
  invalidates: [loans into argument 0 when growth occurs]

Box.init:
  effects: [alloc(alpha, sizeof(A), 1, OOM)]

Box.unbox:
  effects: [free(alpha, argument 0)]

String.copy:
  effects: [alloc(alpha, strlen(argument 0)+1, 1, OOM)]
```

Generated C can be audited against manifests by recognizing the compiler's own
allocation primitives. Arbitrary external C/Rust/JVM calls require a declared
summary; `unknown` remains safe but prevents `noalloc`, bounded-capacity, and
hard real-time proofs.

Source `register` and `deftemplate` declarations now accept an optional final
memory-effect array. Omission means `[unknown]`; an explicitly empty array is a
checked no-effect assertion:

```clojure
(register clock-now (Fn [] Long) "clock_now" [] [])
(register reserve (Fn [Int] (Ptr Byte)) "reserve" [copy]
  [(allocate (argument-elements 0))])
(deftemplate Pointer.free (Fn [(Ptr a)] ())
  "void $NAME($a* p)" "$DECL { CARP_FREE(p); }"
  [(free 0)])
```

The effect grammar is:

```text
[]
[unknown]
[(allocate unknown)]
[(allocate (exact-elements n))]
[(allocate (argument-elements argument-index))]
[(free argument-index)]
[(resize argument-index extent may-move)]
```

Several effects may appear in one array, except that `unknown` must stand
alone. Argument indices and argument-derived extents are checked against the
function signature; a relocating resize automatically invalidates loans
derived from its owner argument. For `register`, the existing foreign
parameter-mode array precedes the memory array, so a zero-argument audited
registration uses `[] []`. These are trusted native contracts: the compiler
validates shape and composes them soundly, but auditing C against the assertion
is a separate build/toolchain responsibility.

## Dynamic contract falsification

`CARP_MEMORY_CONTRACT_TRACE` enables a generated C99 observer after
`carp_memory.h` and before requested Core/native headers and generated
templates. It interposes `CARP_MALLOC`, `CARP_REALLOC`, and `CARP_FREE`, tracks
event counts and requested bytes, and exposes reset/snapshot/check functions.
This makes an annotation test mechanically useful: reset or snapshot, execute a
native API under representative inputs, and reject observations containing an
effect that its manifest does not allow.

The checked-in `scripts/smoke-memory-contract-observer.sh` builds a fixture
whose C implementation deliberately violates its declared empty manifest. The
smoke succeeds only when the observer falsifies that annotation by seeing both
allocation and free events.

Rust and other separately compiled native code do not pass through the C
macros. They can report to the same executable through:

```rust
unsafe extern "C" {
    fn carp_memory_contract_observe_external(event: i32, bytes: usize);
}

const ALLOCATE: i32 = 1;
const RESIZE: i32 = 2;
const FREE: i32 = 4;
```

A Rust `Allocator`/`GlobalAlloc` test adapter should call this ABI around its
actual allocator. Reporting must itself remain allocation-free to avoid
recursion. `scripts/smoke-memory-contract-observer-rust.sh` exercises this with
a real `GlobalAlloc` adapter and a `Vec` allocation, again behind a deliberately
false empty manifest. The initial C observer is process-global and intended for
controlled single-threaded tests; per-thread/nested scopes and concurrent
aggregation are future refinements.

Dynamic observation never proves absence. It can falsify a contract on an
executed path, while untested branches, allocator bypasses, inline assembly,
system calls, and separately compiled code without an adapter remain outside
the observation boundary. Evidence should therefore form a ladder rather than
a Boolean:

```text
declared < observed(samples, target, coverage) < audited < mechanically checked
```

Static `Proven` currently means proven relative to the manifests in Core IR.
The manifest's evidence and the dynamic observation receipts must remain
available so consumers such as Kontor can choose the assurance level they
require. Before bulk-annotating Core, the next harness should generate tests
from each manifest, run representative and boundary inputs under the observer,
and retain target/toolchain/input hashes with the result.

## JVM/Valhalla/Graal as a host, not the ontology

Valhalla is valuable because value classes and flat fields/arrays can preserve
high-level Java interoperability while avoiding many object headers and
indirections. Panama supplies an existing scoped off-heap island through
`MemorySegment`, `MemoryLayout`, and `Arena`. JVMCI supplies a compiler/code
installation seam. These map naturally onto our representation and storage
handler choices:

```text
logical value -> ordinary GC object | Valhalla flat value
affine region -> Panama segment/arena | native allocation
specialized code -> JVM bytecode/JVMCI code | native C/Rust backend
```

The Meta-Carp IR must stay above all of them. Valhalla's implementation is
deeply entangled with HotSpot layout, buffering, escape analysis, deopt, GC,
and C2 alias slices; lifting our semantics directly into C2 would inherit a
large C++ semantic trusted base. The local branch even retains known limits
around scalar replacement of flat arrays. That makes C2 a poor first place for
our experimental optimizer.

A better sequence is:

1. host dynamic language values and the Java ecosystem on an ordinary JVM;
2. use Panama for explicit native regions and current Meta-Carp libraries;
3. emit Valhalla representations when layout/equality/nullability facts allow;
4. prototype compiler phases above JVMCI/Graal, or in our own compiler feeding
   JVM bytecode, rather than initially modifying C2;
5. modify Valhalla/HotSpot only when an experiment identifies a missing VM
   primitive that cannot be expressed through those seams.

Graal is attractive for a dynamic/JIT language because its Java-hosted IR and
partial-evaluation culture are closer to our staging and abstract-
interpretation model than C2. Native Image is a deployment backend, not the
foundation for a recursively self-modifying runtime: closed-world AOT and live
JIT/code evolution have different laws.

The JVM remains an ecosystem island. Kernel, MCU, DMA, and fixed-memory code
must not depend on object headers, safepoints, or a process VM. The same Core
effects lower to a different handler/backend there.

## Kernel and recursively optimizing systems

A future Rust-for-Linux adapter should preserve kernel-specific allocation
context, fallibility, pinning, device visibility, concurrency, and teardown
protocols instead of presenting “Linux memory” as one allocator. No current
Rust-enabled kernel tree was available locally for a version-specific audit,
so this document deliberately states only the backend requirements.

Self-modifying/JIT code adds another affine resource family:

```text
CodeVersion v, WritePermit v, ExecutePermit v, DependencySet v
```

Compilation allocates a candidate code/version world; validation records
proofs, measurements, deoptimization metadata, and resource receipts;
publication consumes write/settlement authority and installs execute
authority. Supersession invalidates dependent code and eventually reclaims the
old version after quiescence. This is the same fork/validate/settle algebra as
Dvergr and Yggdrasil, applied to executable state.

Top-down AGI planning can then choose transformations using predicted latency,
memory, energy, uncertainty, and semantic evidence. It must still settle each
choice through the low-level affine and physical laws; “the planner expects the
optimization to work” is not allocation authority.

## Implementation order

The first compiler slice now implements steps 1 and 2: the specialized-Core
allocation walker lives in `carp-memory`, and every primitive registry entry
carries a structured direct manifest. Known allocation, resize, free, and
no-effect cases are declared beside their lowering; unresolved interfaces and
templates remain explicitly `Unknown`. The session allocation report now
interprets `ArgumentElements` from these manifests instead of matching stable
primitive IDs. This is direct-effect infrastructure only: a checked empty
manifest does not by itself become a transitive `noalloc` proof.

The second slice supplies the conservative core of steps 3 and 4. It marks
unannotated foreign/template calls, indirect calls, and explicitly unknown
primitive manifests as unresolved leaves, and computes a least fixed point over
resolved specialized-body edges. Allocate, resize, free, and unknown remain
independent summary bits. Direct sites and edges are exposed through the
session/CBOR experimental query so a later verifier can reconstruct call-chain
diagnostics. Primitive template dependencies that are not fully represented by
their manifest remain `Unknown`. Audited source contracts can now discharge a
foreign leaf; omitted contracts remain unknown for compatibility and safety.

The third slice adds deterministic `noalloc` and `static-memory` verification
for every specialized target signature to the experimental session/CBOR report.
`noalloc` rejects allocate and resize; `static-memory` additionally rejects
free. A violated or unknown result carries a source-anchored call trace to the
direct effect or unresolved leaf. It also adds the opt-in C/Rust event ABI above
so declared native contracts can be dynamically falsified before they are used
broadly.

1. Move the experimental allocation walker out of `carp-session` into a
   dedicated compiler memory-analysis module.
2. Add structured effect manifests to compiler primitives and templates.
3. Inventory Core native headers/templates and mark unresolved foreign leaves.
4. Infer transitive specialized function summaries and expose them in the
   session/CBOR query.
5. Add an opt-in `noalloc`/static-phase verifier with precise call-chain
   diagnostics.
6. Add capacity abstract interpretation and eliminate proven growth paths.
7. Make allocator parameters explicit in Core and ABI manifests, then add
   fixed-buffer/arena handlers.
8. Add GC root/safepoint/pin effects and representation promotion.
9. Prototype a JVM/Panama backend; evaluate Valhalla and JVMCI/Graal mappings
   without making the JVM the universal runtime.
