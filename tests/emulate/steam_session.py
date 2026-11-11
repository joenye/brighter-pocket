"""A real Steam session for the boot harness (--steam-live): the app's session core
(pocket/launcher/Pocket/PocketSteam.c, built for the host as tests/steam_live.py builds it),
signed in with the refresh token DepotDownloader remembers for the account, over the same
SOCKS5 proxy into the VPN as the game's own connections. The bridge the game's Steam library
reaches (hle.py, "PocketSteamBridgeGet") then answers with the account's Steam ID, persona name
and real web API tickets, as the phone's session would. A thread keeps the session alive
(heartbeats, Steam's messages) while the emulated client runs.
"""
from __future__ import annotations

import ctypes
import json
import os
import ssl
import sys
import threading
import time
import zlib
from pathlib import Path

import websocket

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import steam_live  # noqa: E402

APP_ID = 2791440
ONLINE = 3


class LiveSession:
    def __init__(self, vpn, account: str):
        self.lib = steam_live.build_core(steam_live.ROOT / "build/steam-live/libpocketsteam.so")
        self.lock = threading.Lock()
        self.ws = None
        for endpoint in self._endpoints(vpn)[:5]:   # a manager may drop a new connection: try the next
            host, _, port = endpoint.partition(":")
            try:
                raw = vpn.open(host, int(port or 443))
                raw.setblocking(True)
                raw.settimeout(30)
                tls = ssl.create_default_context().wrap_socket(raw, server_hostname=host)
                self.ws = websocket.create_connection(f"wss://{endpoint}/cmsocket/", socket=tls, timeout=30)
                break
            except (OSError, websocket.WebSocketException):
                continue
        if self.ws is None:
            raise SystemExit("no Steam connection manager answered through the VPN")
        lib = self.lib
        send_type = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint8), ctypes.c_size_t)
        random_type = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_size_t)
        gunzip_type = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.POINTER(ctypes.c_uint8), ctypes.c_size_t,
                                       ctypes.POINTER(ctypes.c_uint8), ctypes.c_size_t)
        self._send = send_type(lambda _, data, size: self.ws.send_binary(ctypes.string_at(data, size)))
        self._random = random_type(lambda buffer, size: ctypes.memmove(buffer, os.urandom(size), size))
        self._gunzip = gunzip_type(self._gunzip_into)
        self.session = lib.pocket_steam_create(ctypes.cast(self._send, ctypes.c_void_p), None,
                                               ctypes.cast(self._random, ctypes.c_void_p),
                                               ctypes.cast(self._gunzip, ctypes.c_void_p))
        token = steam_live.saved_refresh_token(account)
        with self.lock:
            lib.pocket_steam_hello(self.session)
            lib.pocket_steam_logon(self.session, account.encode(), token.encode(), b"Brighter Pocket")
        self._pump_until(lambda: self._status() != 2, "the logon")   # 2: logging on
        if self._status() != ONLINE:
            raise SystemExit("Steam refused the logon")
        with self.lock:
            lib.pocket_steam_request_ownership(self.session, APP_ID)
        owned = ctypes.c_int()
        self._pump_until(lambda: lib.pocket_steam_ownership(self.session, APP_ID, ctypes.byref(owned)), "ownership")
        if owned.value != 1:
            raise SystemExit(f"no ownership ticket for {APP_ID} (result {owned.value})")
        with self.lock:
            lib.pocket_steam_games_played(self.session, APP_ID)
        self._pump_until(lambda: lib.pocket_steam_persona_name(self.session) and lib.pocket_steam_connect_tokens(self.session),
                         "account info and tokens")
        self.steam_id = lib.pocket_steam_steam_id(self.session)
        self.persona = lib.pocket_steam_persona_name(self.session).decode("utf-8", "replace")
        self.running = True
        self.thread = threading.Thread(target=self._keep_alive, daemon=True)
        self.thread.start()

    @staticmethod
    def _endpoints(vpn) -> list[str]:
        # Steam's directory, fetched through the proxy as well.
        s = vpn.open("api.steampowered.com", 443)
        s.setblocking(True)
        s.settimeout(30)
        tls = ssl.create_default_context().wrap_socket(s, server_hostname="api.steampowered.com")
        tls.sendall(b"GET /ISteamDirectory/GetCMListForConnect/v1/?cellid=0&cmtype=websockets HTTP/1.1\r\n"
                    b"Host: api.steampowered.com\r\nConnection: close\r\n\r\n")
        response = b""
        while chunk := tls.recv(65536):
            response += chunk
        tls.close()
        body = response.split(b"\r\n\r\n", 1)[1]
        if b"\r\n" in body[:8]:   # chunked
            out, rest = b"", body
            while rest:
                size_text, _, rest = rest.partition(b"\r\n")
                size = int(size_text, 16)
                if not size:
                    break
                out, rest = out + rest[:size], rest[size + 2:]
            body = out
        servers = [s["endpoint"] for s in json.loads(body)["response"]["serverlist"]
                   if s["endpoint"].split(":")[0].endswith(".steamserver.net")]
        if not servers:
            raise SystemExit("Steam's directory named no connection manager")
        return servers

    @staticmethod
    def _gunzip_into(data, size, output, output_size):
        try:
            plain = zlib.decompress(ctypes.string_at(data, size), 16 + 15)
        except zlib.error:
            return -1
        if len(plain) != output_size:
            return -1
        ctypes.memmove(output, plain, output_size)
        return 0

    def _status(self) -> int:
        with self.lock:
            return self.lib.pocket_steam_status(self.session, None)

    def _receive_one(self, timeout: float) -> None:
        self.ws.settimeout(timeout)
        try:
            opcode, frame = self.ws.recv_data()
        except websocket.WebSocketTimeoutException:
            return
        if opcode != websocket.ABNF.OPCODE_BINARY or not frame:
            return   # pings, pongs and the like: Steam's messages are binary frames
        data = (ctypes.c_uint8 * len(frame)).from_buffer_copy(frame)
        with self.lock:
            if self.lib.pocket_steam_receive(self.session, data, len(frame)) != 0:
                raise SystemExit("a frame from Steam could not be read")

    def _pump_until(self, done, what: str, seconds: float = 30) -> None:
        deadline = time.monotonic() + seconds
        while not done():
            if time.monotonic() > deadline:
                raise SystemExit(f"timed out waiting for {what}")
            self._receive_one(1)

    def _keep_alive(self) -> None:
        beat = time.monotonic()
        while self.running:
            try:
                self._receive_one(1)
                if time.monotonic() - beat > 9:
                    with self.lock:
                        self.lib.pocket_steam_heartbeat(self.session)
                    beat = time.monotonic()
            except (OSError, websocket.WebSocketException):
                return

    def web_ticket(self, identity: str) -> tuple[bytes, int] | None:
        ticket = (ctypes.c_uint8 * 2560)()
        crc = ctypes.c_uint32()
        with self.lock:
            made = self.lib.pocket_steam_web_ticket(self.session, APP_ID, identity.encode(), ticket, ctypes.byref(crc))
        return (bytes(ticket), crc.value) if made == 0 else None

    def close(self) -> None:
        self.running = False
        with self.lock:
            self.lib.pocket_steam_games_played(self.session, 0)
            self.lib.pocket_steam_logoff(self.session)
        time.sleep(0.5)
        self.ws.close()


def open_session(vpn, account: str) -> LiveSession:
    if vpn is None:
        raise SystemExit("--steam-live goes through the VPN: add --vpn")
    return LiveSession(vpn, account)
