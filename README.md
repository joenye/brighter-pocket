# Brighter Pocket

**Brighter Shores' macOS client on an iPad or iPhone, unchanged, signed in to Steam on the device.**

Brighter Pocket does for Brighter Shores what [Slashplayed](https://github.com/paulstraw/slashplayed)
and [WolkaraForever](https://github.com/jklock/wolkaraforever) do for World of Warcraft: the
game's own arm64 Mac client runs natively on the device, and the macOS frameworks it expects are
translated to their iOS equivalents. It is a layer on [Tolkara](https://github.com/tolkara/tolkara),
the runtime WolkaraForever is built on, which loads the unmodified executable as data and
supplies AppKit on UIKit, Metal, audio and the rest.

**Steam without a PC.** The device has no Steam client, and the game exits at start without
one. Brighter Pocket signs in to Steam itself (your account and Steam Guard, once; then a
token in the keychain), and its own Steam library hands the game your account and the web API
tickets the game signs in with, made and registered with Steam as the Steam client makes them.

**The game's servers, through a VPN only.** A network guard in front of the game's socket calls
lets the game reach its servers only while a VPN is up (the ProtonVPN app, say), and otherwise
refuses every host name and every address off the device ([docs/vpn.md](docs/vpn.md)).

**Status: built and checked on Linux, not yet run on a device.** See [docs/status.md](docs/status.md)
for exactly what is verified and what is not.

## What it adds to Tolkara

- a **Steam** library in place of Valve's `libsteam_api.dylib`, and the app's own **Steam
  sign-in and session** behind it;
- the **network guard** (the game's connections through a VPN only), and a guard for the
  client's folder walk under the iOS sandbox;
- the AppKit and QuartzCore calls the client makes that Tolkara lacks (without them it stops at
  start, unable to make its pointer images);
- on-device rewrapping of the client's **AIR 1.8 shader libraries**, which Tolkara refused (all
  536 of them), and the same for Tolkara's Mac translation fallback, with a tool that translates
  them all at once on a Mac should a device refuse them;
- a **profile** naming the game and a helper that copies your own copy to the device;
- a **Linux build** of the whole app (no Mac or Xcode), and Linux tooling to fetch, analyse and
  stage the client, to run Tolkara's loader against it, and to run the client itself in an
  emulator (Rust over the dynarmic JIT, with the layer's adapters): through loading its assets
  to its menu in about half a minute, clicks, and its sign-in through a VPN
  ([docs/emulator.md](docs/emulator.md)).

[docs/client-analysis.md](docs/client-analysis.md) has the findings behind each of these, and
[docs/architecture.md](docs/architecture.md) how they fit.

## Quick start (Linux)

```bash
cp local.env.example local.env          # STEAM_USER, IOS_SDK (an iPhoneOS SDK from Xcode)
python3 -m venv .venv && .venv/bin/pip install zstandard pymobiledevice3
tools/linux/setup_toolchain.sh          # LLVM, ldid
tools/linux/setup_emulator.sh           # dynarmic, for the emulator (needs cargo, cmake, g++)
.venv/bin/python tools/fetch_client.py  # your Steam copy of the macOS game, into client/
tests/run.sh                            # every check that runs without a device
.venv/bin/python tools/build_ios.py --for-client   # build/BrighterPocket-unsigned.ipa
```

Then sideload the `.ipa` with your Apple ID, copy the game with
`pocket/profiles/brighter-shores/install.py`, and open the app with JIT enabled. On a Mac, the
platform's own Xcode scripts build it too. [docs/building.md](docs/building.md) has both routes
in full.

## Layout

|path|what|
|---|---|
|`platform/`|Tolkara, vendored byte for byte at the commit in `pocket/platform.lock`|
|`pocket/`|the layer: `translation/` adapters, `launcher/Pocket/` (Steam sign-in), `profiles/brighter-shores/`, `patches/`, `overlay.map`|
|`tools/`|fetch, analyse and stage the client; prepare the tree; build on Linux (`tools/linux/` stands in for Xcode's tools)|
|`tests/`|`run.sh` and the host tests it builds|
|`docs/`|analysis, architecture, building, status, the VPN|
|`client/`, `build/`, `.toolchain/`|ignored: the game, what is built, the Linux toolchain|

## Licence and notices

MIT ([LICENSE](LICENSE)); Tolkara and other credits in [NOTICE.md](NOTICE.md). Nothing from the
game is in this repository or the app. Not affiliated with or endorsed by Fen Research, Valve or
Apple. Running a game on a platform it was not released for may be against its terms, and your
account could be affected; this build lets the game reach its servers only through a VPN.
