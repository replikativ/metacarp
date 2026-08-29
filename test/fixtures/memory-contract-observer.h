#ifndef METACARP_MEMORY_CONTRACT_OBSERVER_FIXTURE_H
#define METACARP_MEMORY_CONTRACT_OBSERVER_FIXTURE_H

/* Deliberately violates the no-effect declaration in the Carp fixture. The
 * smoke test succeeds only when both allocator events are observed. */
int MemoryContractFixture_violates_noeffect(void) {
    void *cell = CARP_MALLOC(8);
    CARP_FREE(cell);
    return 7;
}

/* Supplied by memory-contract-observer-rust.rs in the Rust smoke. */
int MemoryContractFixture_rust_violates_noeffect(void);

#endif
