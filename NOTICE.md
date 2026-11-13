# Notices

**Tolkara** (MIT, Copyright (c) 2026 Vasilii Kharitonov and the Tolkara contributors,
https://github.com/tolkara/tolkara), a compatibility layer that runs macOS apps on iOS (as Wine
or Proton run Windows apps elsewhere), is vendored unchanged at `platform/`; its own `LICENSE`
and `NOTICE.md` are there. Brighter Pocket's changes to it are the patches in `pocket/patches/`.
The app shows its own name, Brighter Pocket; its settings credit Tolkara with that link.

Brighter Pocket's icon is the **Brighter Atlas** mark (https://brighteratlas.com, by the same
author), drawn from `webapp/brand/mark.svg` of the brighter-atlas repository, its A replaced by
the Apple logo (drawn from macOS's own font by `tools/make_icons.py`; Apple's trademark, not
Apple's endorsement).

The layering (a byte-identical platform, patches, an overlay map) follows
**WolkaraForever** (MIT, github.com/jklock/wolkaraforever); no code was copied from it.
**Slashplayed** (MIT, github.com/paulstraw/slashplayed) was read for its account of
executable memory under TXM and its loader; no code was copied from it.

The Steam library (`pocket/translation/libsteam_api`) is original code. The order of the
methods in its interface tables follows Valve's public Steamworks headers for the interface
versions the client names (SteamUser023, SteamFriends017, SteamUtils010,
STEAMAPPS_INTERFACE_VERSION008), as the Goldberg emulator fork (gbe_fork, LGPL-3.0) lists
them; no Steamworks or emulator source is included.

The app's Steam session (`pocket/launcher/Pocket`) is original code. Its message numbers and
fields are Steam's, as SteamKit2 (LGPL-2.1, github.com/SteamRE/SteamKit) and SteamDatabase's
Protobufs (github.com/SteamDatabase/Protobufs) document them, and its web API ticket follows
the layout SteamKit2's `SteamAuthTicket` builds; no code from either is included.

Game updates (`pocket/launcher/Pocket/PocketDepot.m`) read Steam's content system as SteamKit2
and DepotDownloader (GPL-2.0, github.com/SteamRE/DepotDownloader) document it; no code from
either is included. Depot chunks are decompressed by **zstd**'s reference decoder (BSD, Copyright
(c) Meta Platforms, Inc. and affiliates, github.com/facebook/zstd, `doc/educational_decoder`),
vendored unchanged at `pocket/launcher/Pocket/zstd/` with its `LICENSE`, and by the system's
liblzma.

The emulator (`emulator/`, a test tool, not part of the app) links **dynarmic** (0BSD,
azahar-emu's fork of merryhime/dynarmic, with this repository's changes in
`emulator/dynarmic-patches/`) and the externals it bundles for its arm64 backend (fmt, MIT;
mcl, MIT; oaknut, MIT; robin-map, MIT), built from source with Boost's headers (Boost Software
License 1.0) by `tools/setup_emulator.sh`, and the Rust crates listed in `emulator/Cargo.lock`
under their own licences; none of them is in this repository.

Nothing from Brighter Shores is in this repository or in the app: each user's own copy of the
game, installed through their own Steam account, is copied unchanged from their Mac to their
device (`tools/fetch_client.py`, `pocket/profiles/brighter-shores/install.py`), or downloaded
unchanged from Steam by the app, signed in as them. Brighter Shores
is a trademark of Fen Research Ltd. This project is not affiliated with or endorsed by Fen
Research, Valve or Apple.
