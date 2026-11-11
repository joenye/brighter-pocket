// AKMetalModuleEnd (pocket/translation/Metal/LegacyMetal.h) on the host, over function
// tables built here: where an AIR 1.x module without MDSZ ends. The client's own 536
// libraries are checked by tools/check_shaders.py, which ports the same rule.
#include "LegacyMetal.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static unsigned char lib[512];
static size_t at;

static void put(const void *bytes, size_t n) { memcpy(lib + at, bytes, n); at += n; }
static void u16(uint16_t v) { put(&v, 2); }
static void u32(uint32_t v) { put(&v, 4); }
static void u64(uint64_t v) { put(&v, 8); }
// One function record: NAME, OFFT (public, private, module offsets), optional MDSZ, ENDT.
static void record(uint64_t module, int with_offsets) {
    size_t start = at;
    u32(0);   // size, filled in below
    put("NAME", 4); u16(2); put("f", 2);
    if (with_offsets) { put("OFFT", 4); u16(24); u64(0); u64(0); u64(module); }
    put("ENDT", 4);
    uint32_t size = (uint32_t)(at - start);
    memcpy(lib + start, &size, 4);
}

int main(void) {
    // Three functions whose modules are out of order: 0x200, 0x40, 0x100, in 0x300 of code.
    at = 100;
    u32(3);
    record(0x200, 1); record(0x40, 1); record(0x100, 1);
    uint64_t pub = at;
    assert(AKMetalModuleEnd(lib, 100, pub, 0x40, 0x300) == 0x100);
    assert(AKMetalModuleEnd(lib, 100, pub, 0x100, 0x300) == 0x200);
    assert(AKMetalModuleEnd(lib, 100, pub, 0x200, 0x300) == 0x300);   // the last runs to the section's end
    assert(AKMetalModuleEnd(lib, 100, pub, 0x0, 0x300) == 0x40);
    // An offset past the section never yields an end before it.
    assert(AKMetalModuleEnd(lib, 100, pub, 0x400, 0x300) == 0x400);

    // One function, as every Brighter Shores library has: to the section's end.
    at = 100;
    u32(1);
    record(0, 1);
    assert(AKMetalModuleEnd(lib, 100, at, 0, 0x1234) == 0x1234);

    // A record without OFFT is skipped; a count larger than the table stops at its end.
    at = 100;
    u32(5);
    record(0, 0); record(0x80, 1);
    pub = at;
    assert(AKMetalModuleEnd(lib, 100, pub, 0, 0x100) == 0x80);
    // A record whose size runs past the table stops the scan without reading past it.
    uint32_t huge = 4096;
    memcpy(lib + 104, &huge, 4);
    assert(AKMetalModuleEnd(lib, 100, pub, 0, 0x100) == 0x100);
    // A table too small for its count field.
    assert(AKMetalModuleEnd(lib, 100, 102, 0, 0x100) == 0x100);
    puts("metal: ok");
    return 0;
}
