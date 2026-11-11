//! malloc and the rest, operator new and delete, malloc zones, mmap, and the mem* routines, on
//! the machine's heap (src/memory.rs), in the host's own code.
use super::{Ctx, Registry, Stop};

pub fn register(r: &mut Registry) {
    r.answer(&["_malloc", "__Znwm", "__Znam", "__ZnwmRKSt9nothrow_t"], |c| alloc(c, c.arg(0)));
    r.answer(&["_calloc"], |c| alloc(c, c.arg(0).saturating_mul(c.arg(1))));
    r.answer(&["_valloc"], |c| alloc(c, c.arg(0)));
    r.answer(&["_realloc"], |c| realloc(c, c.arg(0), c.arg(1)));
    r.answer(&["_free", "__ZdlPv", "__ZdaPv", "__ZdlPvm"], |c| {
        c.m.heap.free(c.arg(0));
        Ok(None)
    });
    r.answer(&["_malloc_size"], |c| Ok(Some(c.m.heap.size(c.arg(0)))));
    r.answer(&["_posix_memalign"], |c| {
        let (out, alignment, size) = (c.arg(0), c.arg(1), c.arg(2));
        let block = if alignment <= 16 { c.m.heap.alloc(&c.m.memory, size, false) } else { c.m.heap.alloc_aligned(size, alignment) };
        let block = block.ok_or_else(|| heap_full(size))?;
        c.mem().set_u64(out, block);
        Ok(Some(0))
    });

    // malloc_zone_t: two reserved words, then size, malloc, calloc, valloc, free, realloc,
    // destroy and zone_name; the client calls through it directly (zone->size), so every slot
    // is a function. One zone stands for all.
    r.answer(&["zone.size"], |c| Ok(Some(c.m.heap.size(c.arg(1)))));
    r.answer(&["zone.malloc", "zone.valloc", "_malloc_zone_malloc"], |c| alloc(c, c.arg(1)));
    r.answer(&["zone.calloc", "_malloc_zone_calloc"], |c| alloc(c, c.arg(1).saturating_mul(c.arg(2))));
    r.answer(&["zone.free", "_malloc_zone_free"], |c| {
        c.m.heap.free(c.arg(1));
        Ok(None)
    });
    r.answer(&["zone.realloc", "_malloc_zone_realloc"], |c| realloc(c, c.arg(1), c.arg(2)));
    r.answer(&["zone.destroy", "_malloc_set_zone_name"], |_| Ok(None));
    r.answer(&["_malloc_default_zone", "_malloc_create_zone"], |c| {
        let zone = *c.m.zone.get_or_init(|| {
            let zone = c.m.alloc(256);
            for (i, name) in ["size", "malloc", "calloc", "valloc", "free", "realloc", "destroy"].iter().enumerate() {
                c.mem().set_u64(zone + 0x10 + 8 * i as u64, c.m.slot_address(&format!("zone.{name}")));
            }
            zone
        });
        Ok(Some(zone))
    });

    // An mmap is a page-aligned block of the heap, filled from the file when it maps one.
    r.answer(&["_mmap"], |c| {
        let (length, fd, offset) = (c.arg(1), c.arg32(4) as i32, c.arg(5));
        c.m.report.mapping(length);
        let raw = c.m.heap.alloc(&c.m.memory, length + 0x4000, true).ok_or_else(|| heap_full(length))?;
        let block = crate::memory::align(raw, 0x4000);
        c.state::<Mappings>().lock().unwrap().0.insert(block, raw);
        if fd >= 0 {
            crate::hle::files::map_into(c, fd, offset, block, length);
        }
        Ok(Some(block))
    });
    r.answer(&["_munmap"], |c| {
        if let Some(raw) = c.state::<Mappings>().lock().unwrap().0.remove(&c.arg(0)) {
            c.m.heap.free(raw);
        }
        Ok(Some(0))
    });

    r.answer(&["_memcpy", "_memmove", "___memcpy_chk", "___memmove_chk"], |c| {
        c.mem().copy(c.arg(0), c.arg(1), c.arg(2) as usize);
        Ok(Some(c.arg(0)))
    });
    r.answer(&["_memset", "___memset_chk"], |c| {
        c.mem().fill(c.arg(0), c.arg(1) as u8, c.arg(2) as usize);
        Ok(Some(c.arg(0)))
    });
    r.answer(&["_bzero"], |c| {
        c.mem().fill(c.arg(0), 0, c.arg(1) as usize);
        Ok(None)
    });
    r.answer(&["_memset_pattern16"], |c| {
        let pattern = c.mem().read(c.arg(1), 16);
        let target = c.mem().slice_mut(c.arg(0), c.arg(2) as usize);
        for (i, byte) in target.iter_mut().enumerate() {
            *byte = pattern[i % 16];
        }
        Ok(None)
    });
    r.answer(&["_memcmp"], |c| {
        let n = c.arg(2) as usize;
        let (a, b) = (c.mem().slice(c.arg(0), n), c.mem().slice(c.arg(1), n));
        Ok(Some(match a.iter().zip(b).find(|(x, y)| x != y) {
            Some((x, y)) => (*x as i32 - *y as i32) as i64 as u64,
            None => 0,
        }))
    });
    r.answer(&["_memchr"], |c| {
        let (start, value, n) = (c.arg(0), c.arg(1) as u8, c.arg(2) as usize);
        Ok(Some(c.mem().slice(start, n).iter().position(|&b| b == value).map_or(0, |i| start + i as u64)))
    });

    // The client's thread-local variables, for any descriptor still bound here (the loader
    // gives the client's its own arm64: src/loader.rs).
    r.answer(&["__tlv_bootstrap"], |c| Ok(Some(c.cpu.tpidr() + c.mem().u64(c.arg(0) + 16))));
}

#[derive(Default)]
struct Mappings(std::collections::HashMap<u64, u64>);

fn heap_full(size: u64) -> Stop {
    Stop(format!("the heap is full (asked for {size} bytes)"))
}

fn alloc(c: &mut Ctx, size: u64) -> Result<Option<u64>, Stop> {
    Ok(Some(c.m.heap.alloc(&c.m.memory, size, true).ok_or_else(|| heap_full(size))?))
}

fn realloc(c: &mut Ctx, pointer: u64, size: u64) -> Result<Option<u64>, Stop> {
    let old = if pointer != 0 { c.m.heap.size(pointer) } else { 0 };
    if pointer != 0 && old >= size {
        return Ok(Some(pointer));
    }
    let new = c.m.heap.alloc(&c.m.memory, size, false).ok_or_else(|| heap_full(size))?;
    if pointer != 0 {
        c.mem().copy(new, pointer, old.min(size) as usize);
        c.m.heap.free(pointer);
    }
    Ok(Some(new))
}
