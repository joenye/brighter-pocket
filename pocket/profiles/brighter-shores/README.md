# Brighter Shores (macOS, Steam)

**Status: played on an iPhone** (iPhone19,4, iOS 27.2, Local signing and Developer service, 12 and 13 November 2026):
the app signs in to Steam, and the game signs in to its servers and plays. Built against the
macOS client of 12 November 2026 (Steam manifest 1608971154801325014); see the Brighter Pocket
repository's `docs/status.md`.

**Steam, on the device.** Brighter Shores signs its players in with a Steam ticket, and the
device has no Steam client, so the app signs in to Steam itself when you start the game: your
Steam account name and password the first time (they go only to Steam), then Steam Guard (a
code, or approve the sign-in in the Steam Mobile app). It keeps Steam's sign-in token in the
device's keychain and signs in with it from then on. The game gets your account and its tickets
from that session, through the layer's Steam library (`translation/libsteam_api`). You can
choose to play offline instead.

You need your own copy of Brighter Shores from Steam (the macOS build). Nothing from the game
is included here.

## Copy the game

The easy way is Brighter Pocket Companion, the Mac app that finds the game in Steam, builds the app
and copies the game for you (the Brighter Pocket repository's README, "Set up"). By hand, on a
Mac with Steam: install Brighter Shores, then

```bash
python3 profiles/brighter-shores/install.py --source "$HOME/Library/Application Support/Steam/steamapps/common/Brighter Shores" --device <UDID>
```

`--source` takes Steam's folder for the game, its `x64arm64` folder or `Brighter Shores.app`
itself. `--via pymobiledevice3` copies without Xcode's devicectl.

Or stage it (`--stage-only DIR`) and copy the `Brighter Shores` folder into the app's folder
with the Files app. The script copies `Brighter Shores.app` unchanged, about 1 GB, except
Valve's `libsteam_api.dylib`, which the device cannot use, and checks the executable's SHA-256
before and after.

Open the app: it starts the game (patch 0028).

**Execution mode.** Local signing, Brighter Pocket Companion's default: the client never changes
its own code (it imports no call that could make code writable) and no fixup lands in its
`__TEXT`, so its page container is built from the executable as it is, with no capture
(`TOLKARA_MODE=local-signing tools/install.sh` builds and copies it, and gives the app the
identity to sign one itself for a later build). Played on an iPhone this way on 13 November
2026. It is the only mode offered here (docs/building.md).
