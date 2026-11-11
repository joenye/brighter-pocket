// Tolkara's loader (platform/runtime: GuestImage, GuestLink, GuestFixups) on the real
// client, on the host: it reads the executable as the device's launcher does, finds
// the libraries the staged application carries, and applies every chained fixup in its
// own memory with a slide, binding each import as the device would plan it. Nothing is
// executed. tests/loader_check.py runs it and compares every written pointer with
// tools/macho.py's independent reading of the same file.
//
// usage: loader_test <executable> <steam exports file> <observed out> <slide hex>
//   steam exports: the symbols the iOS-built libsteam_api adapter defines, one per line
//   observed out: one line per written pointer: <address hex> <value hex> <symbol or ->
#include "GuestFixups.h"
#include "GuestImage.h"
#include "GuestLink.h"
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { BIND_SPECIAL_WEAK = -3, BIND_SPECIAL_FLAT = -2, BIND_SPECIAL_MAIN = -1, BIND_SPECIAL_SELF = 0 };
#define SYSTEM_BASE 0x7f0000000000ULL   // where the device's system libraries would answer

typedef struct {
    const GuestImage *image;
    const GuestLinkSet *carried;
    const char *path;
    char steam[64][64];
    size_t steam_count;
    unsigned steam_binds, system_binds, own_binds, unresolved;
} Binder;

static const char *leaf(const char *path) {
    const char *slash = strrchr(path, '/');
    return slash ? slash + 1 : path;
}

static bool resolve(const char *symbol, int ordinal, bool weak, bool lazy, uint64_t *value, void *context) {
    (void)lazy;
    Binder *b = context;
    // The application itself first, as the device's resolve() does (gl_lookup).
    uint64_t own = 0;
    if (gl_lookup(b->carried, b->image, b->path, ordinal, symbol, &own, NULL)) {
        b->own_binds++;
        *value = own;
        return true;
    }
    if (ordinal > 0 && (size_t)ordinal <= b->image->dylib_count &&
        !strcmp(leaf(b->image->dylibs[ordinal - 1]), "libsteam_api.dylib")) {
        // Not carried: the adapter must define it.
        for (size_t i = 0; i < b->steam_count; i++)
            if (!strcmp(b->steam[i], symbol)) {
                b->steam_binds++;
                *value = SYSTEM_BASE - 0x100000 + i * 16;
                return true;
            }
        fprintf(stderr, "unresolved: %s is not defined by the libsteam_api adapter\n", symbol);
        b->unresolved++;
        return weak;
    }
    if (ordinal == BIND_SPECIAL_SELF || ordinal == BIND_SPECIAL_MAIN) {
        fprintf(stderr, "unresolved: %s (ordinal %d) is not exported by the executable\n", symbol, ordinal);
        b->unresolved++;
        return weak;
    }
    // A system library or an adapter on the device; tools/analyze_client.py checks
    // each of these names against the iOS SDK and the adapters.
    b->system_binds++;
    *value = SYSTEM_BASE + (uint64_t)b->system_binds * 16;
    return true;
}

typedef struct { FILE *out; unsigned rebases, binds; } Observer;
static void observe(uint64_t address, uint64_t value, const char *symbol, void *context) {
    Observer *o = context;
    fprintf(o->out, "%" PRIx64 " %" PRIx64 " %s\n", address, value, symbol ? symbol : "-");
    if (symbol) o->binds++; else o->rebases++;
}

int main(int argc, char **argv) {
    if (argc != 5) {
        fprintf(stderr, "usage: %s <executable> <steam exports> <observed out> <slide hex>\n", argv[0]);
        return 2;
    }
    static GuestImage image;
    char error[512];
    if (!gi_load(argv[1], &image, error, sizeof error)) { fprintf(stderr, "gi_load: %s\n", error); return 1; }
    gi_report(&image, stdout);

    // What the application carries, from where the launcher would find it.
    static GuestLinkSet carried;
    if (!gl_load(&carried, &image, argv[1], error, sizeof error)) { fprintf(stderr, "gl_load: %s\n", error); return 1; }
    carried.executable_image = &image;
    printf("carried libraries: %zu (refused %zu)\n", carried.count, carried.refused);
    for (size_t i = 0; i < carried.count; i++) printf("  carried %s\n", carried.libraries[i].install_name);

    Binder binder = {.image = &image, .carried = &carried, .path = argv[1]};
    FILE *exports = fopen(argv[2], "r");
    if (!exports) { perror(argv[2]); return 1; }
    while (binder.steam_count < 64 && fgets(binder.steam[binder.steam_count], 64, exports)) {
        binder.steam[binder.steam_count][strcspn(binder.steam[binder.steam_count], "\r\n")] = 0;
        if (binder.steam[binder.steam_count][0]) binder.steam_count++;
    }
    fclose(exports);

    uint64_t slide = strtoull(argv[4], NULL, 16);
    carried.executable_slide = slide;
    Observer observer = {.out = fopen(argv[3], "w")};
    if (!observer.out) { perror(argv[3]); return 1; }
    GFStats stats = {0};
    bool ok = gf_apply_observed(&image, slide, resolve, &binder, observe, &observer, &stats, error, sizeof error);
    fclose(observer.out);
    printf("fixups: %s rebases=%zu binds=%zu (observed %u rebases, %u binds)\n", ok ? "applied" : error,
           stats.rebases, stats.binds, observer.rebases, observer.binds);
    printf("binds: system=%u steam=%u own=%u unresolved=%u\n", binder.system_binds, binder.steam_binds,
           binder.own_binds, binder.unresolved);
    printf("initializers=%" PRIu64 " tls=%d tls_initializers=%" PRIu64 " entry=%#" PRIx64 "\n",
           image.initializer_count, image.has_tls, image.tls_initializer_count, image.entry);
    bool good = ok && !binder.unresolved && carried.count == 0;
    gl_destroy(&carried);
    gi_destroy(&image);
    return good ? 0 : 1;
}
