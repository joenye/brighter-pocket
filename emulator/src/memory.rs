//! The guest's memory: one host reservation of 2^36 bytes, guest address `a` at `base + a`, so
//! the JIT (src/cpu.rs, fastmem) loads and stores straight to it. Ranges are mapped (made
//! readable and writable) as images, stacks and heaps need them; anything else faults.
//!
//! The heap the client allocates from (malloc and the rest, src/hle/memory.rs) and the harness's
//! own allocations share one allocator here: blocks of 16-byte multiples up to 1 KiB, powers of
//! two above, a freed block reused for the next of its size, behind one lock (the client's
//! threads run at once).
use std::collections::HashMap;
use std::sync::{Mutex, RwLock};

pub const ADDRESS_BITS: u32 = 36;

pub struct Memory {
    base: *mut u8,
    mapped: RwLock<Vec<(u64, u64)>>, // sorted, disjoint [start, end)
}
unsafe impl Send for Memory {}
unsafe impl Sync for Memory {}

pub const PAGE: u64 = 0x4000;

pub fn align(value: u64, to: u64) -> u64 {
    (value + to - 1) & !(to - 1)
}

impl Memory {
    pub fn new() -> Memory {
        let size = 1usize << ADDRESS_BITS;
        let base = unsafe {
            libc::mmap(
                std::ptr::null_mut(),
                size,
                libc::PROT_NONE,
                libc::MAP_PRIVATE | libc::MAP_ANONYMOUS | libc::MAP_NORESERVE,
                -1,
                0,
            )
        };
        assert!(base != libc::MAP_FAILED, "reserving the guest's address space failed");
        Memory { base: base as *mut u8, mapped: RwLock::new(Vec::new()) }
    }

    pub fn base(&self) -> *mut u8 {
        self.base
    }

    /// Make [start, start + size) readable and writable (page-aligned outward). Committed by the
    /// host as it is touched.
    pub fn map(&self, start: u64, size: u64) {
        let first = start & !(PAGE - 1);
        let end = align(start + size, PAGE);
        assert!(end <= 1 << ADDRESS_BITS, "{end:#x} is outside the guest's address space");
        let result = unsafe {
            libc::mprotect(self.base.add(first as usize) as *mut libc::c_void, (end - first) as usize, libc::PROT_READ | libc::PROT_WRITE)
        };
        assert_eq!(result, 0, "mapping {first:#x}..{end:#x} failed");
        let mut ranges = self.mapped.write().unwrap();
        ranges.push((first, end));
        ranges.sort_unstable();
        let mut merged: Vec<(u64, u64)> = Vec::with_capacity(ranges.len());
        for &(s, e) in ranges.iter() {
            match merged.last_mut() {
                Some(last) if s <= last.1 => last.1 = last.1.max(e),
                _ => merged.push((s, e)),
            }
        }
        *ranges = merged;
    }

    pub fn is_mapped(&self, address: u64, size: u64) -> bool {
        let ranges = self.mapped.read().unwrap();
        let i = ranges.partition_point(|&(start, _)| start <= address);
        i > 0 && address + size <= ranges[i - 1].1
    }

    fn host(&self, address: u64, size: usize) -> *mut u8 {
        assert!(self.is_mapped(address, size as u64), "guest access to unmapped {address:#x} (+{size})");
        unsafe { self.base.add(address as usize) }
    }

    pub fn read(&self, address: u64, size: usize) -> Vec<u8> {
        let mut out = vec![0u8; size];
        if size > 0 {
            unsafe { std::ptr::copy_nonoverlapping(self.host(address, size), out.as_mut_ptr(), size) };
        }
        out
    }

    pub fn write(&self, address: u64, data: &[u8]) {
        if !data.is_empty() {
            unsafe { std::ptr::copy_nonoverlapping(data.as_ptr(), self.host(address, data.len()), data.len()) };
        }
    }

    /// A guest slice to read in place (no copy); for large copies and string scans.
    pub fn slice(&self, address: u64, size: usize) -> &[u8] {
        if size == 0 {
            return &[];
        }
        unsafe { std::slice::from_raw_parts(self.host(address, size), size) }
    }

    #[allow(clippy::mut_from_ref)]
    pub fn slice_mut(&self, address: u64, size: usize) -> &mut [u8] {
        if size == 0 {
            return &mut [];
        }
        unsafe { std::slice::from_raw_parts_mut(self.host(address, size), size) }
    }

    pub fn copy(&self, to: u64, from: u64, size: usize) {
        if size > 0 {
            let source = self.host(from, size);
            unsafe { std::ptr::copy(source, self.host(to, size), size) };
        }
    }

    pub fn fill(&self, to: u64, value: u8, size: usize) {
        if size > 0 {
            unsafe { std::ptr::write_bytes(self.host(to, size), value, size) };
        }
    }

    pub fn u8(&self, address: u64) -> u8 {
        unsafe { self.host(address, 1).read() }
    }
    pub fn u16(&self, address: u64) -> u16 {
        unsafe { (self.host(address, 2) as *const u16).read_unaligned() }
    }
    pub fn u32(&self, address: u64) -> u32 {
        unsafe { (self.host(address, 4) as *const u32).read_unaligned() }
    }
    pub fn u64(&self, address: u64) -> u64 {
        unsafe { (self.host(address, 8) as *const u64).read_unaligned() }
    }
    pub fn i32(&self, address: u64) -> i32 {
        self.u32(address) as i32
    }
    pub fn set_u8(&self, address: u64, value: u8) {
        unsafe { self.host(address, 1).write(value) }
    }
    pub fn set_u16(&self, address: u64, value: u16) {
        unsafe { (self.host(address, 2) as *mut u16).write_unaligned(value) }
    }
    pub fn set_u32(&self, address: u64, value: u32) {
        unsafe { (self.host(address, 4) as *mut u32).write_unaligned(value) }
    }
    pub fn set_u64(&self, address: u64, value: u64) {
        unsafe { (self.host(address, 8) as *mut u64).write_unaligned(value) }
    }
    pub fn set_i32(&self, address: u64, value: i32) {
        self.set_u32(address, value as u32)
    }

    /// A NUL-terminated string (lossy UTF-8); empty for a null pointer.
    pub fn cstring(&self, address: u64) -> String {
        String::from_utf8_lossy(&self.cbytes(address)).into_owned()
    }

    pub fn cbytes(&self, address: u64) -> Vec<u8> {
        if address == 0 {
            return Vec::new();
        }
        let mut out = Vec::new();
        let mut at = address;
        loop {
            let byte = self.u8(at);
            if byte == 0 {
                return out;
            }
            out.push(byte);
            at += 1;
        }
    }
}

/// Bump-and-reuse allocation over a mapped region.
pub struct Heap {
    start: u64,
    limit: u64,
    state: Mutex<HeapState>,
}

struct HeapState {
    top: u64,
    sizes: HashMap<u64, u64>,      // live block -> capacity
    spare: HashMap<u64, Vec<u64>>, // capacity -> freed blocks
}

impl Heap {
    pub fn new(memory: &Memory, start: u64, size: u64) -> Heap {
        memory.map(start, size);
        Heap { start, limit: start + size, state: Mutex::new(HeapState { top: start, sizes: HashMap::new(), spare: HashMap::new() }) }
    }

    pub fn capacity_for(size: u64) -> u64 {
        if size <= 1024 { align(size.max(16), 16) } else { size.next_power_of_two() }
    }

    /// A block of at least `size` bytes, 16-aligned; zeroed when `zero` (fresh blocks always are).
    pub fn alloc(&self, memory: &Memory, size: u64, zero: bool) -> Option<u64> {
        let capacity = Heap::capacity_for(size);
        let mut state = self.state.lock().unwrap();
        if let Some(block) = state.spare.get_mut(&capacity).and_then(Vec::pop) {
            state.sizes.insert(block, capacity);
            drop(state);
            if zero {
                memory.fill(block, 0, capacity as usize);
            }
            return Some(block);
        }
        let block = state.top;
        if block + capacity > self.limit {
            return None;
        }
        state.top += capacity;
        state.sizes.insert(block, capacity);
        Some(block)
    }

    /// A block aligned to `alignment` (a power of two above 16), never reused.
    pub fn alloc_aligned(&self, size: u64, alignment: u64) -> Option<u64> {
        let mut state = self.state.lock().unwrap();
        let block = align(state.top, alignment);
        let capacity = Heap::capacity_for(size);
        if block + capacity > self.limit {
            return None;
        }
        state.top = block + capacity;
        state.sizes.insert(block, capacity);
        Some(block)
    }

    /// Free a block this heap handed out; anything else is ignored. True when it was ours.
    pub fn free(&self, block: u64) -> bool {
        let mut state = self.state.lock().unwrap();
        match state.sizes.remove(&block) {
            Some(capacity) => {
                state.spare.entry(capacity).or_default().push(block);
                true
            }
            None => false,
        }
    }

    /// The capacity of a live block, 0 for anything else.
    pub fn size(&self, block: u64) -> u64 {
        self.state.lock().unwrap().sizes.get(&block).copied().unwrap_or(0)
    }

    pub fn used(&self) -> u64 {
        self.state.lock().unwrap().top - self.start
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_reads_writes_and_reuses_blocks() {
        let memory = Memory::new();
        assert!(!memory.is_mapped(0x4_0000_0000, 8));
        let heap = Heap::new(&memory, 0x4_0000_0000, 0x10_0000);
        assert!(memory.is_mapped(0x4_0000_0000, 0x10_0000));
        let a = heap.alloc(&memory, 20, true).unwrap();
        assert_eq!(heap.size(a), 32);
        memory.write(a, b"hello\0");
        assert_eq!(memory.cstring(a), "hello");
        assert!(heap.free(a));
        assert!(!heap.free(a));
        let b = heap.alloc(&memory, 30, true).unwrap();
        assert_eq!(b, a, "a freed block of the same capacity is reused");
        assert_eq!(memory.u64(b), 0, "and zeroed when asked");
        assert_eq!(Heap::capacity_for(1025), 2048);
    }
}
