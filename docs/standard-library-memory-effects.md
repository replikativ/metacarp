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
manifest does not become a transitive `noalloc` proof until step 4 accounts for
ordinary callees, callbacks, and template dependencies.

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
