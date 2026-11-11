"""The network for the boot harness: none, or the game's own connections through a VPN.

The layer's network guard (pocket/translation/libSystem.B/NetworkPolicy.c, running as its arm64
build) decides first. It asks the system proxy settings whether a VPN is up; here they name a
tunnel interface only with --vpn. Without it the guard refuses every lookup and connect, as on
a phone with no VPN. With it the guard passes them to the system, answered here: a lookup gets
a stand-in address (198.18.0.0/15) for the name, and a connect to it goes through a SOCKS5 proxy
that leaves through the VPN (Varrock's ProtonVPN tunnel, reached with ssh -L; the proxy resolves
the name inside the tunnel, so DNS goes through it too). Reads, writes, poll and the socket
options the client uses are the host socket's. Nothing leaves this machine but through the proxy.
"""
from __future__ import annotations

import errno as host_errno
import select
import socket
import struct
import time

# Darwin's numbers, as the client and the guard see them.
EINPROGRESS, EAGAIN, ECONNREFUSED, ETIMEDOUT, ENETUNREACH, EBADF = 36, 35, 61, 60, 51, 9
EAI_NONAME, EAI_FAMILY = 8, 5
AF_INET, AF_INET6, AF_UNSPEC = 2, 30, 0
O_NONBLOCK, F_GETFL, F_SETFL = 0x4, 3, 4
SOL_SOCKET, SO_ERROR = 0xFFFF, 0x1007
POLLIN, POLLOUT, POLLERR, POLLHUP = 0x1, 0x4, 0x8, 0x10
STAND_IN_NET = 0xC6120000   # 198.18.0.0/15, for benchmarking: never a real host


class Socks5:
    """A SOCKS5 proxy with a user name and password; names are resolved by the proxy."""

    def __init__(self, host: str, port: int, user: str, password: str):
        self.host, self.port, self.user, self.password = host, port, user, password

    def open(self, name: str, port: int, timeout: float = 30) -> socket.socket:
        s = socket.create_connection((self.host, self.port), timeout=timeout)
        try:
            s.sendall(b"\x05\x01\x02")                          # version 5, one method: user/password
            if s.recv(2) != b"\x05\x02":
                raise OSError("the proxy wants another method")
            user, password = self.user.encode(), self.password.encode()
            s.sendall(b"\x01" + bytes([len(user)]) + user + bytes([len(password)]) + password)
            if s.recv(2) != b"\x01\x00":
                raise OSError("the proxy refused the password")
            host = name.encode()
            s.sendall(b"\x05\x01\x00\x03" + bytes([len(host)]) + host + struct.pack(">H", port))
            reply = s.recv(4)
            if len(reply) < 4 or reply[1] != 0:
                raise ConnectionRefusedError(f"the proxy could not reach {name}:{port} (reply {reply[1:2].hex()})")
            rest = {1: 4, 4: 16}.get(reply[3])
            rest = rest if rest is not None else s.recv(1)[0]
            s.recv(rest + 2)
        except BaseException:
            s.close()
            raise
        s.setblocking(False)
        return s


def register(emu, f, arg, stack, set_errno, Stop):
    emu.network_log = []          # what the game reached, for the report
    names: dict[int, str] = {}    # stand-in address -> name
    sockets: dict[int, dict] = {}
    previous = {name: f[name] for name in ("_read", "_write", "_close", "_fcntl")}

    def log(line: str) -> None:
        line = f"frame {emu.frames}: {line}"
        emu.network_log.append(line)
        emu.console.append(f"[network] {line}\n")

    def record(entry: dict, direction: str, data: bytes) -> None:
        entry[direction] += len(data)
        if emu.network_record:   # --record-network: every read and write, for study (it holds the ticket)
            emu.network_record.write(f"{emu.frames} {entry['peer']} {direction} {data.hex()}\n")

    # --- the guard's VPN check: CFNetworkCopySystemProxySettings and the CF calls it makes ---
    def proxy_settings(e):
        if not emu.vpn:
            return 0
        return emu.dictionary({"__SCOPED__": emu.dictionary({"utun4": emu.dictionary({}), "en0": emu.dictionary({})})})

    f["_CFNetworkCopySystemProxySettings"] = proxy_settings
    DICTIONARY_TYPE, STRING_TYPE = 18, 7
    f["_CFDictionaryGetTypeID"] = lambda e: DICTIONARY_TYPE
    f["_CFStringGetTypeID"] = lambda e: STRING_TYPE
    f["_CFGetTypeID"] = lambda e: DICTIONARY_TYPE if arg(0) in emu.dicts else STRING_TYPE
    f["_CFDictionaryGetValue"] = lambda e: emu.dicts.get(arg(0), {}).get(emu.nsstring(arg(1)), 0)
    f["_CFDictionaryGetCount"] = lambda e: len(emu.dicts.get(arg(0), {}))

    def keys_and_values(e):
        for i, (key, value) in enumerate(emu.dicts.get(arg(0), {}).items()):
            if arg(1):
                emu.write(arg(1) + 8 * i, struct.pack("<Q", emu.new_string(key)))
            if arg(2):
                emu.write(arg(2) + 8 * i, struct.pack("<Q", value))
        return None

    def c_string(e):
        data = emu.nsstring(arg(0)).encode()
        if len(data) + 1 > arg(2):
            return 0
        emu.write(arg(1), data + b"\0")
        return 1

    f["_CFDictionaryGetKeysAndValues"] = keys_and_values
    f["_CFStringGetCString"] = c_string
    f["_CFRelease"] = lambda e: None

    # --- the system's lookups and sockets -------------------------------------------------------
    def getaddrinfo(e):
        node, service, hints, result = emu.cstring(arg(0)), arg(1), arg(2), arg(3)
        if not emu.vpn:   # the guard refused before this; a numeric or loopback name has no game in it
            log(f"lookup of {node}: no network here")
            return EAI_NONAME
        family = struct.unpack("<i", emu.read(hints + 4, 4))[0] if hints else AF_UNSPEC
        if family not in (AF_UNSPEC, AF_INET):
            return EAI_FAMILY
        port = int(emu.cstring(service)) if service and emu.cstring(service).isdigit() else 0
        address = next((a for a, n in names.items() if n == node), None)
        if address is None:
            address = STAND_IN_NET + len(names) + 1
            names[address] = node
        log(f"lookup of {node} (service {emu.cstring(service) if service else '-'}): a stand-in, resolved in the tunnel")
        info, sockaddr = emu.malloc(48), emu.malloc(16)
        emu.write(sockaddr, struct.pack(">BBHI8x", 16, AF_INET, port, address))   # sockaddr_in (sin_len first)
        socktype = struct.unpack("<i", emu.read(hints + 8, 4))[0] if hints else 1
        emu.write(info, struct.pack("<iiiiI4xQQQ", 0, AF_INET, socktype or 1, 6, 16, 0, sockaddr, 0))
        emu.write(result, struct.pack("<Q", info))
        return 0

    def new_socket(e):
        fd = emu.next_fd
        emu.next_fd += 1
        sockets[fd] = {"socket": None, "nonblocking": False, "error": 0, "peer": None,
                       "received": 0, "sent": 0, "ended": None}
        emu.fds[fd] = "socket"
        return fd

    def connect(e):
        entry = sockets.get(arg(0) & 0xFFFFFFFF)
        family, port, address = struct.unpack(">xBHI", emu.read(arg(1), 8))
        name = names.get(address)
        if entry is None or not emu.vpn or family != AF_INET or name is None:
            set_errno(ENETUNREACH)
            return 0xFFFFFFFF
        entry["peer"] = f"{name}:{port}"
        try:
            entry["socket"] = emu.vpn.open(name, port)
            log(f"connected to {name}:{port} through the VPN")
            # Signed in to a real game from here on: no scripted click may land on its screens.
            if emu.events or emu.on_frame:
                emu.events.clear()
                emu.on_frame = None
                log("scripted clicks stopped: the game reached a server")
        except (OSError, socket.timeout) as error:
            entry["error"] = ECONNREFUSED
            log(f"connect to {name}:{port} through the VPN failed: {error}")
            if not entry["nonblocking"]:
                set_errno(ECONNREFUSED)
                return 0xFFFFFFFF
        if entry["nonblocking"]:   # as a non-blocking connect reports: in progress, then poll says done
            set_errno(EINPROGRESS)
            return 0xFFFFFFFF
        return 0

    def getsockopt(e):
        entry = sockets.get(arg(0) & 0xFFFFFFFF)
        if entry is not None and arg(1) & 0xFFFFFFFF == SOL_SOCKET and arg(2) & 0xFFFFFFFF == SO_ERROR:
            emu.write(arg(3), struct.pack("<i", entry["error"]))
            entry["error"] = 0
        return 0

    def ready(entry: dict, events: int) -> int:
        if entry["socket"] is None:
            return POLLERR | POLLHUP if entry["error"] or entry["peer"] else 0
        readable, writable, _ = select.select([entry["socket"]], [entry["socket"]], [], 0)
        return (POLLIN if readable else 0) & events | (POLLOUT if writable else 0) & events

    # A socket's readiness is the host socket's; any other descriptor is ready for what it asks.
    # A wait lasts at most 50 ms of the host's time (the emulated clock moves by it), then the
    # thread gives up its turn, so the others run while the server answers.
    def poll(e):
        fds, count = arg(0), arg(1) & 0xFFFFFFFF
        timeout = struct.unpack("<i", struct.pack("<I", arg(2) & 0xFFFFFFFF))[0]
        start = time.monotonic()
        deadline = start + (min(timeout, 50) / 1000 if timeout >= 0 else 0.05)
        while True:
            ready_count = 0
            for i in range(count):
                fd, events = struct.unpack("<ih", emu.read(fds + 8 * i, 6))
                entry = sockets.get(fd)
                revents = ready(entry, events) if entry else events & (POLLIN | POLLOUT)
                emu.write(fds + 8 * i + 6, struct.pack("<h", revents))
                ready_count += bool(revents)
            if ready_count or time.monotonic() >= deadline:
                break
            time.sleep(0.005)
        emu.clock_ns += int((time.monotonic() - start) * 1e9)
        if not ready_count and emu.scheduler:
            emu.scheduler.yield_turn()
        return ready_count

    def read(e):
        entry = sockets.get(arg(0) & 0xFFFFFFFF)
        if entry is None:
            return previous["_read"](e)
        if entry["socket"] is None:
            set_errno(ENETUNREACH)
            return 2**64 - 1
        deadline = time.monotonic() + (0 if entry["nonblocking"] else 30)
        while True:
            try:
                data = entry["socket"].recv(arg(2))
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    set_errno(EAGAIN)
                    return 2**64 - 1
                select.select([entry["socket"]], [], [], 0.05)
            except OSError as error:
                set_errno(ECONNREFUSED if error.errno == host_errno.ECONNRESET else ETIMEDOUT)
                return 2**64 - 1
        emu.write(arg(1), data)
        emu.network_bytes[0] += len(data)
        record(entry, "received", data)
        if not data and entry["ended"] is None:
            entry["ended"] = emu.frames
        return len(data)

    def write(e):
        entry = sockets.get(arg(0) & 0xFFFFFFFF)
        if entry is None:
            return previous["_write"](e)
        if entry["socket"] is None:
            set_errno(ENETUNREACH)
            return 2**64 - 1
        data = emu.read(arg(1), arg(2))
        entry["socket"].setblocking(True)
        try:
            entry["socket"].sendall(data)
        finally:
            entry["socket"].setblocking(False)
        emu.network_bytes[1] += len(data)
        record(entry, "sent", data)
        return len(data)

    def close(e):
        entry = sockets.pop(arg(0) & 0xFFFFFFFF, None)
        if entry is None:
            return previous["_close"](e)
        if entry["socket"] is not None:
            entry["socket"].close()
            ended = f", the server closed it at frame {entry['ended']}" if entry["ended"] is not None else ""
            log(f"closed {entry['peer']}: {entry['sent']} bytes sent, {entry['received']} received{ended}")
        emu.fds.pop(arg(0) & 0xFFFFFFFF, None)
        return 0

    def fcntl(e):
        entry = sockets.get(arg(0) & 0xFFFFFFFF)
        if entry is None:
            return previous["_fcntl"](e)
        command = arg(1) & 0xFFFFFFFF
        if command == F_GETFL:
            return O_NONBLOCK if entry["nonblocking"] else 0
        if command == F_SETFL:
            entry["nonblocking"] = bool(stack(0) & O_NONBLOCK)
        return 0

    emu.network_bytes = [0, 0]   # received, sent
    f.update({"_getaddrinfo": getaddrinfo, "_socket": new_socket, "_connect": connect, "_getsockopt": getsockopt,
              "_setsockopt": lambda e: 0, "_freeaddrinfo": lambda e: None, "_poll": poll, "_read": read,
              "_write": write, "_close": close, "_fcntl": fcntl})


def probe(emu, host: str, port: int) -> str:
    """Fetch http://HOST:PORT/ as the client would reach a server: the guard's getaddrinfo and
    connect (the adapter's arm64 code), then the system's socket, write and read. Run after the
    initializers, before main; with --vpn the request leaves through the tunnel."""
    guard = emu.adapters["libSystem.B.dylib"].exports
    budget = 50_000_000

    def text(value: str) -> int:
        address = emu.malloc(len(value) + 1)
        emu.write(address, value.encode() + b"\0")
        return address

    result = emu.malloc(8)
    found = emu.call(guard["_getaddrinfo"], text(host), text(str(port)), 0, result, budget=budget) & 0xFFFFFFFF
    if found:
        return f"getaddrinfo({host}) = {found} (refused)"
    sockaddr = emu.u64(emu.u64(result) + 32)
    fd = emu.call(emu.function_slot("_socket"), AF_INET, 1, 0, budget=budget) & 0xFFFFFFFF
    connected = emu.call(guard["_connect"], fd, sockaddr, 16, budget=budget) & 0xFFFFFFFF
    if connected:
        return "connect = -1 (refused)"
    request = f"GET / HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n".encode()
    buffer = emu.malloc(4096)
    emu.write(buffer, request)
    emu.call(emu.function_slot("_write"), fd, buffer, len(request), budget=budget)
    response = b""
    while True:
        n = emu.call(emu.function_slot("_read"), fd, buffer, 4096, budget=budget)
        if n in (0, 2**64 - 1):
            break
        response += emu.read(buffer, n)
    emu.call(emu.function_slot("_close"), fd, budget=budget)
    status = response.split(b"\r\n", 1)[0].decode(errors="replace")
    body = response.split(b"\r\n\r\n", 1)[-1].decode(errors="replace").strip()
    return f"{status}; body: {body[:80]}"
