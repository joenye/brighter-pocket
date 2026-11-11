# The game's protocol, as far as it is known

What the client says to Fen's servers, worked out from the client's own code running in the
emulator (`docs/emulator.md`): which functions run (`--coverage`), what they are given and make
(`--probe`), and the bytes on the wire (`--record-network`). Status: the framing, the handshake,
the obfuscation and the message integrity are understood; the message catalogue and the
integrity hash's algorithm are not. Studied 2026-11-11 on the roster exchange only (no Steam
ticket involved; `--reach roster1.fenresearch.com:15451` keeps a run from going further), and on
the earlier sign-in recordings (`docs/client-analysis.md`, "Signing in, emulated").

## The code

The game is written in a Java-like language compiled to native arm64 (objects with a header,
arrays with their length at +0xc and data at +0x10, Fen's own `fenlib` packages), on Fen's
engine "mahogany", with **libtomcrypt 1.18.2** linked in (AES, RSA; its source paths are in the
client's strings). The executable is stripped; `LC_FUNCTION_STARTS` gives the function bounds.
Addresses below are the 2026-11-09 build's (manifest 2069922974376902512); every build moves them.

|client+|what|
|---|---|
|0x2fbe4ac, 0x2fbe884, 0x2fbe8e0, 0x2fbe810|platform: connect (socket, connect, poll), recv, send, close|
|0x11a3f68 to 0x11a4160|the socket object over them|
|0x6998c, 0x69e28, 0x6a564, 0x69d64|the game's connection: connect, receive, send, close|
|0x2fc4058 (via 0x3c6cb4)|SecureRandom-style `nextBytes(array, offset, count)`, on `SecRandomCopyBytes`|
|0x8c85d0|the handshake's builder|
|0x2fc42a8|RSA encryption of the handshake's secret (libtomcrypt's `rsa_encrypt_key_ex`, 0x30f344c)|
|0x2fc3704|a message's framing and integrity tag (outgoing)|
|0x2fc3bf0|the same for incoming messages|
|0x30e8afc, 0x30e8c50|a keyed 128-bit hash's update and finish (the tag's)|

## The handshake

1. **Server**: 17 bytes, not masked: `02`, then a 16-byte server nonce.
2. **Client**: draws 32, 32 and 81 random bytes. Byte 0 of the 81 is the session's **mask**
   (below). Its secret is 144 bytes: the server's 16-byte nonce, bytes 1 to 64 of the 81, and
   the two 32-byte draws. It is encrypted under the servers' 2048-bit RSA key (bytes 65 to 80 of
   the 81 go in beside it, apparently as the padding's randomness) and sent as 259 bytes: `00`,
   the length 256 as a varint (`80 02`), the 256-byte block.
3. From here both sides keep per-direction 16-byte keys derived from the secret (the client's
   outgoing key sits at +0x24050 of its connection's crypto state, another at +0x24040).

The RSA public key is not in the executable's data as DER; where the client gets it is not yet
traced.

## Messages

On the wire, after the server's hello, every byte both ways is XORed with the session's mask.
That is obfuscation only: the handshake's first plaintext byte is `00`, so the mask is the first
byte the client sends.

Unmasked, a message is: its length as a varint, a **4-byte tag**, then the body: an inner
varint length, two bytes (`f0 28` on the roster request), then the fields. The tag is the first
4 bytes of an HMAC-like construction: a keyed 128-bit hash of the body under the direction's
running key, then of that result under the second key. After each message the running key is
XORed with the result, so the tags chain: a message cannot be dropped, replayed, reordered or
altered without the session's secret, which only the client and the server have. The bodies
themselves are not encrypted.

Fields are big-endian: strings as a u32 length then the bytes, numbers as raw bytes, counts as
single bytes. The roster request, whole:

|bytes|field|
|---|---|
|`01`|(a version or a kind)|
|`00000005` `title`|the request's name|
|`6f8ebfe972374dc3`|the client's **ProtocolHash** (it prints it at start): the server can turn away a client built from other code|
|`03`|(a count)|
|`00000005` `games`, `0000000f` `brighter_shores`, `00000004` `game`|which game|

It carries nothing about the account or the machine. The roster's answer names the login
server to go on to, and carries the texts of the dialog the client shows when something goes
wrong (`Internal error`, `Sorry - please try again later.`, `ROSTER_SERVER_DONE`, `Retry`)
whatever happens. **The ProtocolHash is enforced**: Fen released a build at 15:16 on 2026-11-11
(manifest 1608971154801325014, ProtocolHash `f5e43f25b7acb9fc`), and from then on the roster
sent the 2026-11-09 build no login server (a 15-byte answer, and the client stopped there),
while the new build, with the same emulator and account, went on to sign in at once.

## What this means for detection

- The integrity chain stops a third party from changing or injecting messages; it does not stop
  the client, which holds the keys. It is not anti-cheat, and nothing else in the client is
  (`docs/client-analysis.md`, "Anti-cheat").
- The server learns the client's build (ProtocolHash), the account (the Steam ticket at login),
  the address it connects from, and whatever the game messages carry (timing included: the
  regular 20-byte message carries a client clock).
- The Steam ticket travels inside the masked stream, unencrypted: anyone on the path (only the
  VPN here) could read it.

## Tools

`pocket-emulator --coverage FILE` (functions in the order they first run), `--probe
ADDR[:DUMP,...] --probe-log FILE` (registers and memory at an instruction), `--reach NAME:PORT`
(only those servers), `--record-network FILE` (every read and write). Their files can hold a
session's secrets: keep them under `build/`, and delete recordings of a signed-in session after
study.
