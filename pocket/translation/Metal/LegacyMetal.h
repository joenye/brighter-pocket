// AIR 1.x Metal libraries, for LibraryContainer.m's rewrap (pocket/patches/0003).
//
// Brighter Shores ships its shaders as container-version-2 libraries holding AIR 1.8
// (VERS 1.8), the format of Xcode 9 and older. Their function records name no module
// size (no MDSZ tag): a function's module runs from its OFFT module offset to the next
// function's module, or to the end of the code section, and its HASH covers exactly
// that range. Header-only, so the shim builder and the app target, which both compile
// LibraryContainer.m, need nothing more; tests/metal_test.c checks it on the host.
#pragma once
#include <stdbool.h>
#include <stdint.h>

static inline uint64_t AKMetalNumber(const uint8_t *p, unsigned count) {
    uint64_t value = 0;
    for (unsigned i = 0; i < count; i++) value |= (uint64_t)p[i] << (8 * i);
    return value;
}

// Where the module at `offset` ends, within a code section of `code_size` bytes: the
// smallest module offset after it among the function records of the table at `table`
// (which ends where the public metadata starts, at `public_start`), else the section's
// end. Records the caller validates; here a malformed one only stops the scan, so the
// answer never exceeds code_size and is never below offset.
static inline uint64_t AKMetalModuleEnd(const uint8_t *b, uint64_t table, uint64_t public_start,
                                        uint64_t offset, uint64_t code_size) {
    uint64_t end = code_size > offset ? code_size : offset;
    if (public_start < table || public_start - table < 4) return end;
    uint64_t count = AKMetalNumber(b + table, 4), pos = table + 4;
    for (uint64_t i = 0; i < count; i++) {
        if (public_start - pos < 4) break;
        uint64_t size = AKMetalNumber(b + pos, 4);
        if (size < 8 || size > public_start - pos) break;
        uint64_t record_end = pos + size;
        pos += 4;
        while (record_end - pos >= 6) {
            const uint8_t *tag = b + pos;
            if (tag[0] == 'E' && tag[1] == 'N' && tag[2] == 'D' && tag[3] == 'T') break;
            uint64_t n = AKMetalNumber(b + pos + 4, 2);
            pos += 6;
            if (n > record_end - pos) break;
            if (tag[0] == 'O' && tag[1] == 'F' && tag[2] == 'F' && tag[3] == 'T' && n == 24) {
                uint64_t other = AKMetalNumber(b + pos + 16, 8);
                if (other > offset && other < end) end = other;
            }
            pos += n;
        }
        pos = record_end;
    }
    return end;
}
