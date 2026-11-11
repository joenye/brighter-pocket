"""A save point for the boot harness: load once, try many times.

`boot.py --threads --serve-from FRAME` runs the client to FRAME (its loading, about nine
minutes, on the emulated clock and offline), then waits there, inside that frame, for tries.
`boot.py --attach [options]` is a try: the server forks, and the fork, which shares the loaded
client with the server until it writes, takes the try's options (its clicks, --frames, --vpn,
--steam-live, --record-network, --stall), writes to the try's own stdout and stderr, and runs on
from FRAME as a run from the start would have. The server stays at FRAME for the next try.
Nothing the server holds is live: no Steam session, no connection, no thread of Python's; a try
opens its own after the fork.
"""
from __future__ import annotations

import contextlib
import json
import os
import signal
import socket
import sys
from pathlib import Path

TRY_OPTIONS = ("frames", "click", "vpn", "steam_live", "record_network", "stall")


def serve(emu, path: Path) -> list[str]:
    """Called inside the client's frame at the save point. Returns only in a try's fork, with
    the try's arguments; the server itself loops here until it is stopped."""
    sys.stdout.flush()
    sys.stderr.flush()
    signal.signal(signal.SIGCHLD, signal.SIG_IGN)   # finished tries leave no zombies
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    path.parent.mkdir(parents=True, exist_ok=True)
    with contextlib.suppress(FileNotFoundError):
        path.unlink()
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(str(path))
    server.listen()
    print(f"save point: frame {emu.frames}; a try: boot.py --attach [--socket {path}] [options]", flush=True)
    while True:
        connection, _ = server.accept()
        message, fds, _, _ = socket.recv_fds(connection, 1 << 20, 2)
        if os.fork() == 0:
            server.close()
            signal.signal(signal.SIGCHLD, signal.SIG_DFL)
            for target, fd in zip((1, 2), fds):
                os.dup2(fd, target)
                os.close(fd)
            emu.try_connection = connection   # held to the fork's exit: the try waits for it to close
            return json.loads(message)
        connection.close()
        for fd in fds:
            os.close(fd)


def attach(path: Path, argv: list[str]) -> int:
    """A try: hand the server the arguments and this process's stdout and stderr, then wait
    until the try's fork has finished."""
    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        connection.connect(str(path))
    except (FileNotFoundError, ConnectionRefusedError):
        raise SystemExit(f"no save point at {path}: start one with boot.py --threads --serve-from FRAME")
    sys.stdout.flush()
    sys.stderr.flush()
    socket.send_fds(connection, [json.dumps(argv).encode()], [1, 2])
    while connection.recv(4096):
        pass
    return 0
