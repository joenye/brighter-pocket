# CLAUDE.md: Brighter Pocket

The macOS Brighter Shores client on iOS, offline, as a layer on Tolkara. Start with README.md;
docs/status.md says what is verified and what is not, docs/client-analysis.md what the client
needs, docs/architecture.md how the layer fits, docs/building.md how to build and install.

## Rules

- **Never reach the game's servers.** The app stays offline: the offline Steam library and the
  network guard (`pocket/translation/libsteam_api`, `pocket/translation/libSystem.B`) are not
  weakened, bypassed or removed without Joe's explicit go-ahead, and no tool here talks to
  anything but Steam's content servers (`tools/fetch_client.py`) and GitHub (toolchain, Tolkara).
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
.venv/bin/python tests/emulate/boot.py [--frames N] [--pinned-appkit] [--check] [--threads] [--click X,Y@FRAME]   # the client's startup, emulated
.venv/bin/python tools/fetch_client.py [--manifest ID]
.venv/bin/python tools/analyze_client.py --sdk "$IOS_SDK"   # out/client-surface.md
.venv/bin/python tools/check_shaders.py [--pinned] [--translator build/platform/tools/translate_metallib.py]
.venv/bin/python tools/translate_shaders.py [--keys] [--push]   # on a Mac: the shader cache, if a device refuses AIR 1.8
.venv/bin/python tools/stage_client.py   # build/stage/Brighter Shores
python3 tools/prepare.py             # build/platform: platform + patches + overlay
.venv/bin/python tools/build_ios.py [--for-client]           # the unsigned .ipa, on Linux
tools/linux/setup_toolchain.sh       # .toolchain/: LLVM 23.1.5, ldid, libclang_rt.ios.a
```

Settings come from `local.env` (`local.env.example`); `IOS_SDK` must name an iPhoneOS SDK
folder for the iOS checks and the Linux build. The Python tools need only the standard
library, except `check_shaders.py` (zstandard), the emulated startup (unicorn, zstandard) and the
copy helper's Linux route (pymobiledevice3); keep them runnable with the Python 3.9 macOS ships.

## Where things are

- `tools/macho.py`: the Mach-O reader everything here uses (fat files, chained fixups, exports,
  Objective-C metadata); `tools/linux/dyld_info` exposes it to the platform's `classify.py`.
- `tools/linux/xcrun`, `otool`, `dyld_info`: what the platform's shim builder and classifier ask
  of Xcode, answered on Linux.
- `tests/loader_test.c` builds Tolkara's own loader for the host against the SDK's Mach-O
  headers; `tests/loader_check.py` compares its output with `tools/macho.py`.
- `tests/emulate/`: the emulated startup. `boot.py` maps the client and the layer's arm64
  adapters; `hle.py` answers libSystem, libc++, Core Graphics and audio; `objc.py` a small
  Objective-C runtime; `appkit.py` which selectors the device's AppKit answers (read from the
  prepared tree); `metal.py` Metal, with each shader library through the rewrap's checks;
  `threads.py` the client's threads by turns (`--threads`). A model gap stops the run with the
  import's name; answer it as the device would, never to make the run pass. A `--threads` run
  takes minutes and an emulated heap of up to 4 GiB: one at a time.
- A device result goes in docs/status.md with the device, OS version and execution mode.
