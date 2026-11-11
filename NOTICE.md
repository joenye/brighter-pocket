# Notices

**Tolkara** (MIT, Copyright (c) 2026 Vasilii Kharitonov and the Tolkara contributors,
github.com/tolkara/tolkara) is vendored unchanged at `platform/`; its own `LICENSE` and
`NOTICE.md` are there. Brighter Pocket's changes to it are the patches in `pocket/patches/`.

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

The Linux build links one piece of LLVM's compiler-rt (`os_version_check.c`, Apache-2.0
WITH LLVM-exception), built by `tools/linux/setup_toolchain.sh` from LLVM's source at the
pinned release, into the app as Xcode's copy of the same library would be.

The emulator (`emulator/`, a test tool, not part of the app) links **dynarmic** (0BSD,
azahar-emu's fork of merryhime/dynarmic) and the externals it bundles (fmt, MIT; mcl, MIT;
robin-map, MIT; xbyak, BSD-3-Clause; Zydis and Zycore, MIT), built from source with Boost's
headers (Boost Software License 1.0) by `tools/linux/setup_emulator.sh`, and the Rust crates
listed in `emulator/Cargo.lock` under their own licences; none of them is in this repository.

Nothing from Brighter Shores is in this repository: the game is downloaded per machine
with the user's own Steam account (`tools/fetch_client.py`) into the ignored `client/`.
Brighter Shores is a trademark of Fen Research Ltd. This project is not affiliated with
or endorsed by Fen Research, Valve or Apple.
