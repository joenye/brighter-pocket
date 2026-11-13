# Status

As of 13 November 2026. **Brighter Shores runs on an iPhone**, signed in to Steam on the device,
and plays: the macOS client, unchanged, through Tolkara and this layer.

## On a device

|device|OS|execution mode|result|
|---|---|---|---|
|iPhone19,4 (iPhone Duo: an inner 2853x2007 and an outer 2034x1398 screen)|iOS 27.2 (24B91020)|Developer service|Memory prepared in about 22 s; the app signs in to Steam on the device (account name, password, Steam Guard), then the game starts, all 500 distinct shader libraries are built by the iPhone's own Metal compiler (none rejected), the game renders at 60 fps on both screens, signs in to its servers with a Steam web API ticket made by the app's session, and plays. 2026-11-12.|
|same|same|**Local signing**|No tunnel and no wait: the runtime matches the Mac-built container to the executable (3,236 pages), maps them read and execute, runs the initializers and `main`; the game reaches its title screen, signed in to Steam, and is played in the world. 2026-11-13.|
|same|same|**Local signing, signed on the device**|With the Mac's container removed, the app builds and signs the container itself with the identity `tools/give_signing_identity.sh` gave it (`[signing] page container ... built and signed on the device: 3236 __TEXT pages`); iOS loads it (`dlopen ok`, `signed suffix remap result=0`) and the game starts. 2026-11-13.|

|same|same|Local signing, 13 November, later|Opening the app starts the game (patch 0028): the loading screen, "Checking for updates…", then the title screen, no library; the notice "Brighter Shores is up to date"; Settings › Builds reads `11-Nov-2026 15:19 UTC (v0.104.2) · Up to date`, signed in as the account. The launcher's screens and the game turn with the phone (the game upright on the outer screen at 120 fps), the on-screen buttons reach the screen's edge, and the loading screen is centred on the whole width. 2026-11-13.|

Seen on that device:

- The sandbox refuses the folders above the app's container (`/var`, `/var/mobile`, ...); the
  folder-walk guard answers for them and the game makes its save folder.
- Switching to another app (the Steam Mobile app for a Steam Guard code, a VPN app) closes the
  app's Steam connection. The sign-in makes it again for each step, and the game's Steam
  session is signed in again with the kept login when the game next asks for a ticket.
- Developer service needs the launcher to enter the game from a run-loop timer: started from a
  main-queue block, memory preparation waits for good (`PocketSteamLaunch.m`).
- The frame rate: at 60 fps with 13 ms waits for a drawable and 0.7 ms of GPU time, the screen
  was the limit, not the game. With the settings' display link asking for the rate, the title
  screen runs at 120 fps on the outer screen (8.3 ms) and the world at about 90 fps on the inner
  one (7 to 12 ms of GPU time, now the limit).
- One connection manager reset every TLS handshake for a while; the app now tries the next.
- Away to another app for 45 s and back (patch 0026): the game was still running, at its title
  screen.

## Verified on the Mac (`tests/run.sh`)

|what|evidence|
|---|---|
|The macOS client is copied unchanged from the Mac's Steam install (or downloaded from Steam's content servers)|`tools/fetch_client.py`; the executable's SHA-256 in `client/*/.complete`, checked again by the copy helper before and after staging|
|Every import has a provider on iOS (SDK 27.2, Tolkara's and this layer's adapters)|`tools/analyze_client.py`: 232 imports, 0 unprovided|
|Tolkara's loader places the staged client: no carried library, all 65,108 fixups applied, all 8 Steam imports bound to the Steam library's arm64 exports|`tests/loader_test.c`, cross-checked pointer by pointer against `tools/macho.py` by `tests/loader_check.py`: 0 differences|
|The Steam library behaves as the client's C++ calls expect (vtable slots, callback objects), offline and with the app's session behind its bridge|`tests/steam_test.cpp`, ASan and UBSan|
|The app's Steam session core frames and reads Steam's messages as Steam does, from hello to a registered web API ticket and logoff|`tests/steam_session_test.c`, ASan and UBSan; against Steam itself by hand: `cargo test --release live_session -- --ignored`|
|The folder-walk guard opens the app's home folder for an ancestor the system refuses, and changes nothing else|`tests/paths_test.c`|
|All 536 shader libraries pass the on-device rewrap's checks with patch 0003, and the Mac translation reads all 536 with patch 0004|`tools/check_shaders.py --translator`|
|The layer's sources compile for arm64 iOS and the iOS Simulator with warnings as errors; the whole app builds|`tests/run.sh`; `tools/build_ios.py`|
|**The client's own startup, emulated** with the layer's adapters as their arm64 iOS builds: Steam signed in through the app's session, window, Metal layer, pointer images, settings store, the nine asset bundles, audio, all 536 shader libraries accepted, frames presented|`pocket-emulator --frames 3 --check` (docs/emulator.md)|
|Emulated to the menu, all 39 threads at once: loading gives way at about frame 600 (13 to 15 s on an M3 Pro), then about 58 frames a second|`pocket-emulator --frames 7000`, by hand|
|A Local-signing page container is built from the client's own `__TEXT` and signed with the developer certificate, with no keychain prompt|`tools/build_signed_container.py` with patch 0009 (3,236 pages, first initializer in `__TEXT`, no fixup there)|
|**Local signing runs the client**: in the iOS Simulator the runtime matches the container to the executable (header and load commands identical), maps its 3,236 signed pages read and execute, runs the five initializers and `main`, and the game reaches its title screen signed in to Steam|`tools/run_simulator.py --local-signing` (`[signed-image] container matches the guest`), screenshot|
|**The game draws in the iOS Simulator**: Brighter Shores' title screen, signed in to Steam, with shader libraries translated for the simulator (patches 0007, 0008), through Metal's validation layer (without it the simulator's Metal fails the first frame)|`tools/run_simulator.py`, screenshot (iPad Pro 13-inch)|
|**The in-game settings, in the game**: the gear beside the on-screen controls and its sheet; the performance overlay (frames a second, frame time, target, worst frame); the frame-rate cap (30 fps capped reads 30 fps and 33.4 ms, 60 reads 60 and 16.7 ms); portrait; the safe-area border on and off; hiding the on-screen controls; each kept across launches|Brighter Shores in the iPhone Duo simulator (`tools/run_simulator.py`, `--settings-demo` and preset settings), screenshots|
|**The layer's screens in iOS's own style** (patch 0027): the loading screen's bar following the runtime log while the game starts, and the count it reached kept for the next start; the Steam sign-in form sheet; the in-game settings sheet|`tools/run_simulator.py` (`--no-steam`; `--offline --launcher-arg=--open-settings`) on the iPhone Duo simulator, screenshots|
|**Game updates without the Mac** (`PocketDepot.m`, `PocketInstalledGame.m`): against Steam itself, the public branch's build and manifest read from PICS; the whole macOS depot (930 MB) fetched from Steam's content servers in 54 s, every chunk decrypted, decompressed (zstd) and checked, identical to the Steam install; the same build fetched reusing the installed one in 2 s; an update put in place, a failed start offered back, going back, and the build before removed once the new one starts|`tests/depot_live.py` (by hand, as the account in `STEAM_USER`)|
|Brighter Pocket Companion builds from this repository and finds the game in Steam's library by itself|`tools/make_companion.sh --dmg`; its Game page|

## Not verified yet

- **A free Personal Team's build on a device** (patch 0031): `TOLKARA_SIGNING=personal` builds
  without the tunnel and extended virtual addressing, with the increased memory limit when the
  team may have it. It compiles (`TolkaraPersonal`, generic iOS), but no free team has built,
  signed and run it yet, and the game's memory without the paid capabilities is not measured.
- **The companion's release and update path** (patch 0034, `.github/workflows/release.yml`):
  an unsigned trial (`tools/release/release.sh --unsigned`) builds the DMG, the appcast and the
  notes, and a build with a public key starts Sparkle and checks at launch; no release has been
  signed, notarized, attested or published yet (the secrets and keys are not set up), so no
  update has been offered or installed. The workflows pass actionlint but have not run on GitHub.
- **"Pocket" on a device's Home Screen** (`TOLKARA_DISPLAY_NAME`, patch 0035): the .ipa and the
  Xcode project carry it, and the app's own text keeps "Brighter Pocket"; not installed on a
  device yet. A phone with the earlier "Brighter Pocket" build keeps its data (same bundle ID).
- **A real update on the device**: no new build has come from Steam since; the download, the
  staging, putting a build in place and going back run on the Mac against Steam
  (`tests/depot_live.py --installed`). Nor has the "Playing elsewhere" question been seen (the
  account's playing state itself is read: `depot_live` reports the game running elsewhere).
- **The sign-in at the main menu on the device**: seen in the iOS Simulator (no kept login: the
  game starts offline and the sign-in sheet comes over its title screen); the phone has a kept
  login.
- **The game's servers across a trip to another app**: the app keeps running in the background
  (patch 0026); whether the game's own server connection survives a long absence in the world
  is not measured yet.
- **The touch gestures on the device**: double-tap to right-click, pinch to zoom and the cursor
  speed pass their host test (`tests/trackpad_test.c`); a player has not yet tried them.
- **A stale Steam session caught before the game signs in**: the keepalive and the ticket
  acknowledgement are in place; the case reported (idle at the main menu, then every sign-in
  to the game refused) has not been reproduced since.
- **External JIT** (a sideloaded `.ipa` with StikDebug or SideStore) has not been tried.
- Long sessions, memory on smaller iPhones, game controllers.

## Known gaps

- **In-game purchases** need the Steam overlay, which the device has none of.
- **NSSharingServicePicker** is a logging stub (the game's share menu does nothing).
- **The emulator cannot show the game's screens**: it checks startup and the game's calls, not
  pictures.

## Reporting a device run

Note the device, OS version and execution mode here, with what the Diagnostics log shows:
`[steam] initialised: signed in`, `On-device Metal library ... loaded` or `rejected`, and
`GetAuthTicketForWebApi(...)`.
