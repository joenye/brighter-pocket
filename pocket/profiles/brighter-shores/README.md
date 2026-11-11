# Brighter Shores (macOS, Steam)

**Status: not yet run on a device.** The client's loading, imports and Steam and network
behaviour were checked on Linux against the macOS build of 9 November 2026 (Steam manifest
2069922974376902512); see the Brighter Pocket repository's `docs/status.md`.

**Offline.** This profile is used with the layer's offline Steam library
(`translation/libsteam_api`) and network guard (`translation/libSystem.B`): Steam starts
"offline" and the game cannot resolve or connect to any server, so it cannot sign in. That is
deliberate for now.

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
