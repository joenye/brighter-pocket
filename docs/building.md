# Building and installing

Two routes reach the same app. **Linux** builds the unsigned app for External JIT: a
sideloading tool signs it with your Apple ID, a JIT enabler gives it executable memory, and no
Mac is involved at any point. **A Mac** builds with the platform's own Xcode scripts and adds
Tolkara's other two execution modes (Developer service, Local signing). Either way you bring
your own copy of the game; nothing of it is in this repository or in the app.

## On Linux

1. **Python tools** (3.9 or later; the core tools need no packages):

   ```bash
   python3 -m venv .venv && .venv/bin/pip install zstandard pymobiledevice3
   ```

   `zstandard` is for `tools/check_shaders.py`, `pymobiledevice3` for copying the game over USB.

2. **An iPhoneOS SDK**: copy `iPhoneOS.sdk` from an Xcode
   (`Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/`) and set
   `IOS_SDK` in `local.env` (from `local.env.example`). This repository was verified with the
   26.4 SDK. The SDK is Apple's and is not redistributed here.

3. **The toolchain**: `tools/linux/setup_toolchain.sh` puts LLVM 23.1.5 (clang, ld64.lld),
   ldid and one compiler-rt piece in `.toolchain/` (about 800 MB). For the emulator
   (docs/emulator.md), `tools/linux/setup_emulator.sh` builds dynarmic, the JIT it runs the client
   on, into `.toolchain/emulator/` (needs cargo, cmake and a C++20 compiler; about two minutes).

4. **The game**: with `STEAM_USER` set, `tools/fetch_client.py` downloads the macOS build from
   Steam's content servers into `client/<date>_<manifest>/` (about 1 GB). It needs a Steam
   account that owns Brighter Shores and DepotDownloader (default: Brighter Atlas's copy, whose
   remembered login it reuses; `--qr` logs in with the Steam app).

5. **Check**: `tests/run.sh` (about a minute) runs everything that runs without a device,
   including the client's own startup in an emulator.

6. **Build**: `tools/build_ios.py` writes `build/BrighterPocket-unsigned.ipa` (about 1 MB).
   `--for-client` makes the compatibility libraries for the downloaded client instead of
   generic ones: the platform then stops a launch on any import nothing provides rather than
   stubbing it, and only the adapters the client uses are built.

7. **Install**: sideload the `.ipa` with SideStore, AltStore or Sideloadly, signed with your
   Apple ID, on a device in Developer Mode. A free Apple ID cannot grant the increased memory
   limit and extended virtual addressing the app asks for; the client is small (54 MB of code)
   so it may fit without them, but that is untested.

8. **Copy the game** into the app's Documents (the app shares it):

   ```bash
   .venv/bin/python pocket/profiles/brighter-shores/install.py --source "client/<folder>/x64arm64" --device <UDID> --via pymobiledevice3
   ```

   or `tools/stage_client.py` and copy `build/stage/Brighter Shores` into the app's folder with
   the Files app. Either way Valve's `libsteam_api.dylib` is left out.

9. **Run**: open the app with JIT enabled (StikDebug, or your sideloading tool), and tap
   Brighter Shores. The first time, the app asks you to sign in to Steam (account name,
   password, then a Steam Guard code or approval in the Steam Mobile app); it keeps Steam's
   sign-in token in the keychain and signs in with it from then on ("Sign out of Steam" in the
   Diagnostics menu forgets it). The launcher then asks the enabler for the executable region
   and loads the client. Its log is in the app's Diagnostics menu.

## On a Mac

```bash
python3 tools/prepare.py          # platform/ + patches + this layer -> build/platform
cd build/platform                 # your local.env is copied in
```

Then follow `platform/docs/BUILDING.md` in that tree, with these settings in `local.env`:

- `GUEST_EXE` naming the client's executable (Steam's install, or a `client/` download) makes
  `tools/install.sh` build the compatibility libraries for it, as `--for-client` does on Linux.
- `TOLKARA_MODE=local-signing` needs no tunnel or debugger. The client never rewrites its own
  code, so the page container is built from the executable as it is; leave `TOLKARA_CAPTURE`
  empty.
- `TOLKARA_MODE=developer-service` needs the one-time `tools/enroll.sh`.
- `tools/package_ipa.sh` there builds the platform's own generic unsigned `.ipa`, as
  `tools/build_ios.py` does here.

Then copy the game with the profile helper (`--via devicectl` is the default on a Mac):

```bash
python3 profiles/brighter-shores/install.py --source "$HOME/Library/Application Support/Steam/steamapps/common/Brighter Shores" --device <UDID>
```

## How the Linux build matches Xcode's

`tools/build_ios.py` follows the platform's `TolkaraDiagnostics` target (`project.yml`): the
same sources (`launcher/`, `runtime/`, `translation/Metal/LibraryContainer.m`) for arm64 iOS 17,
the compatibility libraries from the platform's unchanged `tools/build_shims.py` (and
`tools/classify.py` with `--for-client`), with `tools/linux/xcrun`, `otool` and `dyld_info`
answering what those scripts ask of Xcode; `Info.plist` from `launcher/Info.plist` plus the
keys Xcode generates; the app icon as loose PNGs (no `actool` on Linux); ad hoc signatures by
ldid declaring the two memory entitlements, as `tools/package_ipa.sh` signs with `codesign -s -`;
External JIT preselected; no system root certificates (the platform's release build leaves
them out too).

## If the device refuses the shaders

The device compiles the client's AIR 1.8 shader libraries itself (`docs/client-analysis.md`,
"Rendering"). If its log says `On-device Metal library <key>: rejected`, translate them all once
on a Mac with Xcode's Metal toolchain and copy them to the app's `Documents/TranslatedShaders`,
where Tolkara's Metal adapter looks before anything else:

```bash
python3 tools/prepare.py
.venv/bin/python tools/translate_shaders.py --push --device <UDID>   # the 500 distinct libraries
```

Without the copy, a launch with `--translate-shaders` and the platform's
`tools/serve_shader_translation.py` running asks the Mac for each library while the game waits.
Both go through `tools/translate_metallib.py` as `pocket/patches/0004` lets it read these
libraries; whether Apple's tools take AIR 1.8 is itself unverified.

## Moving to a newer Tolkara

`tools/update_platform.sh [commit]` replaces `platform/` with that commit and pins it; the
prepare step then names any patch that no longer applies or overlay file that now collides.
Run `tests/run.sh` and commit `platform/` with `pocket/platform.lock`.

## A new game build

`tools/fetch_client.py` takes the newest public build (or `--manifest`); `tests/run.sh` then
re-checks the imports, the loader and the shaders against it. The app itself needs rebuilding
only when the client starts importing something new.
