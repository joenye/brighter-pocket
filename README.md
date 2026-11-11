# Brighter Pocket

**Brighter Shores' macOS client on an iPad or iPhone, unchanged, offline.**

Brighter Pocket does for Brighter Shores what [Slashplayed](https://github.com/paulstraw/slashplayed)
and [WolkaraForever](https://github.com/jklock/wolkaraforever) do for World of Warcraft: the
game's own arm64 Mac client runs natively on the device, and the macOS frameworks it expects are
translated to their iOS equivalents. It is a layer on [Tolkara](https://github.com/tolkara/tolkara),
the runtime WolkaraForever is built on, which loads the unmodified executable as data and
supplies AppKit on UIKit, Metal, audio and the rest.

**Offline, by design.** The device has no Steam client, and the game exits at start without one;
Brighter Pocket's own Steam library answers as a Steam that is running but offline. A network
guard in front of the game's socket calls refuses every host name and every address off the
device. So the game can start, but it cannot reach its servers or sign in.

**Status: built and checked on Linux, not yet run on a device.** See [docs/status.md](docs/status.md)
for exactly what is verified and what is not.

## What it adds to Tolkara

- an offline **Steam** library in place of Valve's `libsteam_api.dylib`;
- the **network guard**;
- the AppKit and QuartzCore calls the client makes that Tolkara lacks;
- on-device rewrapping of the client's **AIR 1.8 shader libraries**, which Tolkara refused (all
  536 of them);
- a **profile** naming the game and a helper that copies your own copy to the device;
- a **Linux build** of the whole app (no Mac or Xcode), and Linux tooling to fetch, analyse and
  stage the client and to run Tolkara's loader against it.

[docs/client-analysis.md](docs/client-analysis.md) has the findings behind each of these, and
[docs/architecture.md](docs/architecture.md) how they fit.

## Quick start (Linux)

```bash
cp local.env.example local.env          # STEAM_USER, IOS_SDK (an iPhoneOS SDK from Xcode)
python3 -m venv .venv && .venv/bin/pip install zstandard pymobiledevice3
tools/linux/setup_toolchain.sh          # LLVM, ldid
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
|`pocket/`|the layer: `translation/` adapters, `profiles/brighter-shores/`, `patches/`, `overlay.map`|
|`tools/`|fetch, analyse and stage the client; prepare the tree; build on Linux (`tools/linux/` stands in for Xcode's tools)|
|`tests/`|`run.sh` and the host tests it builds|
|`docs/`|analysis, architecture, building, status|
|`client/`, `build/`, `.toolchain/`|ignored: the game, what is built, the Linux toolchain|

## Licence and notices

MIT ([LICENSE](LICENSE)); Tolkara and other credits in [NOTICE.md](NOTICE.md). Nothing from the
game is in this repository or the app. Not affiliated with or endorsed by Fen Research, Valve or
Apple. Running a game on a platform it was not released for may be against its terms; this
build stays offline.
