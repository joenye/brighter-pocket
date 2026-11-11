# The emulator

`emulator/` runs the macOS client's own arm64 code on Linux, with this layer's adapters as
their arm64 iOS builds, for checks without a device: startup to its first frames
(`tests/run.sh`), the threads loading the game to its menu (about 30 s), clicks, and, through the
VPN, the game's sign-in (`docs/vpn.md`). It is a Rust program over **dynarmic**, the
arm64-to-x86-64 JIT (Joe, 2026-11-11: "get everything into rust"). It replaced a Python harness
on Unicorn, whose answers stopped the emulator for Python on every call, whose threads took turns
on one core, and whose hooks slowed the client's own code several times over: it took 6.5 minutes
to the menu.

## Setup and use

```bash
tools/linux/setup_emulator.sh        # dynarmic (pinned) and Boost's headers into .toolchain/emulator/
cd emulator && cargo build --release # emulator/target/release/pocket-emulator
emulator/target/release/pocket-emulator --frames 3 --check            # what tests/run.sh runs
emulator/target/release/pocket-emulator --frames 6000 [--click X,Y@FRAME ...]
emulator/target/release/pocket-emulator --vpn [--steam-live] [--probe-network HOST] ...   # docs/vpn.md
```

It needs the client (`tools/fetch_client.py`) and the app's adapters (`tools/build_ios.py`:
`build/ios/Payload/BrighterPocket.app/Frameworks`). `cargo test --release` runs its unit tests;
`cargo test --release live_session -- --ignored` is the live check of the app's Steam session
core against Steam itself, through the VPN, by hand (one session per account: not while Joe
plays).

## How it runs the client

- **Memory** is one host reservation of 2^36 bytes, guest address `a` at `base + a`
  (`src/memory.rs`), so the JIT's loads and stores go straight to it (dynarmic's fastmem). The
  client sits at its own addresses, the adapters beside it, the answered imports' slots and
  imported data after them, and one heap of 4 GiB for the client's malloc, stacks and the
  harness's objects (`src/machine.rs` has the map).
- **Loading** (`src/loader.rs`, `src/macho.rs`) applies every chained fixup. A bind goes to an
  adapter's export when the client imports it from that adapter's library (the Steam calls; the
  guard's connect, getaddrinfo and opendir), to an imported data symbol when it is data, and to
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

Measured on this PC (20 host threads, 2026-11-11): to frame 3 with `--check` in about 16 s; the
loading screen gives way to the menu at about frame 1,300, 30 s in; the menu draws at about 27
frames a second; the host holds about 3.5 GB.

## What it cannot do

It draws nothing (no GPU: Metal's objects are stand-ins; buffers are real memory), so it
cannot see a screen or aim a click at a button. Input is a click at a point at a frame.
