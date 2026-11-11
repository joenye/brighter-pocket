// The client's allocator and memory routines for the boot harness, in arm64: built for iOS by
// tests/emulate/native.py and loaded beside the client, so the calls the client makes most
// (calloc, free, memcpy, malloc, bzero: nine in ten of all its calls while it loads) run as
// emulated instructions instead of each stopping the emulator for Python.
//
// The heap is its own region (pocket_heap_base to pocket_heap_limit, set by the harness).
// Blocks carry a 16-byte header with their capacity; capacities are multiples of 16 up to
// 1 KiB, then powers of two; a freed block goes on its capacity's list for the next block of
// that capacity. A pointer from outside the region (a block the harness made in Python) goes to
// the harness. Threads run by turns and a turn can end anywhere, so the lists sit behind a spin
// lock that yields its turn while another thread holds it.
#include <stddef.h>
#include <stdint.h>

#define EXPORT __attribute__((visibility("default"), used))
#define NO_IDIOMS __attribute__((no_builtin))

// Answered by the harness in Python (hle.py: "the native heap").
extern void pocket_foreign_free(void *pointer);
extern void *pocket_foreign_realloc(void *pointer, size_t size);
extern size_t pocket_foreign_size(const void *pointer);
extern void pocket_bulk_copy(void *to, const void *from, size_t size);
extern void pocket_bulk_fill(void *to, int value, size_t size);
extern void pocket_heap_full(size_t size);
extern int sched_yield(void);

EXPORT uintptr_t pocket_heap_base, pocket_heap_limit, pocket_heap_top;

enum { SMALL_CLASSES = 64, CLASSES = SMALL_CLASSES + 48, HEADER = 16, BULK = 64 * 1024 };
static void *free_lists[CLASSES];
static volatile int heap_lock;

typedef struct { uint64_t capacity, magic; } Header;
#define MAGIC 0x506f636b65744870ull   // "PocketHp"

static void lock(void) {
    while (__atomic_exchange_n(&heap_lock, 1, __ATOMIC_ACQUIRE)) sched_yield();
}
static void unlock(void) { __atomic_store_n(&heap_lock, 0, __ATOMIC_RELEASE); }

static int ours(const void *pointer) {
    uintptr_t p = (uintptr_t)pointer;
    return p >= pocket_heap_base + HEADER && p < pocket_heap_limit;
}

// The class of a request, and its capacity.
static unsigned class_of(size_t size, uint64_t *capacity) {
    if (size <= 16 * SMALL_CLASSES) {
        size_t units = size ? (size + 15) / 16 : 1;
        *capacity = units * 16;
        return (unsigned)(units - 1);
    }
    unsigned shift = 64 - (unsigned)__builtin_clzll(size - 1);   // the power of two at or above
    *capacity = 1ull << shift;
    return SMALL_CLASSES + shift - 10;
}

NO_IDIOMS static void fill(void *to, int value, size_t size) {
    if (size >= BULK) { pocket_bulk_fill(to, value, size); return; }
    uint8_t *d = to;
    uint64_t word = (uint8_t)value * 0x0101010101010101ull;
    while (size && ((uintptr_t)d & 7)) { *d++ = (uint8_t)value; size--; }
    for (; size >= 32; size -= 32, d += 32) {
        ((volatile uint64_t *)d)[0] = word; ((volatile uint64_t *)d)[1] = word;
        ((volatile uint64_t *)d)[2] = word; ((volatile uint64_t *)d)[3] = word;
    }
    for (; size >= 8; size -= 8, d += 8) *(volatile uint64_t *)d = word;
    while (size--) *d++ = (uint8_t)value;
}

NO_IDIOMS static void copy_forward(uint8_t *d, const uint8_t *s, size_t size) {
    if ((((uintptr_t)d | (uintptr_t)s) & 7) == 0) {
        for (; size >= 32; size -= 32, d += 32, s += 32) {
            uint64_t a = ((const uint64_t *)s)[0], b = ((const uint64_t *)s)[1];
            uint64_t c = ((const uint64_t *)s)[2], e = ((const uint64_t *)s)[3];
            ((volatile uint64_t *)d)[0] = a; ((volatile uint64_t *)d)[1] = b;
            ((volatile uint64_t *)d)[2] = c; ((volatile uint64_t *)d)[3] = e;
        }
        for (; size >= 8; size -= 8, d += 8, s += 8) *(volatile uint64_t *)d = *(const uint64_t *)s;
    }
    while (size--) *(volatile uint8_t *)d++ = *s++;
}

NO_IDIOMS static void copy_backward(uint8_t *d, const uint8_t *s, size_t size) {
    d += size; s += size;
    while (size--) *(volatile uint8_t *)--d = *--s;
}

EXPORT NO_IDIOMS void *malloc(size_t size) {
    uint64_t capacity;
    unsigned c = class_of(size, &capacity);
    lock();
    void *block = free_lists[c];
    if (block) {
        free_lists[c] = *(void **)block;
    } else {
        uintptr_t start = pocket_heap_top;
        if (start + HEADER + capacity > pocket_heap_limit) {
            unlock();
            pocket_heap_full(size);
            return NULL;
        }
        pocket_heap_top = start + HEADER + capacity;
        Header *header = (Header *)start;
        header->capacity = capacity;
        header->magic = MAGIC;
        block = (void *)(start + HEADER);
    }
    unlock();
    return block;
}

EXPORT NO_IDIOMS void free(void *pointer) {
    if (!pointer) return;
    if (!ours(pointer)) { pocket_foreign_free(pointer); return; }
    Header *header = (Header *)((uintptr_t)pointer - HEADER);
    if (header->magic != MAGIC) return;   // not a block's start: leave it
    uint64_t capacity;
    unsigned c = class_of(header->capacity, &capacity);
    lock();
    *(void **)pointer = free_lists[c];
    free_lists[c] = pointer;
    unlock();
}

EXPORT NO_IDIOMS size_t malloc_size(const void *pointer) {
    if (!pointer) return 0;
    if (!ours(pointer)) return pocket_foreign_size(pointer);
    const Header *header = (const Header *)((uintptr_t)pointer - HEADER);
    return header->magic == MAGIC ? header->capacity : 0;
}

EXPORT NO_IDIOMS void *calloc(size_t count, size_t size) {
    size_t total = count * size;
    void *block = malloc(total);
    if (block) fill(block, 0, total);   // a reused block holds its last owner's bytes
    return block;
}

EXPORT NO_IDIOMS void *memcpy(void *to, const void *from, size_t size) {
    if (size >= BULK) pocket_bulk_copy(to, from, size);
    else copy_forward(to, from, size);
    return to;
}

EXPORT NO_IDIOMS void *memmove(void *to, const void *from, size_t size) {
    if (size >= BULK) pocket_bulk_copy(to, from, size);   // the harness copies as memmove does
    else if ((uintptr_t)to <= (uintptr_t)from || (uintptr_t)to >= (uintptr_t)from + size) copy_forward(to, from, size);
    else copy_backward(to, from, size);
    return to;
}

EXPORT NO_IDIOMS void *realloc(void *pointer, size_t size) {
    if (!pointer) return malloc(size);
    if (!ours(pointer)) return pocket_foreign_realloc(pointer, size);
    size_t capacity = malloc_size(pointer);
    if (capacity >= size) return pointer;
    void *block = malloc(size);
    if (block) {
        memcpy(block, pointer, capacity);
        free(pointer);
    }
    return block;
}

EXPORT NO_IDIOMS void *memset(void *to, int value, size_t size) { fill(to, value, size); return to; }
EXPORT NO_IDIOMS void bzero(void *to, size_t size) { fill(to, 0, size); }
EXPORT NO_IDIOMS void *__memcpy_chk(void *to, const void *from, size_t size, size_t room) { (void)room; return memcpy(to, from, size); }
EXPORT NO_IDIOMS void *__memmove_chk(void *to, const void *from, size_t size, size_t room) { (void)room; return memmove(to, from, size); }
EXPORT NO_IDIOMS void *__memset_chk(void *to, int value, size_t size, size_t room) { (void)room; return memset(to, value, size); }

// operator new and delete, and malloc_zone_t's functions (the zone itself is ignored).
EXPORT void *_Znwm(size_t size) { return malloc(size); }
EXPORT void *_Znam(size_t size) { return malloc(size); }
EXPORT void _ZdlPv(void *pointer) { free(pointer); }
EXPORT void _ZdaPv(void *pointer) { free(pointer); }
EXPORT size_t pocket_zone_size(void *zone, const void *pointer) { (void)zone; return malloc_size(pointer); }
EXPORT void *pocket_zone_malloc(void *zone, size_t size) { (void)zone; return malloc(size); }
EXPORT void *pocket_zone_calloc(void *zone, size_t count, size_t size) { (void)zone; return calloc(count, size); }
EXPORT void *pocket_zone_valloc(void *zone, size_t size) { (void)zone; return malloc(size); }
EXPORT void pocket_zone_free(void *zone, void *pointer) { (void)zone; free(pointer); }
EXPORT void *pocket_zone_realloc(void *zone, void *pointer, size_t size) { (void)zone; return realloc(pointer, size); }
EXPORT void *malloc_zone_malloc(void *zone, size_t size) { (void)zone; return malloc(size); }
EXPORT void *malloc_zone_realloc(void *zone, void *pointer, size_t size) { (void)zone; return realloc(pointer, size); }
EXPORT void malloc_zone_free(void *zone, void *pointer) { (void)zone; free(pointer); }
