# The emulator

`emulator/` runs the macOS client's own arm64 code on an Apple silicon Mac as iOS would run it
with this layer, with the layer's adapters as their arm64 iOS builds, for checks without a
device: startup to its first frames (`tests/run.sh`), the threads loading the game to its menu
(about 15 s), clicks, and, with `--network`, the game's sign-in. It is a Rust
program over **dynarmic**, an arm64 JIT, on its arm64 backend. It replaced a Python harness on Unicorn, whose answers stopped the emulator for
Python on every call, whose threads took turns on one core, and whose hooks slowed the client's
own code several times over: it took 6.5 minutes to the menu.

## Setup and use

```bash
tools/setup_emulator.sh              # dynarmic (pinned, patched) and Boost's headers into .toolchain/emulator/
cd emulator && cargo build --release # emulator/target/release/pocket-emulator
emulator/target/release/pocket-emulator --frames 3 --check            # what tests/run.sh runs
emulator/target/release/pocket-emulator --frames 6000 [--click X,Y@FRAME ...]
emulator/target/release/pocket-emulator --network [--steam-live] [--reach NAME:PORT ...] [--record-network FILE] [--probe-network HOST[:PORT]]
```

It needs Homebrew's `cargo` and `cmake`, Xcode's clang (the Command Line Tools, or
`DEVELOPER_DIR` in `local.env`), the client (`tools/fetch_client.py`) and the app's adapters
(`tools/build_ios.py`: `build/ios/Payload/BrighterPocket.app/Frameworks`). `cargo test
--release` runs its unit tests; `cargo test --release live_session -- --ignored` is the live
check of the app's Steam session core against Steam itself, by hand (one session per account:
not while the account is playing elsewhere). `--steam-live` and that check use DepotDownloader's remembered login,
which .NET keeps under `~/Library/Application Support/IsolatedStorage`; no token is printed.

## The network

By default nothing leaves the Mac: every lookup of a name fails (`EAI_NONAME`, as on a phone
with no network) and every connect is unreachable, so `tests/run.sh` is hermetic.

- `--network`: the device is online. The client's `getaddrinfo` is answered by the Mac's own
  resolver (its IPv4 addresses) and its stream connects go straight out from the Mac, as a
  phone's do; reads, writes and poll are the host socket's.
- `--steam-live` (needs `--network`): the bridge the game's Steam library reaches answers with a
  real Steam session (`STEAM_USER`'s login as DepotDownloader remembers it), connected directly.
- `--reach NAME:PORT` (repeatable): only these servers, by the name the client looked up; any
  other connect is refused as with no network.
- `--record-network FILE`: every read and write on the game's connections (frame, peer,
  direction, hex). It holds the Steam ticket: keep it under `build/`.
- `--probe-network HOST[:PORT]`: after the initializers, fetch `http://HOST/` through the
  client's own `getaddrinfo` and `connect` answers, print what came back, and stop. Without
  `--network` it stops at the lookup.

## dynarmic

`tools/setup_emulator.sh` builds azahar-emu's dynarmic at a pinned commit (its master on
2026-11-12) for the A64 frontend on the arm64 backend, with the patches in
`emulator/dynarmic-patches/` applied in order (each says why at its top). That backend lacked
what the client needs and the x64 one has: an instruction dynarmic does not decode ends its
block with an Interpret terminal, which reached an assertion instead of
`InterpreterFallback` (0001); and emitters for the 64-bit vector compares the client uses, the
scalar saturating arithmetic (0002) and the half-precision arithmetic the frontend translates
(0003). Each patched emitter is the host's own instruction; `cargo test` runs each through the
JIT and on the Mac's CPU and compares them (`src/cpu.rs`). A few opcodes the frontend at this
commit never emits remain unimplemented in the backend. Fastmem is dynarmic's Mach exception
handler: a load or store to an unmapped guest page is recompiled through the callbacks, which
report it.

## How it runs the client

- **Memory** is one host reservation of 2^36 bytes, guest address `a` at `base + a`
  (`src/memory.rs`), so the JIT's loads and stores go straight to it (dynarmic's fastmem). The
  client sits at its own addresses, the adapters beside it, the answered imports' slots and
  imported data after them, and one heap of 4 GiB for the client's malloc, stacks and the
  harness's objects (`src/machine.rs` has the map).
- **Loading** (`src/loader.rs`, `src/macho.rs`) applies every chained fixup. A bind goes to an
  adapter's export when the client imports it from that adapter's library (the Steam calls; the
  container paths' opendir), to an imported data symbol when it is data, and to
  an answered import's slot otherwise. The client's thread-local variables get four arm64
  instructions on the thread's own block (TPIDR_EL0) in place of dyld's lookup.
- **Answered imports** (`src/hle/`): each slot is `svc #id; br x16`. The JIT calls back into
  Rust only when one runs; the answer reads the Apple arm64 calling convention's registers and
  stack slots and returns x0. Anything not answered stops the run with its name, so the model
  grows only where the client goes. Modules: memory and the mem* routines, the C library and
  the container's file system (`libsystem.rs`, `files.rs`), Objective-C with Tolkara's AppKit
  coverage (`objc.rs`), Metal with the on-device rewrap's shader checks (`metal.rs`), and the
  network (`network.rs`).
- **Threads** (`src/runtime.rs`): every thread the client starts runs at once on a host thread of
  its own with its own JIT, as on the device; they share memory and one exclusive monitor, so
  the client's atomics hold across them. The few ARMv8.1 instructions dynarmic does not decode
  (LDADD, LDAPR: 43 in the client) are done on the host's own atomics. Mutexes, condition
  variables, futures, semaphores, joins and sleeps are host waits behind one lock. Metal's
  completion handlers run on pooled workers, whose JITs keep their translated code.
- **Clocks** are the host's: the client's time agrees with its servers'. A present waits for the
  next sixtieth of a second, as the display's vertical sync makes it wait, which leaves the
  loading threads their share. Runs are not repeatable instruction for instruction, as on a
  device. A bundle file is read from disk once and shared by every open and mmap of it.

Measured on an M3 Pro Mac (12 cores, 36 GB, 2026-11-12, the client of 2026-11-12): to frame
3 with `--check` in about 8 to 9 s (18 s on the first run after building); the loading screen
(13 meshes a frame) gives way to the menu (25 a frame) at about frame 600, 13 to 15 s in, with
the heap near 1.1 GB; the menu draws at about 58 frames a second, close to the 60 the presents
are paced to; 7,000 frames take about 133 s, and the host holds 4.7 to 5.3 GB at most.

## What it cannot do

It draws nothing (no GPU: Metal's objects are stand-ins; buffers are real memory), so it
cannot see a screen or aim a click at a button. Input is a click at a point at a frame.
