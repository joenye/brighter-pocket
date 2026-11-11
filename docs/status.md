# Status

As of 11 November 2026. **Built and checked on Linux; not yet run on a device.** The app signs
in to Steam on the device, and the game may reach its servers through a VPN only
([docs/vpn.md](vpn.md)).

## Verified (`tests/run.sh`, on Linux)

|what|evidence|
|---|---|
|The macOS client is downloaded unchanged from Steam's content servers|`tools/fetch_client.py`, executable SHA-256 recorded in `client/*/.complete`|
|Every import has a provider on iOS (SDK 26.4, Tolkara's and this layer's adapters)|`tools/analyze_client.py`: 232 imports, 0 unprovided|
|Tolkara's loader places the staged client: no carried library, all 65,114 fixups applied, all 8 Steam imports bound to the offline library's arm64 exports|`tests/loader_test.c`, cross-checked pointer by pointer against `tools/macho.py` by `tests/loader_check.py`: 0 differences|
|The Steam library behaves as the client's C++ calls expect (vtable slots, callback objects), offline and with the app's session behind its bridge (the account, a ticket handed on by callback 168, a cancelled ticket withdrawn from Steam)|`tests/steam_test.cpp`, ASan and UBSan|
|The app's Steam session core frames and reads Steam's messages as Steam does: hello, a service call before logon, logon, a refusal, account info and game connect tokens in a multi message, the ownership ticket, the web API ticket laid out as SteamKit2 lays it out (session part, CRC-32, `str:` identity, ownership ticket, 2,560 bytes), its registration, Steam's ack, cancelling, being logged off|`tests/steam_session_test.c`, ASan and UBSan|
|**Against Steam itself**, the same core: a service call before logon (the sign-in's first step), logon with a refresh token, the persona name, 10 game connect tokens, Brighter Shores' ownership ticket (result OK), the game marked as playing, a web API ticket registered and acknowledged by Steam, then cancelled and logged off; again through the VPN, a 2,560-byte web API ticket|the Python check by hand, Joe's account, 2026-11-11; `emulator/`'s `live_session_through_the_vpn` (`cargo test --release live_session -- --ignored`), by hand, 2026-11-11|
|With no VPN, the network guard refuses lookups and remote connects before anything leaves and passes loopback through; with one, it hands them to the system; tunnel interfaces are told from others|`tests/network_test.c`|
|**The game's network path, end to end**: the guard's arm64 build asks the system proxy settings for a VPN; with one named, a lookup, `socket`, `connect`, `write` and `read` as the client makes them fetch a page through Varrock's ProtonVPN tunnel, which answers with Proton's address (194.36.110.132, not this PC's); with none, the lookup is refused|`pocket-emulator --vpn --probe-network api.ipify.org`, by hand (docs/vpn.md)|
|The folder-walk guard opens the app's home folder for an ancestor the system refuses, and changes nothing else|`tests/paths_test.c`|
|**The client's own startup, emulated, with the layer's adapters running as their arm64 iOS builds**: Steam initialises signed in through the app's session (or offline, `--offline`), the window, Metal layer and pointer images are made, the settings store is created, the nine asset bundles are read, audio starts, all 536 shader libraries are accepted, and frames are presented; the only AppKit messages left unanswered return nothing|`pocket-emulator --frames 3 --check` (docs/emulator.md; docs/client-analysis.md, "Startup, emulated")|
|Without this layer's AppKit additions the client stops at start ("Could not load move cursor")|`pocket-emulator --pinned-appkit`|
|With all 35 of its threads running at once, Metal's completion handlers run and frames paced at 60 a second, the client's asset pool loads the bundles under its loading screen, then from about frame 1,300 (30 s on the host) it draws its next screen, at about 27 frames a second, with no file touched outside its container, the bundle and `/dev/urandom`, and no network lookup|`pocket-emulator --frames 7000`, by hand (docs/client-analysis.md)|
|**The game signs in to its servers through the VPN, emulated**, with Joe's real Steam session behind the bridge: a click on its sign-in, then the roster server, the login server, a web API ticket for `brighter_shores` from the app's session, the server's "login" and its account summary (the account's characters), then a steady exchange while it waits on that screen; nothing went out but through Varrock's tunnel|`pocket-emulator --vpn --steam-live` with the sweep's clicks, by hand, 2026-11-11 (docs/client-analysis.md, "Signing in, emulated")|
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
7. **The game's sign-in on the device**: emulated, it asks for its ticket when the player
   presses its sign-in, and its servers accept it through the VPN (above). On the device, the
   guard's VPN check must see the VPN app's tunnel in the system proxy settings (not yet seen
   on a device).
8. Input (keyboard, pointer, touch), audio output, and frame pacing.

## Known gaps

- **The emulator cannot show the game's screens**, so a run signed in stops its scripted clicks
  the moment the game reaches a server: play is for the device. Signed in and left on the screen
  after its account summary, the game closes its connection itself about a minute later, on the
  emulated clock and on the host's alike; what that screen wants is not known without seeing it.
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
3. Turn the VPN app on. Start with JIT enabled; sign in to Steam when asked. Read the
   Diagnostics log for `[steam] initialised: signed in`, `On-device Metal library ... loaded` or
   `rejected`, `[network] lookup of ... through the VPN` (or `refused: no VPN`) and
   `GetAuthTicketForWebApi(...)`.
4. Note what happened in this file, with the device, OS version and execution mode.
