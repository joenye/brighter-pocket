# Brighter Shores (macOS, Steam)

**Status: not yet run on a device.** The client's loading, imports and Steam and network
behaviour were checked on Linux against the macOS build of 9 November 2026 (Steam manifest
2069922974376902512); see the Brighter Pocket repository's `docs/status.md`.

**Steam, on the device.** Brighter Shores signs its players in with a Steam ticket, and the
device has no Steam client, so the app signs in to Steam itself when you start the game: your
Steam account name and password the first time (they go only to Steam), then Steam Guard (a
code, or approve the sign-in in the Steam Mobile app). It keeps Steam's sign-in token in the
device's keychain and signs in with it from then on. The game gets your account and its tickets
from that session, through the layer's Steam library (`translation/libsteam_api`). You can
choose to play offline instead.

**The game's servers stay out of reach.** The layer's network guard (`translation/libSystem.B`)
refuses every connection the game itself makes, so it cannot yet sign in to its servers with
the ticket. That is deliberate for now.

You need your own copy of Brighter Shores from Steam (the macOS build). Nothing from the game
is included here.

## Copy the game

On a Mac with Steam: install Brighter Shores, then

```bash
python3 profiles/brighter-shores/install.py --source "$HOME/Library/Application Support/Steam/steamapps/common/Brighter Shores" --device <UDID>
```

On Linux, download the macOS build with the Brighter Pocket repository's
`tools/fetch_client.py` (your Steam account), then copy it with pymobiledevice3:

```bash
python3 profiles/brighter-shores/install.py --source "client/<folder>/x64arm64" --device <UDID> --via pymobiledevice3
```

Or stage it (`--stage-only DIR`) and copy the `Brighter Shores` folder into the app's folder
with the Files app. The script copies `Brighter Shores.app` unchanged, about 1 GB, except
Valve's `libsteam_api.dylib`, which the device cannot use, and checks the executable's SHA-256
before and after.

Open the app, choose an execution mode if it asks, and tap Brighter Shores in the library.

**Execution mode.** The client never changes its own code (it imports no call that could make
code writable), so every mode applies; with Local signing the page container can be built
from the executable as it is, with no capture.
