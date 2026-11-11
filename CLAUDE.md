# CLAUDE.md: Brighter Pocket

The macOS Brighter Shores client on iOS, as a layer on Tolkara: it signs in to Steam on the
device, and its network guard lets the game reach its servers only through a VPN. Start with README.md;
docs/status.md says what is verified and what is not, docs/client-analysis.md what the client
needs, docs/architecture.md how the layer fits, docs/building.md how to build and install.

## Rules

- **The game reaches its servers through a VPN only** (Joe, 2026-11-11; `docs/vpn.md`). The
  network guard (`pocket/translation/libSystem.B`) refuses every lookup and connection off the
  device unless a VPN is up; never weaken that, and never let the emulator's game traffic out
  but through `--vpn` (Varrock's ProtonVPN tunnel via the `game-socks` proxy). Steam itself may
  be reached directly (the app's sign-in, `tools/fetch_client.py`, the emulator's live session test by hand
  as Joe's account with his agreement), and GitHub. Never print or commit a Steam token or the
  proxy's password. On Varrock, only `game-socks` is ours; anything else there is Joe's call.
- **`platform/` is Tolkara byte for byte.** Never edit it. A change to a platform file is a patch
  in `pocket/patches/` (numbered, with its reason and an upstream note at the top), a new file is
  an overlay entry in `pocket/overlay.map`. `tools/prepare.py` enforces both and the pin
  (`pocket/platform.lock`); move the pin only with `tools/update_platform.sh`.
- **Nothing from the game enters git.** The client lives in the ignored `client/`; staged copies
  and builds in `build/`. Reports may name Apple and Steam API symbols and file facts, never
  game code or data.
- **The client file is never changed.** Staging copies it unchanged and leaves only Valve's
  `libsteam_api.dylib` out.
- Commits are Joe's: no agent attribution, signed, `type(area): summary`.
- No em or en dashes in code, comments or docs.

## Commands

```bash
tests/run.sh                         # every check without a device (about a minute)
emulator/target/release/pocket-emulator [--frames N] [--pinned-appkit] [--check] [--click X,Y@FRAME] [--offline]   # the client's startup, emulated (docs/emulator.md)
emulator/target/release/pocket-emulator --vpn [--steam-live] [--probe-network HOST] ...   # with the network, through Varrock's VPN (docs/vpn.md)
(cd emulator && cargo build --release && cargo test --release)   # build it, and its tests
tools/linux/setup_emulator.sh       # .toolchain/emulator/: dynarmic and Boost's headers, which it links
.venv/bin/python tools/fetch_client.py [--manifest ID]
.venv/bin/python tools/analyze_client.py --sdk "$IOS_SDK"   # out/client-surface.md
.venv/bin/python tools/check_shaders.py [--pinned] [--translator build/platform/tools/translate_metallib.py]
.venv/bin/python tools/translate_shaders.py [--keys] [--push]   # on a Mac: the shader cache, if a device refuses AIR 1.8
(cd emulator && cargo test --release live_session -- --ignored)   # by hand: the app's Steam session core against Steam itself, through the VPN (Joe's account)
.venv/bin/python tools/stage_client.py   # build/stage/Brighter Shores
python3 tools/prepare.py             # build/platform: platform + patches + overlay
.venv/bin/python tools/build_ios.py [--for-client]           # the unsigned .ipa, on Linux
tools/linux/setup_toolchain.sh       # .toolchain/: LLVM 23.1.5, ldid, libclang_rt.ios.a
```

Settings come from `local.env` (`local.env.example`); `IOS_SDK` must name an iPhoneOS SDK
folder for the iOS checks and the Linux build. The Python tools need only the standard
library, except `check_shaders.py` (zstandard) and the copy helper's Linux route
(pymobiledevice3); keep them runnable with the Python 3.9 macOS ships. The emulator is Rust
(edition 2024) over dynarmic, built by `tools/linux/setup_emulator.sh`.

## Where things are

- `tools/macho.py`: the Mach-O reader everything here uses (fat files, chained fixups, exports,
  Objective-C metadata); `tools/linux/dyld_info` exposes it to the platform's `classify.py`.
- `tools/linux/xcrun`, `otool`, `dyld_info`: what the platform's shim builder and classifier ask
  of Xcode, answered on Linux.
- `tests/loader_test.c` builds Tolkara's own loader for the host against the SDK's Mach-O
  headers; `tests/loader_check.py` compares its output with `tools/macho.py`.
- `pocket/launcher/Pocket/`: the app's Steam sign-in and session. `PocketSteam.c` is the
  protocol, plain C so `tests/steam_session_test.c` and the emulator (`emulator/src/steam.rs`)
  run it as is; `PocketSteamClient.m` carries it over a WebSocket; `PocketSteamLaunch.m` is the
  sign-in screens, the keychain and the bridge the game's Steam library reaches with dlsym.
- `emulator/`: the emulated startup (docs/emulator.md). `src/loader.rs` maps the client and the
  layer's arm64 adapters; `src/cpu.rs` is dynarmic; `src/runtime.rs` the client's threads, all at
  once on host threads, and what they wait on; `src/hle/` the answered imports (libSystem and
  the container's files, Objective-C with Tolkara's AppKit coverage read from the prepared tree,
  Metal with each shader library through the rewrap's checks, the network). A model gap stops
  the run with the import's name; answer it as the device would, never to make the run pass.
- A device result goes in docs/status.md with the device, OS version and execution mode.
