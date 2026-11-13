// One zstd frame decoded (PocketZstd.c): the bytes written, or (size_t)-1 if the input is bad or
// does not fit output_size bytes. Safe to call from several threads at once.
#pragma once
#include <stddef.h>

size_t pocket_zstd_decompress(void *output, size_t output_size, const void *input, size_t input_size);
