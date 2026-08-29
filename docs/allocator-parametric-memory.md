# Allocator-parametric memory perspectives

Status: research note. This refines the experimental region-fact query; it does
not change Meta-Carp's source semantics or C lowering yet.

## Zig's useful separation

Studied against local Zig `origin/master` at `e266901590` (2026-08-29).

Zig has no ambient default allocator by convention. `std.mem.Allocator` is a
small type-erased capability consisting of an implementation pointer and a
vtable with four raw operations:

```text
alloc, resize-in-place, remap-possibly-moving, free
```

Typed `create`, `alloc`, `dupe`, `destroy`, and `free` helpers sit above that
raw byte interface. Allocation failure is `error.OutOfMemory`, not an implicit
abort. The same interface admits fixed buffers, arenas wrapping child
allocators, failing allocators, debug allocators, libc allocation, and general
purpose allocation.

Current Zig's `ArrayList` makes an especially relevant choice: the old managed
form storing an allocator is deprecated; operations of the default form that
may allocate accept an allocator argument. This makes allocation dependencies
visible and permits one value representation to operate under different
allocation policies.

Zig also demonstrates the common logical/physical distinction. Calling
`free` invalidates the caller's use of a value, but an arena may reclaim bytes
only for its most recent allocation and otherwise do nothing until reset or
deinit. Logical discharge and physical reclamation are not the same event.

## What not to copy blindly

`std.mem.Allocator` deliberately erases properties which our compiler wants to
reason about:

- which allocator owns a pointer;
- allocator and result lifetimes;
- individual, LIFO, bulk, or tracing reclamation;
- stable versus movable addresses;
- capacity bounds and failure policy;
- thread safety;
- zeroing and initialization policy;
- whether allocation/free events are observable or charged.

Zig leaves these as API/documentation discipline. Supplying the wrong allocator
to `free` or outliving allocator state is illegal behavior. A GC also cannot be
fully represented by the raw interface: it requires roots, safepoints/tracing,
pinning or relocation rules, and usually cooperation from generated code.

Meta-Carp should therefore borrow explicit parameterization and composition,
but retain semantic properties and provenance as compiler-visible facts.

## Two-layer capability

Separate the operational allocator from its semantic law/policy record.

```text
Allocator alpha =
  alloc   : Cap alpha * Layout -> Cap alpha * Result(Own alpha Bytes, OOM)
  resize  : Cap alpha * Own alpha Bytes * Size
            -> Cap alpha * Result(Own alpha Bytes, CannotResize | OOM)
  free    : Cap alpha * Own alpha Bytes -> Cap alpha

AllocatorFacts alpha =
  reclamation  : individual | lifo | bulk | tracing | none
  mobility     : stable | remappable | moving
  capacity     : unknown | bounded Bytes
  concurrency  : local | synchronized | lock-free
  failure      : recoverable-oom | abort | declared policy
  observability: hidden | physical telemetry | logical charge
  parent       : Maybe beta
  evidence     : declared | inferred | measured | checked | proved
```

`alpha` is a fresh, generative provenance identity. An `Own alpha A` can be
freed only through a compatible `Cap alpha`; promotion from `alpha` to `beta`
is therefore explicit and may allocate/fail. The parameter may erase to
ordinary pointers at the C ABI after checking.

An allocator handle itself need not be linearly consumed on each source call.
The semantic state threading above expresses ordering and authority. A concrete
implementation may expose a shared borrowed capability, a thread-safe copyable
vtable handle, or an affine local allocator according to its facts.

## Allocators as algebras of an effect theory

The Core allocation syntax is free over operations such as `alloc`, `resize`,
and `free`. Each allocator supplies an algebra/handler interpreting those
operations. Only logical laws are universal:

- a successful allocation introduces exactly one owner obligation;
- `free` consumes that obligation and later use is invalid;
- resize/remap preserves the logical contents promised by its contract;
- failure introduces no owner and leaves stated input obligations valid;
- an owner never crosses allocator provenance without `promote`.

Physical equations are handler-specific. In particular, the equation “free
immediately reduces retained bytes” is false for arenas and GC heaps.

Allocator transformers compose policies:

```text
Arena       : Alloc alpha -> Alloc (arena alpha)
Bound B     : Alloc alpha -> Alloc (bounded B alpha)
FailAfter n : Alloc alpha -> Alloc (failing n alpha)
Trace       : Alloc alpha -> Alloc (traced alpha)
Synchronize : Alloc alpha -> Alloc (shared alpha)
```

This is the algebraic form of Zig's arena/fixed/failing/debug wrappers, with
the otherwise-erased facts retained in the compiler ledger.

## Storage handlers above allocators

Use `StorageHandler alpha` for the richer island contract:

```text
StorageHandler alpha =
  allocator       : Allocator alpha
  enter/exit      : scoped region operations
  roots/safepoint : optional tracing interface
  collect         : optional administrative transition
  pin/unpin       : optional stable-address interface
  promote         : alpha -> beta boundary operation
  facts           : AllocatorFacts alpha plus handler-specific laws
```

Affine malloc/free and arenas use only the allocator facet. A precise GC adds
roots, collection, and possibly pinning. Persistent/COW storage adds snapshot
and sharing laws. They can still implement the same logical Core effects, but
we do not force every handler through a byte-allocation vtable that cannot
state its invariants.

## Parametric functions and existential boundaries

Inside analyzable code, make allocator provenance parametric:

```text
build : forall alpha.
        Cap alpha -> Input
        -> Result(Own alpha Output, OOM)
```

Collections which retain storage carry provenance in their type and request a
compatible capability only at operations that may allocate:

```text
Vector alpha A
append : Cap alpha -> Vector alpha A -> A
         -> Result(Vector alpha A, OOM)
```

At a dynamic or foreign boundary, package the allocator existentially:

```text
Managed A = exists alpha. (Cap alpha, Own alpha A, AllocatorFacts alpha)
```

This supports Clojure-style dynamic values while retaining enough information
to destroy, inspect, migrate, or specialize them safely.

Surface Clojure/Carp need not pass allocator arguments everywhere. An island
may resolve an ambient capability lexically, while Core and ABI manifests make
the resolved parameter explicit.

## Parametricity result we want

For a computation polymorphic in `alpha` which cannot observe addresses,
allocator identity, collection timing, or physical telemetry:

```text
if A and B both satisfy the declared capacity/failure contract,
then observe(run_A(e)) = observe(run_B(e))
```

Logical allocation charges and evidence traces remain equal; physical
allocation count, retained bytes, and timing may differ. With bounded
allocators the theorem is conditional on sufficient capacity, or relates the
declared OOM outcomes explicitly.

This theorem licenses perspective changes between arena, affine, GC, and
static implementations. When the allocator is statically known, the compiler
can devirtualize its operations, erase arena-local frees, prove capacity,
remove OOM branches, or replace allocation with stack/scalar storage. When it
is dynamic, the same Core lowers to a Zig-like capability vtable.

## Consequence for the current experiment

The experimental session query is correct to report allocator `handler` as
`unresolved`: current `OwnershipPlan` proves ownership transitions but does not
record allocation provenance. The next data-producing change should be an
allocation-site fact keyed by `OwnershipSite`, with an allocator variable
`alpha`, rather than assigning a concrete arena/GC/affine label prematurely.

## One ledger, several non-interchangeable books

This model should compose with Kontor without turning every low-level fact into
money or a generic scalar. Kontor's kernel is the right algebra for the
*recording*: a transaction is a member of the kernel of the sum map, grouped by
an identity and a commodity. The corresponding memory posting key is:

```text
(execution-world, memory-book, commodity, allocator-provenance)
```

where a commodity is a typed resource unit such as bytes, pages, address-space
bytes, pinned bytes, allocation permits, or a particular device's frames. An
allocation transfers an amount from `available` (or a capacity liability) to
`live`; a logical free transfers it from `live` to `discharged`. A handler may
then transfer `discharged` to `reusable`, `returned-to-parent`, or neither.
Every transfer balances as a recording act. That does **not** assert a law of
physics: measured committed/resident bytes can disagree and must be reconciled
as telemetry with their own evidence and time axes.

Keep at least three parallel books, which must never be silently netted:

- the **authority book** records affine capacity, permits, and who may settle
  or reclaim them;
- the **logical book** records owner creation, movement, discharge, and
  compiler-attributed charge;
- the **physical book** records reservations, commits, mappings, resident
  pages, allocator retention, and observations from the runtime or OS.

The account is a coordinate, not the ontology. Allocator, region, world,
address space, NUMA/device location, call site, and evidence are independent
dimensions over which the same facts can later be marginalized. An allocation
site in the compiler is therefore an obligation/fact from which postings may be
materialized; it is not itself evidence that `malloc` succeeded at runtime.

## Forking worlds without copying resource authority

Dvergr's current world rule is the low-level rule we need too: semantic state
may be copied or overlaid, but a live capability to settle it remains affine.
For a resource vector `r`, forking must use an explicit split:

```text
split : Permit alpha r -> (Permit alpha r_parent,
                           Permit alpha r_child)
where r_parent + r_child = r
```

Copying the permit would counterfeit capacity. Read-only allocator facts and
immutable allocation history may be shared freely; mutable allocation
authority, live ownership, and settlement/reclamation authority may not.

World merge consumes the child's settlement capability exactly once. Its
resource ledger is joined relative to the fork basis: allocation identities
from the common prefix are shared history, while child-created identities are
new facts. Equal-looking allocations are not deduplicated unless they have the
same generative identity and lineage. Discard consumes settlement authority
and logically discharges child-only owners, but physical reclamation still
follows each handler's law. Promotion between worlds or allocators is an
explicit, balanced transfer and may require a physical copy:

```text
promote : Permit beta n * Own alpha A
          -> Result(Own beta A * Discharged alpha A, OOM)
```

This is the memory analogue of Dvergr's whole-world adoption rule. Partial
promotion requires a real affine partition operation; selecting fields from a
descriptor does not manufacture independently settleable capabilities.

## Do not collapse the OS layer into `alloc`

The allocator algebra is a convenient middle layer, not the bottom of the
system. Code suitable for kernels, drivers, embedded runtimes, and language
bootstrapping needs the storage primitives beneath it to remain expressible:

```text
reserve/unreserve virtual address ranges
commit/decommit physical backing
map/unmap frames and devices
protect/change cache attributes
allocate/free physical frames
pin/unpin and establish DMA visibility
```

Their facts include byte extent, target ABI layout and alignment, address
space, page size, permissions, physical/virtual distinction, cacheability,
mobility, interrupt/safepoint admissibility, failure mode, and provenance.
`malloc`-like, arena, slab, page, GC, and persistent/COW handlers are algebras
built above selected subsets of these operations. High-level code can quantify
over a handler and forget irrelevant details; low-level code can select the
primitive perspective directly. The perspective change is explicit and may
carry proof, accounting, and runtime cost.

## Initial allocation-site fact

The first implementation should be deliberately smaller than this complete
model. It can report backend-proven array allocations with:

```text
site, fresh allocator variable, region, result resource,
element type/count, symbolic byte extent/alignment,
address stability, failure/reclamation policy,
logical/physical account coordinates, and evidence
```

Unknown policy fields stay `unresolved`. In particular, current `CARP_MALLOC`
lowering does not justify claiming recoverable OOM, a concrete allocator, or
immediate reclamation. Later passes can refine the same fact rather than
replacing it with an unrelated cost model.
