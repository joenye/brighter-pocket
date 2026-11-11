# The game's servers, through a VPN only

Joe's decision of 2026-11-11: the game may reach its servers, but only through a VPN.

## On the phone

The network guard (`pocket/translation/libSystem.B/NetworkPolicy.c`) stands in front of the
game's own `getaddrinfo` and `connect`. It asks the system proxy settings whether a VPN is up:
a VPN app's tunnel appears there as a scoped interface (`utun`, `ipsec`, `ppp`, `tap`, `tun`).

- **VPN up** (the ProtonVPN app connected): lookups and connections are the system's, so they
  leave through the tunnel. The log names each once: `[network] lookup of ... through the VPN`.
- **No VPN**: every lookup of a name fails (`EAI_NONAME`) and every connection off the device
  (`ENETUNREACH`), before any query or packet, as before; the log says `refused: no VPN`.

The app's own Steam sign-in (`pocket/launcher/Pocket`) is not behind the guard: it signs in to
Steam with or without the VPN. With the VPN up, it too leaves through the tunnel, as all of the
phone's traffic does. Whether iOS lists every VPN app's tunnel in those settings is not checked
on a device yet.

## Testing on the PC

The emulator (`emulator/`, docs/emulator.md) can send the game's connections out the same way. The
VPN is Varrock's ProtonVPN tunnel (the `wireguard` container, config `wg-UK-352`), shared rather
than copied: a WireGuard key can be connected from one place at a time, and the tunnel carries
qBittorrent and its forwarded port. On Varrock, `game-socks` (in `~/varrock/dco/compose.yaml`,
added 2026-11-11 with Joe's go-ahead) is a SOCKS5 proxy in the `wireguard` container's network:
everything it carries leaves through the tunnel, names are resolved by the tunnel's DNS, it has
no published port, it only accepts the Docker bridge gateway (`ALLOWED_IPS`), and it needs the
password in Varrock's `.env` (`GAME_SOCKS_USER`, `GAME_SOCKS_PASSWORD`; the same two lines are in
this repository's ignored `local.env`).

```bash
# The tunnel to it (keep it running); 172.30.10.25 is the wireguard container's address:
ssh -N -L 127.0.0.1:1080:$(ssh varrock docker inspect wireguard --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'):1080 varrock
curl --socks5-hostname 127.0.0.1:1080 -U "$GAME_SOCKS_USER:$GAME_SOCKS_PASSWORD" https://api.ipify.org   # a Proton address

# The guard and the network path, without the game: through the VPN, then without it.
emulator/target/release/pocket-emulator --vpn --probe-network api.ipify.org
emulator/target/release/pocket-emulator --probe-network api.ipify.org     # refused: no VPN

# The game with the network up, and the real account and tickets from a live Steam session
# (STEAM_USER's login as DepotDownloader remembers it), Steam reached through the VPN too. It
# reaches its menu at about frame 1,300 (30 s); the sign-in is the 34th of the clicks in
# docs/client-analysis.md, "Signing in, emulated":
emulator/target/release/pocket-emulator --vpn --steam-live --frames N [--click X,Y@FRAME ...]
```

`--vpn` makes the system proxy settings name a tunnel, so the guard (its arm64 build) lets the
game through; the system's lookup answers with a stand-in address (198.18.0.0/15) for the name,
and a connect to it goes to the proxy with the name, so DNS too is resolved inside the tunnel.
Scripted clicks stop the moment the game reaches a server, so none lands on a signed-in screen.

**The clock** is the host's, as on a device: the client's time agrees with its servers', and
the display's vertical sync paces its frames at 60 a second at most.

**The Steam session** (`--steam-live`) reads Steam's messages whole and sends its heartbeats at
Steam's interval. If the connection drops it signs in once more. If Steam logs it off, above
all with `LoggedInElsewhere` (EResult 6: the account is signed in elsewhere, Joe's own Steam
playing, say), it stops: signing in again would take the account away from there. Run it only
while the account is not in use.
