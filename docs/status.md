# Status

As of 11 November 2026. **Built and checked on Linux; not yet run on a device.** Nothing here
has connected to Brighter Shores' servers, and the app is built so that the game cannot.

## Verified (`tests/run.sh`, on Linux)

|what|evidence|
|---|---|
|The macOS client is downloaded unchanged from Steam's content servers|`tools/fetch_client.py`, executable SHA-256 recorded in `client/*/.complete`|
|Every import has a provider on iOS (SDK 26.4, Tolkara's and this layer's adapters)|`tools/analyze_client.py`: 232 imports, 0 unprovided|
|Tolkara's loader places the staged client: no carried library, all 65,114 fixups applied, all 8 Steam imports bound to the offline library's arm64 exports|`tests/loader_test.c`, cross-checked pointer by pointer against `tools/macho.py` by `tests/loader_check.py`: 0 differences|
|The offline Steam library behaves as the client's C++ calls expect (vtable slots, callback objects, ticket failure)|`tests/steam_test.cpp`, ASan and UBSan|
|The offline guard refuses lookups and remote connects before anything leaves, and passes loopback through|`tests/network_test.c`|
|The folder-walk guard opens the app's home folder for an ancestor the system refuses, and changes nothing else|`tests/paths_test.c`|
|**The client's own startup, emulated, with the layer's adapters running as their arm64 iOS builds**: Steam initialises offline, the window, Metal layer and pointer images are made, the settings store is created, the nine asset bundles are read, audio starts, all 536 shader libraries are accepted, and frames are presented; the only AppKit messages left unanswered return nothing|`tests/emulate/boot.py --check` (docs/client-analysis.md, "Startup, emulated")|
|Without this layer's AppKit additions the client stops at start ("Could not load move cursor")|`tests/emulate/boot.py --pinned-appkit`|
|With its 35 threads run by turns and Metal's completion handlers run, the client's asset pool loads the bundles and the client draws (65,366 meshes over 3,000 frames), with no file touched outside its container, the bundle and `/dev/urandom`, and no network lookup|`tests/emulate/boot.py --threads --frames 3000` (by hand: 12 minutes; docs/client-analysis.md)|
|All 536 shader libraries pass the on-device rewrap's checks with patch 0003 (and all 536 fail them without it), and the Mac fallback reads all 536 with patch 0004 (and none without it)|`tools/check_shaders.py`, `--pinned`, `--translator`|
|The layer's sources and the patched platform file compile for arm64 iOS with warnings as errors|`tests/run.sh`, "layer sources compile"|
|The whole app (launcher, runtime, 13 compatibility libraries) builds and links for arm64 iOS 17, signed ad hoc with the memory entitlements|`tools/build_ios.py`, 1.2 MB `.ipa`|
|A build made for the client plans libsteam_api as a full adapter and libSystem as a re-exporting one, and stubs nothing real in AudioToolbox|`tools/build_ios.py --for-client` (the platform's `classify.py` run on Linux)|
|The profile is valid by the platform's own checker|`platform/tools/check_profile.py`|

## Not verified (needs a device)

In the order a first run would meet them:

1. **The Linux-built app installs and starts** after a sideloading tool re-signs it. Its
   `Info.plist` and icons are written by `tools/build_ios.py`, not Xcode.
2. **External JIT on the device**: Tolkara has not run this mode on a device yet either (its
   README says so). StikDebug must service the launcher's request for the executable region.
3. **The client gets through its startup on the device**: emulated, it does, with its threads
   too (above); on the device they run at once rather than by turns, and Tolkara's AppKit, Metal
   and audio adapters do real work where the emulator stands in.
4. **The iPad's Metal compiler builds AIR 1.8**: patch 0003 hands the libraries over; whether
   the compiler accepts this old AIR is the largest single unknown. If it refuses, Tolkara's
   fallback is a translation made on a Mac (`tools/serve_shader_translation.py`), which reads
   them with patch 0004; whether Apple's tools take AIR 1.8 has to be seen there too.
5. **Whether the sandbox refuses the folders above the container**: if it does, the folder-walk
   guard answers for them; if not, the guard never acts.
6. **What the game shows offline**: emulated, with every thread running, it looked nothing up
   in 3,000 frames; a lookup at sign-in fails at once. Signing in is impossible by design.
7. Input (keyboard, pointer, touch), audio output, and frame pacing.

## Known gaps

- **No sign-in.** The game authenticates with a Steam web API ticket, and the offline library
  answers "no connection". Going online would need a ticket from Steam itself (Tolkara already
  speaks Steam's CM protocol for Steam Cloud, `platform/launcher/Cloud/`), a decision to make
  deliberately: this build is offline on purpose.
- **NSSharingServicePicker** is a logging stub (the game's share menu does nothing).
- **The app is named "Brighter Pocket" only in the Linux build**; a Mac build through the
  platform's scripts is named Tolkara and lists Tolkara's other profiles too.
- **Developer service needs a Mac** (Swift sources, enrolment); the Linux build has External
  JIT only.

## First device run, suggested

1. `tests/run.sh`, then `tools/build_ios.py --for-client`.
2. Sideload, enable Developer Mode, copy the game with the profile helper.
3. Start with JIT enabled; read the Diagnostics log for `[steam] initialised offline`,
   `On-device Metal library ... loaded` or `rejected`, and `[network] lookup of ... refused`.
4. Note what happened in this file, with the device, OS version and execution mode.
