use std::alloc::{GlobalAlloc, Layout, System};

const ALLOCATE: i32 = 1;
const RESIZE: i32 = 2;
const FREE: i32 = 4;

unsafe extern "C" {
    fn carp_memory_contract_observe_external(event: i32, bytes: usize);
}

struct ObservedSystem;

unsafe impl GlobalAlloc for ObservedSystem {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        let pointer = unsafe { System.alloc(layout) };
        if !pointer.is_null() {
            unsafe { carp_memory_contract_observe_external(ALLOCATE, layout.size()) };
        }
        pointer
    }

    unsafe fn dealloc(&self, pointer: *mut u8, layout: Layout) {
        unsafe { carp_memory_contract_observe_external(FREE, layout.size()) };
        unsafe { System.dealloc(pointer, layout) };
    }

    unsafe fn realloc(&self, pointer: *mut u8, layout: Layout, size: usize) -> *mut u8 {
        let resized = unsafe { System.realloc(pointer, layout, size) };
        if !resized.is_null() {
            unsafe { carp_memory_contract_observe_external(RESIZE, size) };
        }
        resized
    }
}

#[global_allocator]
static ALLOCATOR: ObservedSystem = ObservedSystem;

#[no_mangle]
pub extern "C" fn MemoryContractFixture_rust_violates_noeffect() -> i32 {
    let mut bytes = Vec::with_capacity(8);
    bytes.push(7);
    drop(bytes);
    7
}
