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
tests/run.sh                         # every check without a device (about 20 s)
.venv/bin/python tools/fetch_client.py [--manifest ID]
.venv/bin/python tools/analyze_client.py --sdk "$IOS_SDK"   # out/client-surface.md
.venv/bin/python tools/check_shaders.py [--pinned]
.venv/bin/python tools/stage_client.py   # build/stage/Brighter Shores
python3 tools/prepare.py             # build/platform: platform + patches + overlay
.venv/bin/python tools/build_ios.py [--for-client]           # the unsigned .ipa, on Linux
tools/linux/setup_toolchain.sh       # .toolchain/: LLVM 23.1.5, ldid, libclang_rt.ios.a
```

Settings come from `local.env` (`local.env.example`); `IOS_SDK` must name an iPhoneOS SDK
folder for the iOS checks and the Linux build. The Python tools need only the standard
library, except `check_shaders.py` (zstandard) and the copy helper's Linux route
(pymobiledevice3); keep them runnable with the Python 3.9 macOS ships.

## Where things are

- `tools/macho.py`: the Mach-O reader everything here uses (fat files, chained fixups, exports,
  Objective-C metadata); `tools/linux/dyld_info` exposes it to the platform's `classify.py`.
- `tools/linux/xcrun`, `otool`, `dyld_info`: what the platform's shim builder and classifier ask
  of Xcode, answered on Linux.
- `tests/loader_test.c` builds Tolkara's own loader for the host against the SDK's Mach-O
  headers; `tests/loader_check.py` compares its output with `tools/macho.py`.
- A device result goes in docs/status.md with the device, OS version and execution mode.
