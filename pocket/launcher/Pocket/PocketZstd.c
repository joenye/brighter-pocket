// zstd for Steam's depot chunks (PocketDepot.m): the zstd project's reference decoder,
// zstd/zstd_decompress.inc, unchanged (facebook/zstd doc/educational_decoder at commit
// fe34776c207f3f879f386ed4158a38d927ff6d10, BSD licence in zstd/LICENSE; iOS has no zstd of
// its own). It ends the process on bad input; here a bad chunk returns an error instead: its
// exit goes back to the call that began the decode. (What that decode had allocated is lost;
// a bad chunk is rare and is fetched again from another server.)
#include "PocketZstd.h"
#include <setjmp.h>
#include <stdlib.h>

static _Thread_local jmp_buf *escape;
static void decodeFailed(void) __attribute__((noreturn));
static void decodeFailed(void) { longjmp(*escape, 1); }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#define exit(code) decodeFailed()
#include "zstd/zstd_decompress.inc"
#undef exit
#pragma clang diagnostic pop

size_t pocket_zstd_decompress(void *output, size_t output_size, const void *input, size_t input_size) {
    jmp_buf here;
    jmp_buf *previous = escape;
    escape = &here;
    size_t made = setjmp(here) ? (size_t)-1 : ZSTD_decompress(output, output_size, input, input_size);
    escape = previous;
    return made;
}
