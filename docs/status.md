# Status

As of 11 November 2026. **Built and checked on Linux; not yet run on a device.** The app signs
in to Steam on the device; nothing here has connected to Brighter Shores' servers, and the
network guard keeps the game from them.

## Verified (`tests/run.sh`, on Linux)

|what|evidence|
|---|---|
|The macOS client is downloaded unchanged from Steam's content servers|`tools/fetch_client.py`, executable SHA-256 recorded in `client/*/.complete`|
|Every import has a provider on iOS (SDK 26.4, Tolkara's and this layer's adapters)|`tools/analyze_client.py`: 232 imports, 0 unprovided|
|Tolkara's loader places the staged client: no carried library, all 65,114 fixups applied, all 8 Steam imports bound to the offline library's arm64 exports|`tests/loader_test.c`, cross-checked pointer by pointer against `tools/macho.py` by `tests/loader_check.py`: 0 differences|
|The Steam library behaves as the client's C++ calls expect (vtable slots, callback objects), offline and with the app's session behind its bridge (the account, a ticket handed on by callback 168, a cancelled ticket withdrawn from Steam)|`tests/steam_test.cpp`, ASan and UBSan|
|The app's Steam session core frames and reads Steam's messages as Steam does: hello, a service call before logon, logon, a refusal, account info and game connect tokens in a multi message, the ownership ticket, the web API ticket laid out as SteamKit2 lays it out (session part, CRC-32, `str:` identity, ownership ticket, 2,560 bytes), its registration, Steam's ack, cancelling, being logged off|`tests/steam_session_test.c`, ASan and UBSan|
|**Against Steam itself**, the same core: a service call before logon (the sign-in's first step), logon with a refresh token, the persona name, 10 game connect tokens, Brighter Shores' ownership ticket (result OK), the game marked as playing, a web API ticket registered and acknowledged by Steam, then cancelled and logged off|`tests/steam_live.py`, by hand, Joe's account, 2026-11-11|
|The offline guard refuses lookups and remote connects before anything leaves, and passes loopback through|`tests/network_test.c`|
|The folder-walk guard opens the app's home folder for an ancestor the system refuses, and changes nothing else|`tests/paths_test.c`|
|**The client's own startup, emulated, with the layer's adapters running as their arm64 iOS builds**: Steam initialises signed in through the app's session (or offline, `--offline`), the window, Metal layer and pointer images are made, the settings store is created, the nine asset bundles are read, audio starts, all 536 shader libraries are accepted, and frames are presented; the only AppKit messages left unanswered return nothing|`tests/emulate/boot.py --check` (docs/client-analysis.md, "Startup, emulated")|
|Without this layer's AppKit additions the client stops at start ("Could not load move cursor")|`tests/emulate/boot.py --pinned-appkit`|
|With its 35 threads run by turns, Metal's completion handlers run and the emulated clock paced at 60 frames a second, the client's asset pool loads the bundles and the client draws its loading screen, then from about frame 4,700 its next screen (90,752 meshes over 6,000 frames), with no file touched outside its container, the bundle and `/dev/urandom`, and no network lookup; two 300-frame runs give the same counts|`tests/emulate/boot.py --threads --frames 6000` (by hand: 12 minutes; docs/client-analysis.md)|
|All 536 shader libraries pass the on-device rewrap's checks with patch 0003 (and all 536 fail them without it), and the Mac fallback reads all 536 with patch 0004 (and none without it)|`tools/check_shaders.py`, `--pinned`, `--translator`|
|The layer's sources and the patched platform file compile for arm64 iOS with warnings as errors|`tests/run.sh`, "layer sources compile"|
|The whole app (launcher, runtime, 13 compatibility libraries) builds and links for arm64 iOS 17, signed ad hoc with the memory entitlements|`tools/build_ios.py`, 1.2 MB `.ipa`|
|A build made for the client plans libsteam_api as a full adapter and libSystem as a re-exporting one, and stubs nothing real in AudioToolbox|`tools/build_ios.py --for-client` (the platform's `classify.py` run on Linux)|
|The profile is valid by the platform's own checker|`platform/tools/check_profile.py`|

## Not verified (needs a device)

In the order a first run would meet them:

1. **The Linux-built app installs and starts** after a sideloading tool re-signs it. Its
   `Info.plist` and icons are written by `tools/build_ios.py`, not Xcode.
2. **Signing in to Steam on the device**: the sign-in screens, the RSA-encrypted password
   (Security framework), Steam Guard by code or by approval in the Steam Mobile app, and the
   keychain have not run anywhere yet; the protocol under them has (above). The game's Steam
   library finds the session with `dlsym` (the app exports `PocketSteamBridgeGet`; checked in
   the Linux build's export table).
3. **External JIT on the device**: Tolkara has not run this mode on a device yet either (its
   README says so). StikDebug must service the launcher's request for the executable region.
4. **The client gets through its startup on the device**: emulated, it does, with its threads
   too (above); on the device they run at once rather than by turns, and Tolkara's AppKit, Metal
   and audio adapters do real work where the emulator stands in.
5. **The iPad's Metal compiler builds AIR 1.8**: patch 0003 hands the libraries over; whether
   the compiler accepts this old AIR is the largest single unknown. If it refuses, Tolkara's
   fallback is a translation made on a Mac, all at once with `tools/translate_shaders.py` or one
   by one with `tools/serve_shader_translation.py`, which read the libraries with patch 0004;
   whether Apple's tools take AIR 1.8 has to be seen there too (`docs/building.md`).
6. **Whether the sandbox refuses the folders above the container**: if it does, the folder-walk
   guard answers for them; if not, the guard never acts.
7. **When the game asks for its ticket**: emulated and signed in, it asked for none in 6,000
   frames: its sign-in waits for the player. Which identity it names, and what its servers make
   of the ticket, are seen only once it asks (on the device) and once the network guard lets
   it through (Joe's decision).
8. Input (keyboard, pointer, touch), audio output, and frame pacing.

## Known gaps

- **The game cannot sign in to its servers yet.** It gets a real web API ticket from the app's
  Steam session, but the network guard refuses the connection it would carry it on, by design
  for now. Lifting the guard for the game's own hosts is the remaining step.
- **A dropped Steam connection is not made again** during play. Steam ties a ticket to the
  session that registered it, so tickets made before the drop probably lapse with it (not
  tested); the next launch signs in again. Signing out is in the launcher's Diagnostics menu
  ("Sign out of Steam").
- **In-game purchases** need the Steam overlay, which the device has none of.
- **NSSharingServicePicker** is a logging stub (the game's share menu does nothing).
- **The app is named "Brighter Pocket" only in the Linux build**; a Mac build through the
  platform's scripts is named Tolkara and lists Tolkara's other profiles too.
- **Developer service needs a Mac** (Swift sources, enrolment); the Linux build has External
  JIT only.

## First device run, suggested

1. `tests/run.sh`, then `tools/build_ios.py --for-client`.
2. Sideload, enable Developer Mode, copy the game with the profile helper.
3. Start with JIT enabled; sign in to Steam when asked. Read the Diagnostics log for
   `[steam] initialised: signed in`, `On-device Metal library ... loaded` or `rejected`,
   `GetAuthTicketForWebApi(...)` and `[network] lookup of ... refused`.
4. Note what happened in this file, with the device, OS version and execution mode.
