# The macOS client: what it needs from iOS

Findings on the macOS Brighter Shores client, read on Linux from the file alone (nothing was
run). Every number here is reproduced by the tool named beside it; `tests/run.sh` runs them
all. Build: Steam depot 2791442 (macOS), manifest 2069922974376902512, 9 November 2026.

## Identity (`tools/analyze_client.py`)

|field|value|
|---|---|
|bundle|`x64arm64/Brighter Shores.app`: executable, Valve's `libsteam_api.dylib`, `assetBundle0` to `8`, about 1 GB|
|executable|universal (x86_64 and arm64), SHA-256 `cedf14d2d57c17de01840443c4d15703ada50fc23e334665768de7163b193437`|
|arm64 slice|54.3 MB, `__text` 51.4 MB, built for macOS 12.0 with the 26.2 SDK, not encrypted|
|fixups|chained, `DYLD_CHAINED_PTR_64_OFFSET`: 64,845 rebases, 269 binds of 236 imports|
|startup|5 initializers (`__init_offsets`), thread-local variables, no TLS initializers|

**It never writes its own code.** It imports none of `mprotect`, `vm_protect`, `mach_vm_protect`,
`vm_remap`, `pthread_jit_write_protect_np`, `sys_icache_invalidate` or `__clear_cache`. So
every execution mode applies, and a Local-signing page container is built from the file's own
`__TEXT` with no capture (World of Warcraft needs a capture because it unpacks its code).

## Imports

The client links 19 libraries and imports from 12 of them, plus 4 symbols bound by name.
Against the iOS 26.4 SDK, with Tolkara's adapters and this layer's:

|library|imports|on device|
|---|---:|---|
|libSystem|125|iOS; `connect` and `getaddrinfo` through the network guard (`pocket/translation/libSystem.B`)|
|libc++|34|iOS|
|AppKit|15|Tolkara's AppKit adapter; NSPasteboard, NSWorkspace added by `PocketCompat.m`; NSSharingServicePicker and `NSEventTrackingRunLoopMode` stubbed|
|libobjc|13|iOS|
|libsteam_api (`@loader_path`)|8|the offline Steam library (`pocket/translation/libsteam_api`)|
|Foundation, CoreFoundation, Metal|8 each|iOS; Metal through Tolkara's adapter (devices, shader rewrap)|
|AudioToolbox|7|Tolkara's adapter (the default output unit becomes RemoteIO)|
|CoreGraphics|4|Tolkara's adapter (`CGDisplay*` display queries)|
|Security, QuartzCore|1 each|iOS (`SecRandomCopyBytes`, `CAMetalLayer`)|
|operator new/delete (bound by name)|4|libc++|

Carbon, Cocoa, CoreVideo, CoreAudio, GameKit, StoreKit and Quartz are linked but nothing is
imported from them. No import is left without a provider.

## The application's shape

Three Objective-C classes of its own: `MyAppDelegate` (launching and termination),
`MyWindowView : NSView` (first responder, mouse, scroll wheel, keys, `opaque`) and
`MyWindowDelegate` (resize, backing scale, screen, full screen, occlusion, key status). It
pumps its own events (`nextEventMatchingMask:untilDate:inMode:dequeue:`, `sendEvent:`) and
draws into a `CAMetalLayer` it sets on its view. 355 selectors are referenced. Against
Tolkara's AppKit, the gaps were the classes above, the named cursors and
`+[NSBitmapImageRep imageRepWithData:]` (its pointer images), and
`-[CAMetalLayer setDisplaySyncEnabled:]`, which iOS does not have and would raise on: all
added by `pocket/translation/AppKit/PocketCompat.m`. The remaining unimplemented selectors
(`setLevel:`, `setStyleMask:`, `setFrame:display:`, `center`, `setTitle:`, `setMaxSize:`,
`setAcceptsMouseMovedEvents:`, `setPresentationOptions:`) return nothing and are answered by
the adapter's logging stub, which is harmless for them.

It finds its data at `[[NSBundle mainBundle] bundlePath]/Contents/Resources/assetBundle%d`
(Tolkara answers `mainBundle` with the guest's bundle), keeps an embedded SQLite store under
Application Support, and must start on the main thread, where Tolkara runs it.

## Steam

The client starts Steam before anything else. If `SteamInternal_SteamAPI_Init` fails it prints
"Failed to init Steam" and calls `exit(0)`: on a device with no Steam client, Valve's library
would end the game at once. So the library standing in for it must initialise. What the client then asks:

- interfaces `SteamUser023`, `SteamFriends017`, `SteamUtils010` and
  `STEAMAPPS_INTERFACE_VERSION008`, through `SteamInternal_ContextInit` accessors;
- `GetPersonaName`, `GetSteamID`, `IsOverlayEnabled`, `MarkContentCorrupt`;
- `GetAuthTicketForWebApi`, with callback 168 (`GetTicketForWebApiResponse_t`) registered for
  the ticket, and callback 152 (`MicroTxnAuthorizationResponse_t`, in-game purchases).

The web API ticket is how a game session is authenticated: the game sends it to its servers,
which check it with Steam. With the app signed in to Steam (`docs/architecture.md`, "Steam"),
the library answers with the account's Steam ID and persona name and a real ticket made by the
app's session; offline, as Steam does when running but offline: initialised, not logged on,
`k_steamIDNil`, and a ticket result of "no connection" (`tests/steam_test.cpp` checks both).

The session was checked against Steam itself (`tests/steam_live.py`, Joe's account, 2026-11-11):
a service call before logon, logon with a refresh token, the persona name, ten game connect
tokens, Brighter Shores' ownership ticket, the game marked as playing, and a web API ticket
registered with `CMsgClientAuthList` and acknowledged by Steam (`CMsgClientAuthListAck` naming
its CRC), then cancelled. Whether the game's servers accept such a ticket cannot be seen while
the network guard keeps the game from them.

## Network

`socket`, `getaddrinfo`, `connect`, `poll`, `getsockopt`, `setsockopt`, then `read`, `write`,
`fcntl` and `close` on the socket, and nothing else: no URL loading, CFNetwork or Network
framework. One lookup and one connect path; the server name is not in the executable's strings
(it arrives from game data at run time). The network guard lets them through only while a VPN
is up and otherwise refuses every host name and every non-loopback address
(`tests/network_test.c`, `docs/vpn.md`), and logs what was attempted.

## Rendering

Metal throughout. Depth and stencil formats are Depth32Float, Stencil8 and
Depth32Float_Stencil8, all available on iOS (no Depth24Unorm_Stencil8). The device queries it
makes that iOS lacks (`isLowPower`, `isHeadless`, `MTLCopyAllDevices`) Tolkara answers.

**Shaders** (`tools/check_shaders.py`): 332 fragment libraries in `assetBundle4` and 204 vertex
libraries in `assetBundle7`, each a container-version-2 Metal library holding **AIR 1.8**,
whose function records carry no module size (MDSZ). Tolkara's on-device rewrap accepted only
AIR 2.x with MDSZ, so the pinned Tolkara refuses all 536 (`--pinned`), which would leave the
game dependent on shader translation from a Mac. `pocket/patches/0003` takes the module to run
to the next one or the end of the code section; the SHA-256 each function records then matches
in all 536, and all are accepted. Whether the iPad's Metal compiler builds AIR 1.8 is the first
thing to see on a device.

If it does not, Tolkara's fallback sends the library to a Mac (`tools/serve_shader_translation.py`
over USB), whose `tools/translate_metallib.py` compiles it for iOS with Apple's tools. That script
had the same two requirements, so it could not read any of the 536 either ("missing module
metadata"). `pocket/patches/0004` reads them the same way and, AIR 1.x having no iOS revision of
its own, compiles each module for iOS 14, through Apple's upgrade pass to AIR 2.3 where the
compiler refuses it as it is. `tools/check_shaders.py --translator` checks that it reads all 536;
whether Apple's tools accept AIR 1.8 has to be seen on a Mac.

## Loading (`tests/loader_test.c`, `tests/loader_check.py`)

Tolkara's own loader (`GuestImage`, `GuestLink`, `GuestFixups`), compiled for Linux, reads the
staged executable, finds no carried library (Valve's is left out by staging), and applies all
65,114 fixups with a slide; `tools/macho.py`, an independent reader, agrees on every location,
value and bound symbol. All 8 Steam imports resolve to the offline library's exports, taken from
its arm64 iOS build.

## Startup, emulated (`tests/emulate/boot.py`)

The client's own startup, run on the host in an arm64 emulator (Unicorn): its initializers,
then `main`, on one thread, with this layer's adapters running as their real arm64 iOS builds
(the Steam library; `connect`, `getaddrinfo` and `opendir` from the libSystem adapter) and
everything else answered as the device would answer it, Tolkara's AppKit answering exactly the
selectors its adapter implements (nil for the rest, as its stub classes do). What it does:

1. about a thousand class initializers, then Steam (`Initialized Steam API`, offline);
2. `NSApplication`, a menu bar, its window and `MyWindowView` with a `CAMetalLayer`, and its 5
   pointer images from 10 embedded PNGs through `+[NSBitmapImageRep imageRepWithData:]`;
3. `Client.initialize()`: its settings store, an SQLite database under
   `Application Support/Fen Research/save_local_steam_live/`, made by a folder walk from the root;
4. the nine asset bundles, read from the app bundle (`assetBundle%d` under `bundlePath`);
5. audio: the default output unit, stream format, initialise, start;
6. Metal: the device (`MTLCopyAllDevices`), all 536 shader libraries (every one accepted by the
   rewrap's checks), pipelines, samplers, depth-stencil states; then its event loop, presenting a
   frame through `presentDrawable:afterMinimumDuration:` each turn.

It starts 35 threads: one that works through a list of memory blocks, and a pool of 34 that
reads the asset bundles. By default they are recorded, not run, and the startup above needs none
of them. `boot.py --threads` runs them by turns (`tests/emulate/threads.py`: mutexes, condition
variables, futures, semaphores, each waiter served in the order it came) and has Metal run each
command buffer's completion handler and each drawable's presented handler once the buffer is
committed, as the GPU does when it is done. The client paces its frames by two semaphores those
handlers signal (two frames in flight, three drawables), so without them it stops after its
third frame.

Time is the emulator's own: the client's clocks (`steady_clock`, `system_clock`,
`gettimeofday`, `time`) read a clock that moves 2 µs for each call the emulator answers, by the
length of each sleep, to a timed wait's deadline when nothing else can run, and at least 1/60 s
per presented frame, as vertical sync paces the device. The host's clock would make every frame
look seconds long to the client; this one makes a run the same every time. (With `--vpn` it
becomes the host's at the first input: docs/vpn.md, "The clock".)

How fast it runs. Unicorn (QEMU's code translator) runs the client's own arm64 on one x86 core
at about 23 million translated blocks a second (measured over the first 300 frames; a tight
loop alone runs at 3 billion instructions a second, the client's real code with its memory
traffic far slower), and the client's threads take turns on it instead of sharing cores. Around that,
the harness costs as little as it can: an answered import is an `svc` in its slot, so Unicorn
stops for Python only when one runs (a code hook over the slots, beside Unicorn's instruction
count, made every instruction several times slower); a turn ends after 400,000 blocks,
counted by a block hook in C (`tests/emulate/host/turns.c`), as repeatable as the count was;
the client's one thread-local variable (2.2 million lookups in its first 300 frames) is four
arm64 instructions on the thread's own block (`boot.py`, `_native_thread_vars`); and its
allocator and memory routines, nine in ten of its calls while it loads, are arm64 of the
harness's own on a heap of their own (`tests/emulate/native/heap.c`). Its first 300 frames
took 60 s before these and take 26 s now; what is left is the client's own work, above all
its texture copies while it loads.

Run so for 6,000 frames (100 s of the emulated clock; about 6.5 minutes on the host to frame
5,099), the pool reads the asset bundles while the client draws a loading screen of 13 meshes
a frame; at about frame 4,600 the heap settles near 1 GB and the client draws 25 meshes a frame,
its next screen (95,315 meshes by frame 6,000). No file outside its container, the bundle and
`/dev/urandom` is touched, and no network address is looked up.

A save point spares the loading: `boot.py --threads --serve-from 5099` loads once and waits
there; each `boot.py --attach [options]` forks it and runs on from frame 5,099 with its own
clicks, network and Steam session (`tests/emulate/savepoint.py`): to the sign-in in 6 seconds,
to frame 6,000 in 32. A try from a save point at frame 20 to frame 40 matched a run from the
start exactly (clock and meshes).

`--click X,Y@FRAME` hands a click to the client as Tolkara's AppKit hands it a touch:
`-[MyWindowView mouseDown:]`, the client's own, reads `locationInWindow`, scales it to pixels and
queues it for the game. The emulator does not see what is drawn, so it cannot aim at a button.
Swept over the screen after loading (from frame 5,100, every 90 points across and 60 up), the
clicks reach the game's own buttons: one at (970, 120) points from the bottom left makes the
client call `-[NSApplication terminate:]`, its quit button, where Tolkara's AppKit exits as macOS
does. The other 220 clicks (24 before it, 196 in the rows above in a second run) change what it
draws but start no sign-in (no ticket asked of Steam) and no lookup in a run played offline.
Signed in through the app's session, the 34th click of the sweep, at (610, 180) after the 33
before it, starts the game's sign-in ("Signing in, emulated" below).

Memory: by the third frame the main thread has allocated about 275 MB, and with the pool
loading, the emulated heap holds about 1 GB once the loading screen is past (1,054 MB at 6,000
frames; an upper bound: blocks are kept in 4 KiB size classes and never merged). Nothing large is
reserved with `mmap` (3.1 MB at most). An iPad's limit is
well above that; on an iPhone it is closer, and a free Apple ID cannot grant the
increased-memory entitlement.

Three things it found that would have stopped the game on the device, all answered by the layer:

- **The pointer images.** The pinned Tolkara's `NSBitmapImageRep` has no `imageRepWithData:`,
  so it answers nil, and the client stops at once with "exception: Could not load move cursor"
  (`boot.py --pinned-appkit`). `PocketCompat.m` decodes the PNG with UIImage.
- **The folder walk.** For each folder above its save folder the client calls `opendir`, and
  `mkdir` only where that fails; a failed `mkdir` ends the walk. If the sandbox refuses to open
  the folders above the app's container, `mkdir` answers EEXIST there and the settings store is
  never made. `ContainerPaths.c` answers such an `opendir` with the app's home folder. (Whether
  the sandbox refuses them is not known without a device; the emulator assumes it does.)
- **Display sync.** The client sends `-[CAMetalLayer setDisplaySyncEnabled:]` twice while it
  sets up its layer. The iOS SDK marks it unavailable on iOS, so on the device's `CAMetalLayer`
  it would raise (the emulator treats it so without the layer); `PocketCompat.m` adds it where
  the class lacks it.

The only AppKit messages left unanswered are `-[NSApplication setMenu:]`, `-[NSWindow center]`
and `-[NSWindow setMaxSize:]`, which return nothing. `tests/run.sh` runs this to 3 frames.

## Signing in, emulated (`boot.py --threads --vpn --steam-live`)

With the network up through Varrock's VPN and Joe's real Steam session behind the bridge
(`docs/vpn.md`), the sweep's clicks up to (610, 180) at frame 5,232, then, frame by frame:

|frame|what the game did|
|---:|---|
|5,234|asks for random bytes (`SecRandomCopyBytes`), looks up `roster1.fenresearch.com` with no service|
|5,235 to 5,237|connects to it on port 15451; 322 bytes out, 141 back; closes|
|5,237 to 5,238|looks up and connects to a numeric address the roster named, port 15401 (the login server)|
|5,239 to 5,240|its first exchange; the server's reply carries the sign-in's states ("Logging in...", "Loading save game...")|
|5,240 to 5,241|asks the app's session for a web API ticket for the identity `brighter_shores` and sends it (2,618 bytes)|
|5,245 to 5,251|the server calls "login"; the game answers; then the account summary, the account's characters|
|5,251 to 6,769|20 bytes out, 12 and 13 back, every third frame, while it waits on that screen|
|6,769|the game closes the connection itself; it makes no other to frame 7,236|

Each message is a length byte then its body, every byte masked with one byte the session agrees
(0x75 in one run, 0xbc in another). Nothing but the roster and the login server was reached,
and nothing but through the tunnel. The ticket is Steam's real one
(`tests/emulate/steam_session.py`), so the server accepted the account as Steam vouches for it.

**The game lets go about a minute after signing in, on whichever clock.** On the emulated clock
it closed the login connection about 55 s (emulated) after connecting, at frame 6,769. On the
host's clock (`--vpn`, docs/vpn.md, "The clock"), signed in again with the same clicks and the
same exchange, it closed it 63 s (real) after connecting, at frame 5,418: the server's time and
the client's agreed, and the client still let go, from the same code as the roster's close
(`client+0x2fbe830`, on the main thread). So it is the client's own wait of about a minute on
the screen after the account summary, with no click reaching it (a run stops its clicks once
the game reaches a server). Whether the game on a Mac does the same when left on that screen,
and what that screen asks for, is not known here. In another run Steam had logged the
emulator's session off before the sign-in (`LoggedInElsewhere`: the account was in use
elsewhere), and the game closed the login connection 5 frames after sending its ticket.
`--record-network FILE` writes every read and write for study; it holds the ticket, so it stays
under `build/` and is deleted after.
