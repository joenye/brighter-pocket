# CLAUDE.md: Brighter Pocket

The macOS Brighter Shores client on iOS, unchanged, as a layer on Tolkara (a compatibility
layer, like Wine or Proton but for macOS apps on iOS; https://github.com/tolkara/tolkara): the client file is
copied byte for byte and never patched; the layer answers its macOS imports, signs in to Steam
on the device and lends the game that session. Start with README.md; docs/status.md says what
is verified and what is not, docs/client-analysis.md what the client needs,
docs/architecture.md how the layer fits, docs/building.md how to build by hand (players' setup is in README.md).

## Rules

- **The client file is never changed**, on disk or in memory beyond what loading it does
  (fixups). Staging copies it unchanged and leaves only Valve's `libsteam_api.dylib` out; the
  app's own updates fetch Steam's files unchanged, each chunk's SHA-1 checked, and leave out the
  same file. Every difference from the Mac is outside it: adapters, the launcher, patches to
  Tolkara.
- The game reaches its servers directly, VPN or not (Joe, 2026-11-12: the VPN-only guard is
  dropped). Never touch the Mac's own VPN or network settings. Never print or commit a Steam
  token or password.
- **Usage counts go only to Umami, and never name anyone** (Joe, 2026-11-14): the companion's
  `pocket/management/Analytics.swift` (patch 0041) and the app's `PocketAnalytics.m` send
  anonymous events to brighteratlas.com's Umami website under their own hostnames, on by default
  with an off switch in each. Never an account, team, device name, email, path, token or game
  data; README.md, "Anonymous usage counts", lists every event: keep it in step.
- **`platform/` is Tolkara byte for byte.** Never edit it. A change to a platform file is a patch
  in `pocket/patches/` (numbered, with its reason and an upstream note at the top), a new file is
  an overlay entry in `pocket/overlay.map`. `tools/prepare.py` enforces both and the pin
  (`pocket/platform.lock`); move the pin only with `tools/update_platform.sh`.
- **Nothing from the game enters git.** The client lives in the ignored `client/`; staged copies
  and builds in `build/`. Reports may name Apple and Steam API symbols and file facts, never
  game code or data.
- **The app is Brighter Pocket**, a Brighter Atlas project (https://brighteratlas.com; its icon
  is the Brighter Atlas mark with the Apple logo for its A, `tools/make_icons.py`). Text a player reads never says "Tolkara" (patches 0029, 0030
  make Tolkara's own strings use the app's name), except the credits: the settings' About and
  the companion's credit name Tolkara with its link. On the Home Screen it is "Pocket"
  (`TOLKARA_DISPLAY_NAME` in `pocket/layer.env`); its own text keeps the full name
  (`TOLKARA_APP_NAME`, patch 0035). Internal keys, folder names on disk and log prefixes keep Tolkara's
  names: changing them would lose players' data.
- Commits are Joe's: no agent attribution, signed, `type(area): summary`.
- No em or en dashes in code, comments or docs.

## Commands

```bash
tests/run.sh                         # every check without a device (about a minute)
tools/make_companion.sh [--dmg]      # build/Brighter Pocket Companion.app: the automatic setup (README.md, "Set up")
tools/release/release.sh --unsigned  # a release's DMG, appcast and notes, ad hoc (docs/releasing.md; CI signs real ones)
.venv/bin/python tools/run_simulator.py [--seconds N] [--no-steam] [--launcher-arg ARG] [--env K=V]   # the app in the iOS Simulator, the game started
emulator/target/release/pocket-emulator [--frames N] [--pinned-appkit] [--check] [--click X,Y@FRAME] [--offline]   # the client's startup, emulated (docs/emulator.md)
emulator/target/release/pocket-emulator --network [--steam-live] [--probe-network HOST] ...   # with the network (hermetic without it)
(cd emulator && cargo build --release && cargo test --release)   # build it, and its tests
tools/setup_emulator.sh             # .toolchain/emulator/: dynarmic (arm64 backend, emulator/dynarmic-patches) and Boost's headers
.venv/bin/python tools/fetch_client.py [--depot [--manifest ID]]   # from the Mac's Steam install (or DepotDownloader)
.venv/bin/python tools/analyze_client.py   # out/client-surface.md
.venv/bin/python tools/check_shaders.py [--pinned] [--translator build/platform/tools/translate_metallib.py]
.venv/bin/python tools/translate_shaders.py [--simulator] [--keys] [--push]   # shader translations (a device that refuses AIR 1.8; the simulator)
(cd emulator && cargo test --release live_session -- --ignored)   # by hand: the app's Steam session core against Steam itself (Joe's account)
.venv/bin/python tests/depot_live.py [--small DIR | DIR EXISTING | --installed WORK APP]   # by hand: the app's game updates against Steam itself (Joe's account)
.venv/bin/python tools/stage_client.py   # build/stage/Brighter Shores
python3 tools/prepare.py             # build/platform: platform + patches + overlay
(cd build/platform && tools/install.sh)   # build, sign and install on DEVICE (local.env), Local signing's container too
.venv/bin/python tools/build_ios.py [--simulator] [--for-client]   # the unsigned .ipa, or the simulator's app
```

Builds share `build/`: wrap anything that runs prepare.py, build_ios.py, run_simulator.py or
install.sh in `lockf -k build/.build.lock ...` when more than one may run at once.

Everything runs on an Apple silicon Mac with Xcode; settings come from `local.env`
(`local.env.example`), `DEVELOPER_DIR` there when Xcode is not the selected developer folder.
The Python tools need only the standard library, except `check_shaders.py` (zstandard) and the
copy helper's route without Xcode (pymobiledevice3); keep them runnable with the Python 3.9
macOS ships. The emulator is Rust (edition 2024) over dynarmic, built by
`tools/setup_emulator.sh`.

## Where things are

- `tools/macho.py`: the Mach-O reader everything here uses (fat files, chained fixups, exports,
  Objective-C metadata).
- `tools/run_simulator.py`: the simulator run. In simulator builds the app signs in to Steam
  with DepotDownloader's remembered login named in its environment (`PocketSteamLaunch.m`,
  simulator only), the Metal adapter takes shader translations made for the simulator
  (patches 0007, 0008), and `PocketCompat.m` adds the presentation calls the simulator's Metal
  lacks.
- `pocket/management/` and patches 0020 to 0023, 0034, 0037 to 0041: Tolkara Management made into Brighter Pocket
  Companion (`tools/make_companion.sh`), with its own updates (Sparkle) and What's New from
  `CHANGELOG.md`; `VERSION` is its version. Releases are built, signed and attested by
  `.github/workflows/release.yml` (docs/releasing.md); never sign or publish one by hand. Patch 0028: opening the app starts the game (the library
  only when there is none), the Steam sign-in and the update before the start hashes it.
- Patch 0009: Local signing for this client (chained fixups, `__init_offsets`, codesign).
  `PocketLocalSigning.m` (patches 0014, 0024) makes and signs the same container on the device
  for a build that has none, with the identity `pocket/tools/give_signing_identity.sh` gave
  the app once; `tests/local_signing_test.m` checks it matches the Mac's byte for byte.
- `pocket/translation/AppKit/PocketSettings.m`: the in-game settings (docs/architecture.md);
  patch 0025 the touch input (double tap, pinch, cursor speed; `tests/trackpad_test.c`).
- `tests/loader_test.c` builds Tolkara's own loader for the host against the SDK's Mach-O
  headers; `tests/loader_check.py` compares its output with `tools/macho.py`.
- `pocket/launcher/Pocket/`: the app's Steam sign-in and session. `PocketSteam.c` is the
  protocol, plain C so `tests/steam_session_test.c` and the emulator (`emulator/src/steam.rs`)
  run it as is; `PocketSteamClient.m` carries it over a WebSocket; `PocketSteamLaunch.m` is the
  sign-in screens, the keychain, the bridge the game's Steam library reaches with dlsym, and
  the session's keepalive and state (`PocketSteamCurrentState`, shown in the settings).
  `PocketDepot.m` reads Steam's content system (PICS, manifests, chunks; zstd from the
  reference decoder vendored unchanged in `zstd/`), `PocketInstalledGame.m` keeps the build on
  the device and its updates (`tests/depot_live.m` runs both on the Mac), and
  `PocketGameUpdates.m` shows them before the game starts.
- `emulator/`: the emulated startup (docs/emulator.md). `src/loader.rs` maps the client and the
  layer's arm64 adapters; `src/cpu.rs` is dynarmic; `src/runtime.rs` the client's threads, all at
  once on host threads, and what they wait on; `src/hle/` the answered imports (libSystem and
  the container's files, Objective-C with Tolkara's AppKit coverage read from the prepared tree,
  Metal with each shader library through the rewrap's checks, the network). A model gap stops
  the run with the import's name; answer it as the device would, never to make the run pass.
- A device result goes in docs/status.md with the device, OS version and execution mode.
