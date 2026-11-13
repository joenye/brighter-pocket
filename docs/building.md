# Building from the command line

Most people should use the setup app instead: the [README](../README.md#set-up). This page is the same
work by hand, and the routes the app does not take. Everything runs on an Apple silicon Mac with
Xcode; you bring your own copy of the game, and nothing of it is in this repository or the app.

## Once

1. **Xcode** (verified with Xcode 27.2 and its iOS 27.2 SDK). If `xcode-select` names another
   developer folder (the Command Line Tools, or an Xcode elsewhere), set `DEVELOPER_DIR` in
   `local.env` (copied from `local.env.example`); every tool here reaches Xcode through `xcrun`
   with it.
2. **Python tools** (the Python 3.9 macOS ships is enough; the core tools need no packages):

   ```bash
   python3 -m venv .venv && .venv/bin/pip install zstandard pymobiledevice3
   ```

   `zstandard` is for `tools/check_shaders.py`, `pymobiledevice3` for copying the game to a
   device without Xcode's devicectl.
3. **The game**: install Brighter Shores in the Steam app on the Mac, then
   `.venv/bin/python tools/fetch_client.py` copies it, unchanged, into `client/<date>_<manifest>/`
   (about 1 GB). `--depot` downloads it with DepotDownloader instead (`DEPOT_DOWNLOADER`,
   `STEAM_USER`), for a build Steam has not installed (`--manifest`).
4. **Check**: `tests/run.sh` (about a minute) runs everything that runs without a device. With
   `tools/setup_emulator.sh` run once (it needs `brew install cmake` and Rust's cargo), it also
   runs the client's startup in the emulator (docs/emulator.md).

## The companion

```bash
tools/make_companion.sh [--dmg]     # build/Brighter Pocket Companion.app (and .dmg)
tools/release/release.sh --unsigned # a release's files in build/release/, ad hoc
```

Brighter Pocket Companion is Tolkara Management (`platform/docs/MANAGEMENT.md`) built from the
prepared tree, so it carries this layer's source and profile, adapted by `pocket/patches/0020`
onward and `pocket/management/`, and builds Brighter Pocket from that source on the player's
Mac. A local build has its updates off unless `tools/release/sparkle-public-key.txt` holds the
key. Releases are built and signed on GitHub from a tag; [releasing.md](releasing.md) has the
steps, the secrets and how a download is checked.

## On a device, by hand

The platform's own scripts build, sign with your team and install, from the prepared tree:

```bash
python3 tools/prepare.py          # platform/ + patches + this layer -> build/platform
cd build/platform                 # your local.env is copied in
tools/install.sh                  # build, sign, install; with Local signing also the page container
python3 profiles/brighter-shores/install.py --source "$HOME/Library/Application Support/Steam/steamapps/common/Brighter Shores" --device <UDID>
```

with these in `local.env`:

- `DEVELOPMENT_TEAM` (your team's ID; a free Personal Team with `TOLKARA_SIGNING=personal`),
  `DEVICE` (the UDID, `xcrun devicectl list devices`), `TOLKARA_BUNDLE_ID` (unique to you);
- `GUEST_EXE` naming the client's executable, which makes the compatibility libraries for it
  and the page container from it;
- `TOLKARA_MODE=local-signing`, the one route Brighter Pocket supports. (Tolkara's other mode,
  Developer service, is left in `platform/` but is not offered or supported here.)

With Local signing, `tools/install.sh` also runs `tools/give_signing_identity.sh DEVICE BUNDLE
TEAM` once per install of the app (it asks the device whether it has one): your Apple
Development identity goes to the app in a PKCS#12 file under a random passphrase, which only a
launch argument carries; the app keeps it in its keychain and deletes the file. macOS may ask
once to allow the export of the key. With it the app signs the page container for a build that
has none itself (`--again` gives the identity again).

Open the app on the device: it starts Brighter Shores (patch 0028; Tolkara's library shows
only when there is no game or no execution mode). The first time, over the game's main menu,
it asks you to sign in to Steam (account name, password, then a Steam Guard code or approval in
the Steam Mobile app); it keeps Steam's sign-in token in the keychain from then on. Its log is in the Diagnostics menu, and in the app's
`Documents/native-guest.log`.

After Steam updates the game, the app updates it on the device (`docs/architecture.md`,
"Updates"), and signs the new build itself the first time it starts;
it runs as long as it imports nothing the compatibility libraries were not made for. If it
does, the app offers the build before back: run `tools/fetch_client.py`, then
`tools/install.sh` again (the compatibility libraries and the page container are made for one
executable). `tests/depot_live.py` runs the app's download against Steam itself on the Mac, by
hand, as `STEAM_USER` with DepotDownloader's remembered login: `--small DIR` fetches the small
files (real chunks), `DIR EXISTING` fetches a build reusing another, `--installed WORK APP` goes
through an update, a failed start and going back on a copy of APP.

## In the iOS Simulator

```bash
.venv/bin/python tools/run_simulator.py [--seconds N] [--no-steam] [--local-signing] [--launcher-arg ARG] [--env K=V]
```

It builds the app for the simulator with `tools/build_ios.py --simulator --for-client`, boots the
simulator (`SIMULATOR` in `local.env`, default the iPad Pro 13-inch (M5)), copies the client and
shader libraries translated for the simulator into the app's Documents, and starts Brighter
Shores. The simulator is a Mac process, so the memory it maps executes without any of the three
modes; `--local-signing` runs the game's code from a page container all the same, as a device
does with Local signing (built for the simulator, signed ad hoc). The app signs in to Steam with
DepotDownloader's remembered login for `STEAM_USER` (`--no-steam` shows its own sign-in screens
instead). The console, screenshots and the runtime's log land in `build/simulator/<time>/`.
Xcode 27 has no Simulator.app: watch the screen in Xcode's Device Hub. The game runs with
Metal's validation layer (`MTL_DEBUG_LAYER=1`), without which the simulator's Metal fails its
first frame and the screen stays black. If a run stops at
`UNIMPLEMENTED -[NSApplication setMenu:]` for good, the simulator's Metal service is stuck:
`xcrun simctl shutdown all` and run again.

## An unsigned .ipa (External JIT)

`.venv/bin/python tools/build_ios.py --for-client` writes `build/BrighterPocket-unsigned.ipa`
(about 1 MB) for sideloading with SideStore, AltStore or Sideloadly and a JIT enabler such as
StikDebug. It follows the platform's `TolkaraDiagnostics` target: the same sources, compiled and
linked with Xcode's clang; the compatibility libraries from the platform's `tools/build_shims.py`
(made for the client with `--for-client`); `Info.plist` from `launcher/Info.plist` with the keys
Xcode generates; ad hoc signatures declaring the two memory entitlements, as
`tools/package_ipa.sh` does; External JIT preselected. Not yet tried on a device.

## If a device refuses the shaders

The device compiles the client's AIR 1.8 shader libraries itself (an iPhone with iOS 27.2 builds
all of them). If a log says `On-device Metal library <key>: rejected`, translate them all once
with Xcode's Metal toolchain (`xcodebuild -downloadComponent MetalToolchain`) and copy them to the
app's `Documents/TranslatedShaders`, where Tolkara's Metal adapter looks next:

```bash
python3 tools/prepare.py
.venv/bin/python tools/translate_shaders.py --push --device <UDID>   # the 500 distinct libraries
```

## Moving to a newer Tolkara

`tools/update_platform.sh [commit]` replaces `platform/` with that commit and pins it; the
prepare step then names any patch that no longer applies or overlay file that now collides.
Run `tests/run.sh` and commit `platform/` with `pocket/platform.lock`.
