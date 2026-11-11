"""A real Steam session for the boot harness (--steam-live): the app's session core
(pocket/launcher/Pocket/PocketSteam.c, built for the host as tests/steam_live.py builds it),
signed in with the refresh token DepotDownloader remembers for the account, over the same
SOCKS5 proxy into the VPN as the game's own connections. The bridge the game's Steam library
reaches (hle.py, "PocketSteamBridgeGet") then answers with the account's Steam ID, persona name
and real web API tickets, as the phone's session would.

A thread keeps the session alive while the emulated client runs: it reads Steam's messages as
they come (a whole websocket frame at a time, once the socket is readable) and sends a heartbeat
at the interval Steam asked for. Should the connection drop, it signs in again, once, and says
so; should Steam log the session off (the account signed in elsewhere: Joe's own Steam, say), it
stops there, and the bridge has no ticket to give: the account is never taken back.
"""
from __future__ import annotations

import ctypes
import json
import os
import select
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
LOGGING_ON, ONLINE, LOGGED_OFF = 2, 3, 5   # PocketSteamStatus
LOGGED_IN_ELSEWHERE = 6                   # EResult


class LiveSession:
    def __init__(self, vpn, account: str, log):
        self.vpn, self.account, self.log = vpn, account, log
        self.lib = steam_live.build_core(steam_live.ROOT / "build/steam-live/libpocketsteam.so")
        self.lock = threading.Lock()        # the session core
        self.send_lock = threading.Lock()   # the socket's writes
        self.connected = threading.Event()
        self.ws = None
        self.session = None
        self.ended: str | None = None       # why the session ended for good
        send_type = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint8), ctypes.c_size_t)
        random_type = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_size_t)
        gunzip_type = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.POINTER(ctypes.c_uint8), ctypes.c_size_t,
                                       ctypes.POINTER(ctypes.c_uint8), ctypes.c_size_t)
        self._send = send_type(self._send_frame)
        self._random = random_type(lambda buffer, size: ctypes.memmove(buffer, os.urandom(size), size))
        self._gunzip = gunzip_type(self._gunzip_into)
        self._connect()
        self.running = True
        self.thread = threading.Thread(target=self._keep_alive, daemon=True)
        self.thread.start()

    # --- connecting and signing in ------------------------------------------------------------
    def _connect(self) -> None:
        if self.ws is not None:
            self.ws.close()
        self.ws = None
        for endpoint in self._endpoints(self.vpn)[:5]:   # a manager may drop a new connection: try the next
            host, _, port = endpoint.partition(":")
            try:
                raw = self.vpn.open(host, int(port or 443))
                raw.setblocking(True)
                raw.settimeout(30)
                tls = ssl.create_default_context().wrap_socket(raw, server_hostname=host)
                self.ws = websocket.create_connection(f"wss://{endpoint}/cmsocket/", socket=tls, timeout=30)
                break
            except (OSError, websocket.WebSocketException):
                continue
        if self.ws is None:
            raise ConnectionError("no Steam connection manager answered through the VPN")
        lib = self.lib
        with self.lock:
            if self.session:
                lib.pocket_steam_destroy(self.session)
            self.session = lib.pocket_steam_create(ctypes.cast(self._send, ctypes.c_void_p), None,
                                                   ctypes.cast(self._random, ctypes.c_void_p),
                                                   ctypes.cast(self._gunzip, ctypes.c_void_p))
            lib.pocket_steam_hello(self.session)
            lib.pocket_steam_logon(self.session, self.account.encode(),
                                   steam_live.saved_refresh_token(self.account).encode(), b"Brighter Pocket")
        self._pump_until(lambda: self._status() != LOGGING_ON, "the logon")
        if self._status() != ONLINE:
            raise ConnectionError("Steam refused the logon")
        with self.lock:
            lib.pocket_steam_request_ownership(self.session, APP_ID)
        owned = ctypes.c_int()
        self._pump_until(lambda: self._locked(lib.pocket_steam_ownership, APP_ID, ctypes.byref(owned)), "ownership")
        if owned.value != 1:
            raise ConnectionError(f"no ownership ticket for {APP_ID} (result {owned.value})")
        with self.lock:
            lib.pocket_steam_games_played(self.session, APP_ID)
        self._pump_until(lambda: self._locked(lib.pocket_steam_persona_name) and self._locked(lib.pocket_steam_connect_tokens),
                         "account info and tokens")
        with self.lock:
            self.steam_id = lib.pocket_steam_steam_id(self.session)
            self.persona = lib.pocket_steam_persona_name(self.session).decode("utf-8", "replace")
            self.heartbeat = lib.pocket_steam_heartbeat_seconds(self.session) or 9
        self.connected.set()

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
            raise ConnectionError("Steam's directory named no connection manager")
        return servers

    # --- the core's callbacks -----------------------------------------------------------------
    def _send_frame(self, _, data, size) -> None:
        # Called by the core under self.lock. An error here cannot cross back into C: the next
        # read finds the connection gone.
        try:
            with self.send_lock:
                self.ws.send_binary(ctypes.string_at(data, size))
        except (OSError, websocket.WebSocketException):
            pass

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

    # --- reading Steam's messages -------------------------------------------------------------
    def _locked(self, function, *args):
        with self.lock:
            return function(self.session, *args)

    def _status(self) -> int:
        return self._locked(self.lib.pocket_steam_status, None)

    def _receive_ready(self, timeout: float) -> None:
        """Hand the core one message from Steam if one arrives within timeout. The frame is read
        whole once the socket is readable, so a timeout never cuts one in two."""
        sock = self.ws.sock
        if not (isinstance(sock, ssl.SSLSocket) and sock.pending()):
            if not select.select([sock], [], [], timeout)[0]:
                return
        opcode, frame = self.ws.recv_data()
        if opcode == websocket.ABNF.OPCODE_CLOSE:
            raise ConnectionError("Steam closed the connection")
        if opcode != websocket.ABNF.OPCODE_BINARY or not frame:
            return   # pings and pongs: Steam's messages are binary frames
        data = (ctypes.c_uint8 * len(frame)).from_buffer_copy(frame)
        with self.lock:
            if self.lib.pocket_steam_receive(self.session, data, len(frame)) != 0:
                raise ConnectionError("a message from Steam could not be read")

    def _pump_until(self, done, what: str, seconds: float = 30) -> None:
        deadline = time.monotonic() + seconds
        while not done():
            if time.monotonic() > deadline:
                raise ConnectionError(f"timed out waiting for {what}")
            if reason := self._logged_off():
                raise ConnectionError(reason)
            self._receive_ready(1)

    def _logged_off(self) -> str | None:
        """Why Steam ended the session, if it did: that is Steam's decision, never fought."""
        result = ctypes.c_int()
        with self.lock:
            status = self.lib.pocket_steam_status(self.session, ctypes.byref(result))
        if status != LOGGED_OFF:
            return None
        return f"Steam logged the session off: EResult {result.value}" + (
            " (LoggedInElsewhere: the account signed in elsewhere)" if result.value == LOGGED_IN_ELSEWHERE else "")

    def _keep_alive(self) -> None:
        beat = time.monotonic()
        while self.running:
            try:
                self._receive_ready(1)
                if time.monotonic() - beat >= self.heartbeat:
                    with self.lock:
                        self.lib.pocket_steam_heartbeat(self.session)
                    beat = time.monotonic()
                if self._status() != ONLINE:
                    raise ConnectionError("the session is no longer online")
            except (OSError, websocket.WebSocketException, ConnectionError) as error:
                if not self.running:
                    return
                self.connected.clear()
                # Steam ending the session (another sign-in to the account, above all) is final:
                # signing in again would take the account back from wherever it is in use.
                if reason := self._logged_off():
                    self.ended = reason
                    self.log(f"{reason}; not signing in again")
                    return
                self.log(f"the connection to Steam was lost ({error}); signing in again")
                try:
                    time.sleep(2)
                    self._connect()
                    self.log("signed in to Steam again")
                except (OSError, websocket.WebSocketException, ConnectionError) as again:
                    self.ended = f"signing in again failed ({again})"
                    self.log(self.ended)
                    return
                beat = time.monotonic()

    # --- what the bridge asks -----------------------------------------------------------------
    def web_ticket(self, identity: str) -> tuple[bytes, int] | None:
        if self.ended or not self.connected.wait(60):
            self.log(f"no Steam session for a ticket for {identity!r}")
            return None
        ticket = (ctypes.c_uint8 * 2560)()
        crc = ctypes.c_uint32()
        with self.lock:
            made = self.lib.pocket_steam_web_ticket(self.session, APP_ID, identity.encode(), ticket, ctypes.byref(crc))
        return (bytes(ticket), crc.value) if made == 0 else None

    def close(self) -> None:
        self.running = False
        self.thread.join(5)
        if self.connected.is_set():
            with self.lock:
                self.lib.pocket_steam_games_played(self.session, 0)
                self.lib.pocket_steam_logoff(self.session)
            time.sleep(0.5)
        self.ws.close()


def open_session(vpn, account: str, log) -> LiveSession:
    if vpn is None:
        raise SystemExit("--steam-live goes through the VPN: add --vpn")
    try:
        return LiveSession(vpn, account, log)
    except ConnectionError as error:
        raise SystemExit(f"--steam-live: {error}")
