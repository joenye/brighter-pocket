// The scheduler's turns for the boot harness (threads.py), counted on the host: a Unicorn block
// hook in C that stops the emulator once a thread has run its share of translated blocks.
// Unicorn's own instruction count (emu_start's count) runs a callback for every instruction and
// made the client's code about four times slower; this one runs once a block, and like the
// count it ends a turn at the same place on every run. Built by threads.py with the host's cc.
#include <stdint.h>

typedef struct {
    uint64_t blocks;            // run in this turn
    uint64_t limit;             // the turn's share
    int (*stop)(void *engine);  // uc_emu_stop
} Turn;

void pocket_turn_block(void *engine, uint64_t address, uint32_t size, void *user) {
    Turn *turn = user;
    (void)address;
    (void)size;
    if (++turn->blocks == turn->limit) turn->stop(engine);
}
