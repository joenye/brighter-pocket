#!/usr/bin/env python3
"""Run the app's Steam session core (pocket/launcher/Pocket/PocketSteam.c) against Steam itself.

usage: tests/steam_live.py [--account NAME] [--identity TEXT] [--keep-playing]

By hand only: it signs in to a real Steam account and talks to Steam's connection managers
(never to the game's servers). It builds the C core as a host library, connects to a CM over
a WebSocket, and checks each step the phone will take: a service call before logon
(Authentication.GetPasswordRSAPublicKey), logon with a refresh token, the persona name, game
connect tokens, Brighter Shores' ownership ticket, "playing" the game, and a web API ticket
registered with Steam and acknowledged, then cancelled. The refresh token is the one
DepotDownloader remembers for the account (its IsolatedStorage account.config); it is never
printed. While it runs, the account shows as in game in Brighter Shores, and a game session
the account has elsewhere ends.
"""
from __future__ import annotations

import argparse
import ctypes
import glob
import json
import os
import subprocess
import sys
import time
import urllib.request
import zlib
from pathlib import Path

import websocket  # pip install websocket-client

ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / "pocket/launcher/Pocket/PocketSteam.c"
APP_ID = 2791440
ONLINE, REFUSED, LOGGED_OFF = 3, 4, 5
TICKET_SIZE = 2560


def saved_refresh_token(account: str) -> str:
    """DepotDownloader's remembered login: account.config is deflated protobuf-net, its field 4
    the LoginTokens map (account name -> refresh token)."""
    def varint(data: bytes, i: int) -> tuple[int, int]:
        value, shift = 0, 0
        while True:
            byte = data[i]
            i += 1
            value |= (byte & 127) << shift
            shift += 7
            if byte < 128:
                return value, i

    def fields(data: bytes):
        i = 0
        while i < len(data):
            key, i = varint(data, i)
            if key & 7 == 2:
                size, i = varint(data, i)
                yield key >> 3, data[i:i + size]
                i += size
            elif key & 7 == 0:
                _, i = varint(data, i)
            else:
                return
    newest = None
    for path in glob.glob(os.path.expanduser("~/.local/share/IsolatedStorage/*/*/*/AssemFiles/account.config")):
        for number, entry in fields(zlib.decompress(Path(path).read_bytes(), -15)):
            if number == 4:
                pair = dict(fields(entry))
                if pair.get(1, b"").decode() == account and pair.get(2):
                    if newest is None or os.path.getmtime(path) > newest[0]:
                        newest = (os.path.getmtime(path), pair[2].decode())
    if not newest:
        raise SystemExit(f"DepotDownloader remembers no login for {account}")
    return newest[1]


def build_core(out: Path) -> ctypes.CDLL:
    out.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["cc", "-std=c11", "-O1", "-g", "-fPIC", "-shared", "-Wall", "-Wextra", "-Werror",
                    str(CORE), "-o", str(out)], check=True)
    lib = ctypes.CDLL(str(out))
    P, u8p, sz = ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint8), ctypes.c_size_t
    lib.pocket_steam_create.restype = P
    lib.pocket_steam_create.argtypes = [P, P, P, P]
    for name, args in {"pocket_steam_hello": [P], "pocket_steam_logon": [P, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p],
                       "pocket_steam_logoff": [P], "pocket_steam_heartbeat": [P], "pocket_steam_destroy": [P],
                       "pocket_steam_request_ownership": [P, ctypes.c_uint32],
                       "pocket_steam_games_played": [P, ctypes.c_uint32],
                       "pocket_steam_cancel_ticket": [P, ctypes.c_uint32]}.items():
        getattr(lib, name).argtypes = args
        getattr(lib, name).restype = None
    lib.pocket_steam_receive.argtypes = [P, u8p, sz]
    lib.pocket_steam_status.argtypes = [P, ctypes.POINTER(ctypes.c_int)]
    lib.pocket_steam_steam_id.argtypes = [P]
    lib.pocket_steam_steam_id.restype = ctypes.c_uint64
    lib.pocket_steam_persona_name.argtypes = [P]
    lib.pocket_steam_persona_name.restype = ctypes.c_char_p
    lib.pocket_steam_connect_tokens.argtypes = [P]
    lib.pocket_steam_connect_tokens.restype = sz
    lib.pocket_steam_heartbeat_seconds.argtypes = [P]
    lib.pocket_steam_call.argtypes = [P, ctypes.c_char_p, u8p, sz]
    lib.pocket_steam_call.restype = ctypes.c_uint64
    lib.pocket_steam_reply.argtypes = [P, ctypes.c_uint64, ctypes.POINTER(ctypes.c_int), ctypes.POINTER(u8p),
                                       ctypes.POINTER(sz)]
    lib.pocket_steam_ownership.argtypes = [P, ctypes.c_uint32, ctypes.POINTER(ctypes.c_int)]
    lib.pocket_steam_web_ticket.argtypes = [P, ctypes.c_uint32, ctypes.c_char_p, u8p, ctypes.POINTER(ctypes.c_uint32)]
    lib.pocket_steam_ticket_acknowledged.argtypes = [P, ctypes.c_uint32]
    return lib


class Live:
    def __init__(self, lib: ctypes.CDLL):
        self.lib = lib
        endpoint = json.load(urllib.request.urlopen(
            "https://api.steampowered.com/ISteamDirectory/GetCMListForConnect/v1/?cellid=0&cmtype=websockets",
            timeout=30))["response"]["serverlist"][0]["endpoint"]
        if not endpoint.split(":")[0].endswith(".steamserver.net"):
            raise SystemExit(f"unexpected connection manager {endpoint}")
        print(f"connection manager: {endpoint}")
        self.ws = websocket.create_connection(f"wss://{endpoint}/cmsocket/", timeout=30)
        send_type = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint8), ctypes.c_size_t)
        random_type = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_size_t)
        gunzip_type = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.POINTER(ctypes.c_uint8), ctypes.c_size_t,
                                       ctypes.POINTER(ctypes.c_uint8), ctypes.c_size_t)

        def gunzip(data, size, output, output_size):
            try:
                plain = zlib.decompress(ctypes.string_at(data, size), 16 + 15)
            except zlib.error:
                return -1
            if len(plain) != output_size:
                return -1
            ctypes.memmove(output, plain, output_size)
            return 0

        self._send = send_type(lambda _, data, size: self.ws.send_binary(ctypes.string_at(data, size)))
        self._random = random_type(lambda buffer, size: ctypes.memmove(buffer, os.urandom(size), size))
        self._gunzip = gunzip_type(gunzip)
        self.session = lib.pocket_steam_create(ctypes.cast(self._send, ctypes.c_void_p), None,
                                               ctypes.cast(self._random, ctypes.c_void_p),
                                               ctypes.cast(self._gunzip, ctypes.c_void_p))

    def pump(self, until, seconds: float = 30, what: str = ""):
        deadline = time.monotonic() + seconds
        while not until():
            left = deadline - time.monotonic()
            if left <= 0:
                raise SystemExit(f"timed out waiting for {what}")
            self.ws.settimeout(left)
            frame = self.ws.recv()
            data = (ctypes.c_uint8 * len(frame)).from_buffer_copy(frame)
            if self.lib.pocket_steam_receive(self.session, data, len(frame)) != 0:
                raise SystemExit("a frame from Steam could not be read")

    def status(self) -> tuple[int, int]:
        result = ctypes.c_int()
        return self.lib.pocket_steam_status(self.session, ctypes.byref(result)), result.value


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--account", default="joenye")
    parser.add_argument("--identity", default="brighter-pocket-live-check",
                        help="the identity the ticket names (the game's own is seen on the device)")
    args = parser.parse_args()
    token = saved_refresh_token(args.account)
    lib = build_core(ROOT / "build/steam-live/libpocketsteam.so")
    live = Live(lib)
    s = live.session

    lib.pocket_steam_hello(s)
    # A service call with no account yet: the sign-in screen's first step on the phone.
    request = bytes([0x0a, len(args.account)]) + args.account.encode()
    body = (ctypes.c_uint8 * len(request)).from_buffer_copy(request)
    job = lib.pocket_steam_call(s, b"Authentication.GetPasswordRSAPublicKey#1", body, len(request))
    result, reply, size = ctypes.c_int(), ctypes.POINTER(ctypes.c_uint8)(), ctypes.c_size_t()
    live.pump(lambda: lib.pocket_steam_reply(s, job, ctypes.byref(result), ctypes.byref(reply), ctypes.byref(size)),
              what="Authentication.GetPasswordRSAPublicKey")
    modulus = ctypes.string_at(reply, size.value)
    print(f"service call without an account: result {result.value}, {size.value}-byte reply "
          f"(RSA modulus field present: {modulus[:1] == bytes([0x0a])})")
    if result.value != 1:
        return 1

    lib.pocket_steam_logon(s, args.account.encode(), token.encode(), b"Brighter Pocket")
    live.pump(lambda: live.status()[0] in (ONLINE, REFUSED, LOGGED_OFF), what="the logon response")
    status, result_code = live.status()
    print(f"logon: {'online' if status == ONLINE else 'refused'} (result {result_code}), "
          f"heartbeat every {lib.pocket_steam_heartbeat_seconds(s)} s")
    if status != ONLINE:
        return 1
    print(f"steam ID: {lib.pocket_steam_steam_id(s)}")
    live.pump(lambda: lib.pocket_steam_persona_name(s) and lib.pocket_steam_connect_tokens(s), what="account info and tokens")
    print(f"persona name received ({len(lib.pocket_steam_persona_name(s))} characters); "
          f"game connect tokens: {lib.pocket_steam_connect_tokens(s)}")

    lib.pocket_steam_request_ownership(s, APP_ID)
    owned = ctypes.c_int()
    live.pump(lambda: lib.pocket_steam_ownership(s, APP_ID, ctypes.byref(owned)), what="the ownership ticket")
    print(f"ownership ticket for {APP_ID}: result {owned.value}")
    if owned.value != 1:
        return 1

    lib.pocket_steam_games_played(s, APP_ID)
    ticket = (ctypes.c_uint8 * TICKET_SIZE)()
    crc = ctypes.c_uint32()
    if lib.pocket_steam_web_ticket(s, APP_ID, args.identity.encode(), ticket, ctypes.byref(crc)) != 0:
        print("no web API ticket: a token or the ownership ticket is missing")
        return 1
    print(f"web API ticket built ({TICKET_SIZE} bytes, session part CRC {crc.value:08x}); waiting for Steam's ack")
    try:
        live.pump(lambda: lib.pocket_steam_ticket_acknowledged(s, crc.value), seconds=15, what="the ticket ack")
        print("Steam acknowledged the ticket")
    except SystemExit as error:
        print(f"no ack: {error} (SteamKit2 notes Steam no longer always acks; the ticket may still be valid)")

    lib.pocket_steam_cancel_ticket(s, crc.value)
    lib.pocket_steam_games_played(s, 0)
    lib.pocket_steam_logoff(s)
    time.sleep(1)
    live.ws.close()
    lib.pocket_steam_destroy(s)
    print("cancelled the ticket, stopped playing, logged off")
    return 0


if __name__ == "__main__":
    sys.exit(main())
