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
|libSystem|125|iOS; `connect` and `getaddrinfo` through the offline guard (`pocket/translation/libSystem.B`)|
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
would end the game at once. So the offline library must initialise. What the client then asks:

- interfaces `SteamUser023`, `SteamFriends017`, `SteamUtils010` and
  `STEAMAPPS_INTERFACE_VERSION008`, through `SteamInternal_ContextInit` accessors;
- `GetPersonaName`, `GetSteamID`, `IsOverlayEnabled`, `MarkContentCorrupt`;
- `GetAuthTicketForWebApi`, with callback 168 (`GetTicketForWebApiResponse_t`) registered for
  the ticket, and callback 152 (`MicroTxnAuthorizationResponse_t`, in-game purchases).

The web API ticket is how a session is authenticated, which is why offline means no sign-in.
The offline library answers as Steam does when running but offline: initialised, not logged on,
`k_steamIDNil`, and a ticket result of "no connection" (`tests/steam_test.cpp`).

## Network

`socket`, `getaddrinfo`, `connect`, `poll`, `getsockopt`, `setsockopt`, and nothing else: no
URL loading, CFNetwork or Network framework. One lookup and one connect path; the server name
is not in the executable's strings (it arrives from game data at run time). The offline guard
refuses every host name and every non-loopback address (`tests/network_test.c`), and logs what
was attempted.

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

It starts 35 threads. Run one after another (`boot.py --threads`), every one of them goes
straight to waiting on a condition variable: one waits on its own, the other 34 are a pool
waiting for work. None of them reads a file or touches the network at startup.

Memory: by the third frame the main thread has allocated about 275 MB (an upper bound: the
emulator never frees) and reserved nothing large with `mmap`, well within an iPad's or a recent
iPhone's limit even without the increased-memory entitlement a free Apple ID cannot grant.

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
