"""What the boot harness answers for the client's and the adapter's imports.

Each answer reads its arguments from the emulator's registers (the Apple arm64 calling
convention: integer arguments in x0 to x7, floating point in v0 to v7, variadic arguments
on the stack in 8-byte slots) and returns the value for x0, or None to leave x0 alone.
Only what startup needs is modelled; anything else stops the run with its name, so the
model grows only where the client really goes.
"""
from __future__ import annotations

import math
import os
import stat as stat_module
import struct
import time
from types import SimpleNamespace

from unicorn.arm64_const import UC_ARM64_REG_D0, UC_ARM64_REG_D1, UC_ARM64_REG_S0, UC_ARM64_REG_S1, UC_ARM64_REG_SP

ENOENT, EBADF, EACCES, ENOSYS, ENETUNREACH = 2, 9, 13, 78, 51
EAI_NONAME = 8


def answers(emu):
    BootStop = emu.Stop   # the harness's own, so its handler sees it
    f: dict = {}
    d: dict = {}
    errno_slot = emu.malloc(16)
    files = SimpleNamespace(stdout=emu.malloc(256), stderr=emu.malloc(256))

    def arg(n):
        return emu.reg(n)

    def stack(i):
        return emu.u64(emu.uc.reg_read(UC_ARM64_REG_SP) + 8 * i)

    def set_errno(value):
        emu.write(errno_slot, struct.pack("<i", value))
        return value

    def fn(*names):
        def register(body):
            for name in names:
                f[name] = body
            return body
        return register

    # --- process -------------------------------------------------------------------------
    @fn("_exit", "__exit")
    def _exit(e):
        raise BootStop(f"exit({arg(0) & 0xFFFFFFFF})")

    @fn("_abort", "___stack_chk_fail")
    def _abort(e):
        raise BootStop("abort")

    @fn("___cxa_atexit")
    def _atexit(e):
        emu.atexit.append((arg(0), arg(1)))
        return 0

    @fn("___chkstk_darwin")
    def _chkstk(e):
        return None   # a stack probe; the emulated stack is mapped whole

    @fn("___error")
    def _error(e):
        return errno_slot

    container_home = "/var/mobile/Containers/Data/Application/POCKET"

    @fn("_getenv")
    def _getenv(e):
        # An iOS app's HOME is its container; nothing else is set for the client.
        if emu.cstring(arg(0)) == "HOME":
            value = emu.malloc(len(container_home) + 1)
            emu.write(value, container_home.encode() + b"\0")
            return value
        return 0

    @fn("_getpid")
    def _getpid(e):
        return 4242

    @fn("_geteuid")
    def _geteuid(e):
        return 501

    @fn("_sysctlbyname")
    def _sysctlbyname(e):
        name, out, size = emu.cstring(arg(0)), arg(1), arg(2)
        values = {"hw.ncpu": 8, "hw.physicalcpu": 8, "hw.logicalcpu": 8, "hw.memsize": 8 << 30}
        if name not in values:
            set_errno(ENOENT)
            return 0xFFFFFFFF
        length = emu.u64(size) if size else 8
        if out:
            emu.write(out, values[name].to_bytes(8, "little")[:length])
        return 0

    @fn("_sysconf")
    def _sysconf(e):
        return {29: 16384, 58: 8, 57: 8}.get(arg(0) & 0xFFFFFFFF, 0)

    @fn("_confstr")
    def _confstr(e):
        value = b"/private/var/mobile/tmp/\0"
        if arg(1) and arg(2):
            emu.write(arg(1), value[:arg(2)])
        return len(value)

    @fn("_gethostuuid")
    def _gethostuuid(e):
        emu.write(arg(0), bytes(16))
        return 0

    @fn("_srandomdev")
    def _srandomdev(e):
        return None

    @fn("_random")
    def _random(e):
        return 12345

    @fn("_atoi")
    def _atoi(e):
        try:
            return int(emu.cstring(arg(0)).strip().split()[0]) & 0xFFFFFFFF
        except (ValueError, IndexError):
            return 0

    # The client's own dlopen and dlsym are the loader's on the device (they find nothing it
    # does not carry); an adapter's are the system's, which find the system's functions.
    def from_adapter():
        lr = emu.reg(30)
        return any(a.slide <= lr < a.slide + 0x1000_0000 for a in emu.adapters.values())

    @fn("_dlopen")
    def _dlopen(e):
        return emu.malloc(16) if from_adapter() else 0

    @fn("_dlsym")
    def _dlsym(e):
        return emu.function_slot("_" + emu.cstring(arg(1))) if from_adapter() else 0

    @fn("_strcasecmp")
    def _strcasecmp(e):
        return compare(raw_cstring(arg(0)).lower(), raw_cstring(arg(1)).lower())

    @fn("_snprintf")
    def _snprintf(e):
        data = format_string(raw_cstring(arg(2)), stack_slots(emu.uc.reg_read(UC_ARM64_REG_SP)))
        if arg(1):
            emu.write(arg(0), data[:arg(1) - 1] + b"\0")
        return len(data)

    @fn("_inet_pton")
    def _inet_pton(e):
        import ipaddress
        try:
            address = ipaddress.ip_address(emu.cstring(arg(1)))
        except ValueError:
            return 0
        if (address.version == 4) != ((arg(0) & 0xFFFFFFFF) == 2):
            return 0
        emu.write(arg(2), address.packed)
        return 1

    @fn("_inet_ntop")
    def _inet_ntop(e):
        import ipaddress
        family, size = arg(0) & 0xFFFFFFFF, arg(3)
        raw = emu.read(arg(1), 4 if family == 2 else 16)
        text = str(ipaddress.ip_address(raw)).encode() + b"\0"
        emu.write(arg(2), text[:size])
        return arg(2)

    @fn("_dlclose")
    def _dlclose(e):
        return 0

    @fn("_dlerror")
    def _dlerror(e):
        return 0

    # --- time ------------------------------------------------------------------------------
    @fn("_time")
    def _time(e):
        now = int(time.time())
        if arg(0):
            emu.write(arg(0), struct.pack("<q", now))
        return now

    @fn("_gettimeofday")
    def _gettimeofday(e):
        now = time.time()
        if arg(0):
            emu.write(arg(0), struct.pack("<qi4x", int(now), int((now % 1) * 1e6)))
        return 0

    @fn("_nanosleep")
    def _nanosleep(e):
        block_if_thread("nanosleep")
        return 0

    @fn("_localtime")
    def _localtime(e):
        t = time.localtime(struct.unpack("<q", emu.read(arg(0), 8))[0])
        tm = emu.malloc(64)
        emu.write(tm, struct.pack("<9i4xq8x", t.tm_sec, t.tm_min, t.tm_hour, t.tm_mday, t.tm_mon - 1,
                                  t.tm_year - 1900, (t.tm_wday + 1) % 7, t.tm_yday - 1, t.tm_isdst, 0))
        return tm

    # --- memory ----------------------------------------------------------------------------
    @fn("_malloc", "__Znwm", "__Znam")
    def _malloc(e):
        return emu.malloc(arg(0))

    @fn("_calloc")
    def _calloc(e):
        return emu.malloc(arg(0) * arg(1))

    @fn("_posix_memalign")
    def _posix_memalign(e):
        alignment, size = arg(1), arg(2)
        emu.heap = (emu.heap + alignment - 1) & ~(alignment - 1)
        emu.write(arg(0), struct.pack("<Q", emu.malloc(size)))
        return 0

    def realloc(pointer, size):
        new = emu.malloc(size)
        if pointer:
            old = emu.sizes.get(pointer, size)
            emu.write(new, emu.read(pointer, min(old, size)))
        return new

    @fn("_realloc")
    def _realloc(e):
        return realloc(arg(0), arg(1))

    @fn("_free", "__ZdlPv", "__ZdaPv")
    def _free(e):
        return None

    @fn("_malloc_size")
    def _malloc_size(e):
        return emu.sizes.get(arg(0), 0)

    zones: list[int] = []

    # malloc_zone_t: two reserved words, then size, malloc, calloc, valloc, free, realloc, destroy and
    # zone_name; the client calls through it directly (zone->size), so every slot is a function here.
    f["zone.size"] = lambda e: emu.sizes.get(arg(1), 0)
    f["zone.malloc"] = lambda e: emu.malloc(arg(1))
    f["zone.calloc"] = lambda e: emu.malloc(arg(1) * arg(2))
    f["zone.valloc"] = lambda e: emu.malloc(arg(1))
    f["zone.free"] = lambda e: None
    f["zone.realloc"] = lambda e: realloc(arg(1), arg(2))
    f["zone.destroy"] = lambda e: None

    @fn("_malloc_default_zone", "_malloc_create_zone")
    def _zone(e):
        if not zones:
            zone = emu.malloc(256)
            slots = [emu.function_slot("zone." + n) for n in ("size", "malloc", "calloc", "valloc", "free", "realloc", "destroy")]
            emu.write(zone + 0x10, struct.pack("<7Q", *slots))
            zones.append(zone)
        return zones[0]

    @fn("_malloc_set_zone_name")
    def _zone_name(e):
        return None

    @fn("_malloc_zone_malloc")
    def _zone_malloc(e):
        return emu.malloc(arg(1))

    @fn("_malloc_zone_realloc")
    def _zone_realloc(e):
        return realloc(arg(1), arg(2))

    @fn("_malloc_zone_free")
    def _zone_free(e):
        return None

    @fn("_mmap")
    def _mmap(e):
        address, length, prot, flags, fd, offset = (arg(i) for i in range(6))
        fd = fd & 0xFFFFFFFF
        block = emu.malloc(length + 0x4000)
        block = (block + 0x3FFF) & ~0x3FFF
        if fd != 0xFFFFFFFF and isinstance(emu.fds.get(fd), dict):
            emu.write(block, bytes(emu.fds[fd]["data"][offset:offset + length]))
        return block

    @fn("_munmap")
    def _munmap(e):
        return 0

    # --- strings ---------------------------------------------------------------------------
    @fn("_memcpy", "_memmove", "___memcpy_chk", "___memmove_chk")
    def _memcpy(e):
        if arg(2):
            emu.write(arg(0), emu.read(arg(1), arg(2)))
        return arg(0)

    @fn("_memset", "___memset_chk")
    def _memset(e):
        if arg(2):
            emu.write(arg(0), bytes([arg(1) & 0xFF]) * arg(2))
        return arg(0)

    @fn("_bzero")
    def _bzero(e):
        if arg(1):
            emu.write(arg(0), bytes(arg(1)))
        return None

    @fn("_memset_pattern16")
    def _memset_pattern16(e):
        pattern, n = emu.read(arg(1), 16), arg(2)
        emu.write(arg(0), (pattern * (n // 16 + 1))[:n])
        return None

    @fn("_memcmp")
    def _memcmp(e):
        a, b = emu.read(arg(0), arg(2)), emu.read(arg(1), arg(2))
        for x, y in zip(a, b):
            if x != y:
                return (x - y) & 0xFFFFFFFF
        return 0

    @fn("_memchr")
    def _memchr(e):
        data = emu.read(arg(0), arg(2))
        at = data.find(bytes([arg(1) & 0xFF]))
        return arg(0) + at if at >= 0 else 0

    @fn("_strlen")
    def _strlen(e):
        return len(emu.cstring(arg(0), 1 << 20).encode("utf-8", "surrogateescape"))

    def raw_cstring(address, limit=1 << 20):
        out = bytearray()
        while len(out) < limit:
            chunk = emu.read(address + len(out), 64)
            end = chunk.find(b"\0")
            if end >= 0:
                return bytes(out + chunk[:end])
            out += chunk
        return bytes(out)

    def compare(a, b):
        return 0 if a == b else (1 if a > b else 0xFFFFFFFF)

    @fn("_strcmp")
    def _strcmp(e):
        return compare(raw_cstring(arg(0)), raw_cstring(arg(1)))

    @fn("_strncmp")
    def _strncmp(e):
        n = arg(2)
        return compare(raw_cstring(arg(0))[:n], raw_cstring(arg(1))[:n])

    @fn("_strrchr")
    def _strrchr(e):
        s = raw_cstring(arg(0))
        at = s.rfind(bytes([arg(1) & 0xFF]))
        return arg(0) + at if at >= 0 else 0

    @fn("_strcspn")
    def _strcspn(e):
        s, reject = raw_cstring(arg(0)), raw_cstring(arg(1))
        return next((i for i, c in enumerate(s) if c in reject), len(s))

    @fn("_strspn")
    def _strspn(e):
        s, accept = raw_cstring(arg(0)), raw_cstring(arg(1))
        return next((i for i, c in enumerate(s) if c not in accept), len(s))

    @fn("___strlcpy_chk")
    def _strlcpy(e):
        s, size = raw_cstring(arg(1)), arg(2)
        if size:
            emu.write(arg(0), s[:size - 1] + b"\0")
        return len(s)

    @fn("___strlcat_chk")
    def _strlcat(e):
        d, s, size = raw_cstring(arg(0)), raw_cstring(arg(1)), arg(2)
        joined = (d + s)[:max(size - 1, len(d))]
        emu.write(arg(0), joined + b"\0")
        return len(d) + len(s)

    # --- formatted output --------------------------------------------------------------------
    def format_string(fmt: bytes, next_slot) -> bytes:
        out = bytearray()
        i = 0
        while i < len(fmt):
            c = fmt[i]
            if c != 0x25:   # %
                out.append(c)
                i += 1
                continue
            j = i + 1
            while j < len(fmt) and fmt[j] in b"-+ #0123456789.*hlqjzt":
                j += 1
            if j >= len(fmt):
                break
            spec, conv = fmt[i + 1:j].decode(), chr(fmt[j])
            i = j + 1
            if conv == "%":
                out += b"%"
                continue
            flags = spec.rstrip("hlqjzt")
            length = spec[len(flags):]
            while "*" in flags:
                flags = flags.replace("*", str(next_slot() & 0xFFFFFFFF), 1)
            value = next_slot()
            if conv == "s":
                text = raw_cstring(value) if value else b"(null)"
                out += ("%" + flags + "s").encode() % text if flags else text
            elif conv in "di":
                bits = 64 if any(x in length for x in "lqjzt") else 32
                v = value & ((1 << bits) - 1)
                v = v - (1 << bits) if v >> (bits - 1) else v
                out += ("%" + flags + "d").encode() % v
            elif conv in "uxXo":
                bits = 64 if any(x in length for x in "lqjzt") else 32
                out += ("%" + flags + conv).encode() % (value & ((1 << bits) - 1))
            elif conv == "p":
                out += b"0x%x" % value
            elif conv == "c":
                out.append(value & 0xFF)
            elif conv in "feEgGaA":
                out += ("%" + flags + conv).encode() % struct.unpack("<d", struct.pack("<Q", value))[0]
            elif conv == "@":
                out += emu.describe(value).encode()
            else:
                out += f"%{spec}{conv}".encode()
        return bytes(out)

    emu.format_string = lambda fmt, start: format_string(fmt, stack_slots(start))

    def stack_slots(start):
        state = {"at": start}

        def next_slot():
            value = emu.u64(state["at"])
            state["at"] += 8
            return value
        return next_slot

    def emit(stream, data: bytes):
        emu.console.append(data.decode("utf-8", "replace"))

    @fn("_printf")
    def _printf(e):
        data = format_string(raw_cstring(arg(0)), stack_slots(emu.uc.reg_read(UC_ARM64_REG_SP)))
        emit(1, data)
        return len(data)

    @fn("_fprintf")
    def _fprintf(e):
        data = format_string(raw_cstring(arg(1)), stack_slots(emu.uc.reg_read(UC_ARM64_REG_SP)))
        emit(arg(0), data)
        return len(data)

    @fn("_vsnprintf")
    def _vsnprintf(e):
        data = format_string(raw_cstring(arg(2)), stack_slots(arg(3)))
        size = arg(1)
        if size:
            emu.write(arg(0), data[:size - 1] + b"\0")
        return len(data)

    @fn("_fputs")
    def _fputs(e):
        emit(arg(1), raw_cstring(arg(0)))
        return 1

    @fn("_fflush")
    def _fflush(e):
        return 0

    @fn("_NSLog")
    def _nslog(e):
        fmt = emu.nsstring(arg(0))
        data = format_string(fmt.encode(), stack_slots(emu.uc.reg_read(UC_ARM64_REG_SP)))
        emit(2, b"NSLog: " + data + b"\n")
        return None

    # --- files: the staged bundle read-only from the host; the app's container in memory -------
    # On the device the client's working directory is the folder holding its .app, and its
    # Application Support is the launcher's container. Here the bundle is read from the
    # staged copy, and the container lives in memory: nothing outside the emulator changes.
    container = container_home
    emu.container = container
    directories = {container, container + "/Library", container + "/Library/Application Support",
                   container + "/Documents", container + "/tmp"}
    memory_files: dict[str, bytearray] = {}
    emu.memory_files = memory_files

    def host_path(path: str) -> str | None:
        app = str(emu.app)
        return path if path == app or path.startswith(app + "/") else None

    def in_container(path: str) -> bool:
        return path == container or path.startswith(container + "/")

    def parent(path: str) -> str:
        return path.rsplit("/", 1)[0]

    def kind(path: str) -> str | None:
        real = host_path(path)
        if real:
            return "dir" if os.path.isdir(real) else "file" if os.path.isfile(real) else None
        # The container's own ancestors exist (so mkdir of them answers EEXIST, as on the device).
        if path in directories or path == "/" or container.startswith(path.rstrip("/") + "/"):
            return "dir"
        if path in memory_files:
            return "file"
        return None

    def make_directories(path: str) -> bool:
        """mkdir -p inside the container, as -[NSFileManager createDirectoryAtPath:...] would."""
        if not in_container(path):
            return False
        parts = path[len(container):].strip("/").split("/")
        for i in range(1, len(parts) + 1):
            directories.add(container + "/" + "/".join(parts[:i]))
        return True

    emu.vfs_kind = kind
    emu.vfs_make_directories = make_directories

    def new_fd(entry):
        fd = emu.next_fd
        emu.next_fd += 1
        emu.fds[fd] = entry
        return fd

    O_ACCMODE, O_APPEND, O_CREAT, O_TRUNC, O_EXCL = 3, 0x8, 0x200, 0x400, 0x800
    EEXIST, EISDIR, EINVAL, ENOTTY = 17, 21, 22, 25
    FAIL32, FAIL64 = 0xFFFFFFFF, 2**64 - 1

    @fn("_open")
    def _open(e):
        path, flags = emu.cstring(arg(0)), arg(1) & 0xFFFFFFFF
        emu.files_opened.append(f"open {path} ({flags:#x})")
        found = kind(path)
        if host_path(path):
            if flags & O_ACCMODE or found != "file":
                set_errno(EACCES if found else ENOENT)
                return FAIL32
            return new_fd({"path": path, "data": open(path, "rb").read(), "pos": 0, "writable": False})
        if not in_container(path):
            set_errno(ENOENT)
            return FAIL32
        if found == "dir":
            set_errno(EISDIR)
            return FAIL32
        if found is None:
            if not flags & O_CREAT or parent(path) not in directories:
                set_errno(ENOENT)
                return FAIL32
            memory_files[path] = bytearray()
        elif flags & O_CREAT and flags & O_EXCL:
            set_errno(EEXIST)
            return FAIL32
        if flags & O_TRUNC:
            memory_files[path] = bytearray()
        return new_fd({"path": path, "data": memory_files[path], "pos": 0, "writable": bool(flags & O_ACCMODE),
                       "append": bool(flags & O_APPEND)})

    def fd_entry(fd):
        entry = emu.fds.get(fd & 0xFFFFFFFF)
        if entry is None:
            set_errno(EBADF)
        return entry

    @fn("_close")
    def _close(e):
        return 0 if emu.fds.pop(arg(0) & 0xFFFFFFFF, None) is not None else (set_errno(EBADF) and FAIL32)

    @fn("_read")
    def _read(e):
        entry = fd_entry(arg(0))
        if entry is None or not isinstance(entry, dict):
            return FAIL64
        data = bytes(entry["data"][entry["pos"]:entry["pos"] + arg(2)])
        emu.write(arg(1), data)
        entry["pos"] += len(data)
        return len(data)

    @fn("_pread")
    def _pread(e):
        entry = fd_entry(arg(0))
        if entry is None or not isinstance(entry, dict):
            return FAIL64
        data = bytes(entry["data"][arg(3):arg(3) + arg(2)])
        emu.write(arg(1), data)
        return len(data)

    def put(entry, offset, data):
        buffer = entry["data"]
        if len(buffer) < offset:
            buffer.extend(bytes(offset - len(buffer)))
        buffer[offset:offset + len(data)] = data

    @fn("_write")
    def _write(e):
        fd, data = arg(0) & 0xFFFFFFFF, emu.read(arg(1), arg(2))
        if fd in (1, 2):
            emit(fd, data)
            return len(data)
        entry = fd_entry(fd)
        if entry is None or not isinstance(entry, dict) or not entry["writable"]:
            set_errno(EBADF)
            return FAIL64
        if entry.get("append"):
            entry["pos"] = len(entry["data"])
        put(entry, entry["pos"], data)
        entry["pos"] += len(data)
        return len(data)

    @fn("_pwrite")
    def _pwrite(e):
        entry = fd_entry(arg(0))
        if entry is None or not isinstance(entry, dict) or not entry["writable"]:
            set_errno(EBADF)
            return FAIL64
        put(entry, arg(3), emu.read(arg(1), arg(2)))
        return arg(2)

    @fn("_lseek")
    def _lseek(e):
        entry = fd_entry(arg(0))
        if entry is None or not isinstance(entry, dict):
            return FAIL64
        whence = arg(2) & 0xFFFFFFFF
        base = {0: 0, 1: entry["pos"], 2: len(entry["data"])}.get(whence)
        if base is None:
            set_errno(EINVAL)
            return FAIL64
        entry["pos"] = (base + arg(1)) & FAIL64
        return entry["pos"]

    @fn("_ftruncate")
    def _ftruncate(e):
        entry = fd_entry(arg(0))
        if entry is None or not isinstance(entry, dict) or not entry["writable"]:
            set_errno(EINVAL)
            return FAIL32
        size = arg(1)
        data = entry["data"]
        del data[size:]
        data.extend(bytes(size - len(data)))
        return 0

    def write_stat(buffer, size, mode):
        # struct stat (64-bit inode): st_mode at 4, st_size at 96, st_blksize at 112.
        st = bytearray(144)
        struct.pack_into("<H", st, 4, mode)
        struct.pack_into("<q", st, 96, size)
        struct.pack_into("<i", st, 112, 4096)
        emu.write(buffer, bytes(st))

    def stat_path(path, buffer):
        found = kind(path)
        if found is None:
            set_errno(ENOENT)
            return FAIL32
        if found == "dir":
            write_stat(buffer, 0, stat_module.S_IFDIR | 0o755)
        else:
            size = os.path.getsize(path) if host_path(path) else len(memory_files[path])
            write_stat(buffer, size, stat_module.S_IFREG | 0o644)
        return 0

    @fn("_stat", "_lstat")
    def _stat(e):
        return stat_path(emu.cstring(arg(0)), arg(1))

    @fn("_fstat")
    def _fstat(e):
        entry = fd_entry(arg(0))
        if entry is None or not isinstance(entry, dict):
            return FAIL32
        write_stat(arg(1), len(entry["data"]), stat_module.S_IFREG | 0o644)
        return 0

    @fn("_access")
    def _access(e):
        path = emu.cstring(arg(0))
        if kind(path) is None:
            set_errno(ENOENT)
            return FAIL32
        if arg(1) & 2 and not in_container(path):
            set_errno(EACCES)
            return FAIL32
        return 0

    @fn("_getcwd")
    def _getcwd(e):
        cwd = str(emu.app.parent).encode() + b"\0"
        buf = arg(0) or emu.malloc(len(cwd))
        emu.write(buf, cwd)
        return buf

    @fn("_mkdir")
    def _mkdir(e):
        path = emu.cstring(arg(0)).rstrip("/")
        emu.files_opened.append(f"mkdir {path}")
        if kind(path):
            set_errno(EEXIST)
            return FAIL32
        if not in_container(path) or parent(path) not in directories:
            set_errno(EACCES if not in_container(path) else ENOENT)
            return FAIL32
        directories.add(path)
        return 0

    @fn("_unlink", "_remove")
    def _unlink(e):
        path = emu.cstring(arg(0))
        if path in memory_files:
            del memory_files[path]
            return 0
        set_errno(ENOENT if not host_path(path) else EACCES)
        return FAIL32

    @fn("_rmdir")
    def _rmdir(e):
        path = emu.cstring(arg(0)).rstrip("/")
        if path in directories and in_container(path):
            directories.discard(path)
            return 0
        set_errno(ENOENT)
        return FAIL32

    @fn("_rename")
    def _rename(e):
        old, new = emu.cstring(arg(0)), emu.cstring(arg(1))
        if old in memory_files and in_container(new) and parent(new) in directories:
            memory_files[new] = memory_files.pop(old)
            return 0
        set_errno(ENOENT)
        return FAIL32

    @fn("_fsync", "_fchmod", "_fchown", "_futimes", "_utimes", "_flock")
    def _quiet_file(e):
        return 0

    # One process, so every lock is granted; F_GETLK reports the range unlocked. The third
    # argument is variadic: on the stack.
    @fn("_fcntl")
    def _fcntl(e):
        command = arg(1) & 0xFFFFFFFF
        if command == 7:   # F_GETLK: struct flock's l_type (offset 20) becomes F_UNLCK
            emu.write(stack(0) + 20, struct.pack("<h", 2))
        elif command == 50:   # F_GETPATH
            entry = emu.fds.get(arg(0) & 0xFFFFFFFF)
            if isinstance(entry, dict):
                emu.write(stack(0), entry["path"].encode() + b"\0")
        return 0

    @fn("_statfs", "_fstatfs")
    def _statfs(e):
        emu.write(arg(1), bytes(2168))
        return 0

    @fn("_fsctl")
    def _fsctl(e):
        set_errno(ENOTTY)
        return FAIL32

    @fn("_readlink")
    def _readlink(e):
        set_errno(EINVAL)
        return FAIL64

    # The sandbox: the container and the bundle open; the folders above the container are refused
    # (EPERM), the cautious reading of an app's sandbox, which ContainerPaths.c answers for.
    @fn("_opendir")
    def _opendir(e):
        path = emu.cstring(arg(0)).rstrip("/") or "/"
        emu.files_opened.append(f"opendir {path}")
        found = kind(path)
        if found == "dir" and (in_container(path) or host_path(path)):
            return emu.malloc(64)
        set_errno(1 if found == "dir" else ENOENT)
        return 0

    @fn("_closedir")
    def _closedir(e):
        return 0

    @fn("_NSSearchPathForDirectoriesInDomains")
    def _search_path(e):
        # NSApplicationSupportDirectory (14), NSDocumentDirectory (9), NSCachesDirectory (13)
        folder = {14: "/Library/Application Support", 9: "/Documents", 13: "/Library/Caches"}.get(arg(0) & 0xFFFFFFFF)
        if folder and folder.rsplit("/", 1)[0] and container + folder.rsplit("/", 1)[0] not in directories:
            directories.add(container + folder.rsplit("/", 1)[0])
        if folder:
            directories.add(container + folder)
        return emu.new_array([emu.new_string(container + folder)] if folder else [])

    # --- network: refused, as the offline guard refuses it ------------------------------------
    @fn("_getaddrinfo")
    def _getaddrinfo(e):
        emu.console.append(f"[network] lookup of {emu.cstring(arg(0))} refused: offline\n")
        return EAI_NONAME

    @fn("_socket")
    def _socket(e):
        fd = emu.next_fd
        emu.next_fd += 1
        return fd

    @fn("_connect")
    def _connect(e):
        set_errno(ENETUNREACH)
        return 0xFFFFFFFF

    @fn("_freeaddrinfo", "_setsockopt", "_getsockopt", "_poll")
    def _quiet(e):
        return 0

    # --- threads and locks: one thread ----------------------------------------------------------
    @fn("_pthread_mutex_init", "_pthread_mutex_destroy", "_pthread_mutex_lock", "_pthread_mutex_unlock",
        "_pthread_mutex_trylock", "_pthread_mutexattr_init", "_pthread_mutexattr_destroy",
        "_pthread_mutexattr_settype", "_pthread_join")
    def _lock(e):
        return 0

    @fn("_pthread_create")
    def _pthread_create(e):
        emu.threads.append((arg(2), arg(3)))
        emu.write(arg(0), struct.pack("<Q", 0x7000 + len(emu.threads)))
        return 0

    @fn("_pthread_setspecific")
    def _setspecific(e):
        emu.specific[arg(0)] = arg(1)
        return 0

    @fn("_dispatch_semaphore_create")
    def _sem(e):
        return emu.malloc(32)

    # A worker thread that would wait here ends its run (threads run one after another, each up to
    # its first wait); the main thread never waits on these.
    def block_if_thread(what):
        if emu.current_thread:
            raise BootStop(f"waits ({what})")

    @fn("_dispatch_semaphore_wait")
    def _sem_wait(e):
        block_if_thread("dispatch_semaphore_wait")
        return 0

    @fn("_dispatch_semaphore_signal", "_dispatch_release")
    def _sem_op(e):
        return 0

    @fn("_dispatch_data_create")
    def _dispatch_data(e):
        return emu.malloc(32)

    # --- thread-local variables -------------------------------------------------------------
    @fn("__tlv_bootstrap")
    def _tlv(e):
        descriptor = arg(0)
        key = (emu.current_thread, emu.u64(descriptor + 8))   # one block per thread and image key
        if key not in emu.tls_keys:
            emu.tls_keys[key] = emu.tls_block()
        return emu.tls_keys[key] + emu.u64(descriptor + 16)

    # --- arithmetic and maths ---------------------------------------------------------------
    @fn("___udivti3")
    def _udivti3(e):
        a = arg(0) | (arg(1) << 64)
        b = arg(2) | (arg(3) << 64)
        q = a // b if b else 0
        emu.set_reg(1, q >> 64)
        return q & (2**64 - 1)

    def double_in(n=0):
        return struct.unpack("<d", struct.pack("<Q", emu.uc.reg_read([UC_ARM64_REG_D0, UC_ARM64_REG_D1][n])))[0]

    def double_out(value):
        emu.uc.reg_write(UC_ARM64_REG_D0, struct.unpack("<Q", struct.pack("<d", value))[0])

    @fn("_cos")
    def _cos(e):
        double_out(math.cos(double_in()))

    @fn("_exp")
    def _exp(e):
        double_out(math.exp(double_in()))

    @fn("_fmodf")
    def _fmodf(e):
        a = struct.unpack("<f", struct.pack("<I", emu.uc.reg_read(UC_ARM64_REG_S0)))[0]
        b = struct.unpack("<f", struct.pack("<I", emu.uc.reg_read(UC_ARM64_REG_S1)))[0]
        emu.uc.reg_write(UC_ARM64_REG_S0, struct.unpack("<I", struct.pack("<f", math.fmod(a, b) if b else math.nan))[0])

    # --- audio output, as Tolkara's AudioToolbox adapter answers: the default output unit
    #     (RemoteIO on the device) is found, made and started; nothing renders here -------------
    @fn("_AudioComponentFindNext")
    def _audio_find(e):
        description = emu.read(arg(1), 20)
        emu.audio.append("find " + description[:4][::-1].decode("latin-1") + "/" + description[4:8][::-1].decode("latin-1"))
        return emu.malloc(32)

    @fn("_AudioComponentInstanceNew")
    def _audio_new(e):
        emu.write(arg(1), struct.pack("<Q", emu.malloc(64)))
        return 0

    @fn("_AudioUnitSetProperty")
    def _audio_set(e):
        emu.audio.append(f"set property {arg(1) & 0xFFFFFFFF} scope {arg(2) & 0xFFFFFFFF}")
        return 0

    @fn("_AudioUnitInitialize", "_AudioOutputUnitStart", "_AudioOutputUnitStop", "_AudioComponentInstanceDispose")
    def _audio_ok(e):
        emu.audio.append(emu.hle_name[1:])
        return 0

    # --- Core Graphics displays, as Tolkara's adapter answers (translation/CoreGraphics/Displays.m:
    #     one display, number 1, the screen's size in millimetres at 132 points per inch) ---------
    screen_points = (1366, 1024)

    @fn("_CGDisplayScreenSize")
    def _cg_screen_size(e):
        if arg(0) & 0xFFFFFFFF != 1:
            emu.set_doubles(0, 0)
        else:
            emu.set_doubles(screen_points[0] * 25.4 / 132, screen_points[1] * 25.4 / 132)
        return None

    @fn("_CGDisplayCopyDisplayMode")
    def _cg_copy_mode(e):
        return emu.malloc(64) if arg(0) & 0xFFFFFFFF == 1 else 0

    @fn("_CGDisplayModeGetRefreshRate")
    def _cg_refresh(e):
        emu.set_doubles(120.0 if arg(0) else 0.0)
        return None

    @fn("_CGDisplayModeRelease")
    def _cg_release(e):
        return None

    # --- the offline Steam library's own imports ----------------------------------------------
    @fn("_AKLogC")
    def _aklog(e):
        data = format_string(raw_cstring(arg(0)), stack_slots(emu.uc.reg_read(UC_ARM64_REG_SP)))
        emu.steam_calls.append("log: " + data.decode("utf-8", "replace").rstrip())
        return None

    # --- data ------------------------------------------------------------------------------
    def pointer_to(target):
        return lambda address: emu.write(address, struct.pack("<Q", target))

    d["___stdoutp"] = pointer_to(files.stdout)
    d["___stderrp"] = pointer_to(files.stderr)
    d["___stack_chk_guard"] = pointer_to(0x5EED5EED5EED5EED)
    for name in ("__NSConcreteGlobalBlock", "__NSConcreteStackBlock", "___CFConstantStringClassReference",
                 "__objc_empty_cache", "_NSDefaultRunLoopMode", "_NSEventTrackingRunLoopMode", "_NSApp"):
        d[name] = None

    # --- libc++ (Apple's arm64 string layout: data, size, capacity with the top bit set when long;
    #     short strings keep up to 22 bytes inline, their size in byte 23) ----------------------
    def string_get(this):
        raw = emu.read(this, 24)
        if raw[23] & 0x80:
            data, size = struct.unpack("<QQ", raw[:16])
            return emu.read(data, size) if size else b""
        return raw[:raw[23]]

    def string_capacity(this):
        raw = emu.read(this, 24)
        return (struct.unpack("<Q", raw[16:])[0] & ~(1 << 63)) - 1 if raw[23] & 0x80 else 22

    def string_set(this, value: bytes, reserve: int = 0):
        if len(value) <= 22 and reserve <= 22:
            emu.write(this, value + bytes(23 - len(value)) + bytes([len(value)]))
            return
        capacity = max(len(value), reserve) + 1
        data = emu.malloc(capacity)
        emu.write(data, value + b"\0")
        emu.write(this, struct.pack("<QQQ", data, len(value), capacity | (1 << 63)))

    @fn("__ZNKSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEE4findEcm")
    def _string_find(e):
        at = string_get(arg(0)).find(bytes([arg(1) & 0xFF]), arg(2))
        return at if at >= 0 else 2**64 - 1

    @fn("__ZNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEE6assignEPKc")
    def _string_assign(e):
        string_set(arg(0), raw_cstring(arg(1)))
        return arg(0)

    @fn("__ZNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEE7reserveEm")
    def _string_reserve(e):
        if arg(1) > string_capacity(arg(0)):
            string_set(arg(0), string_get(arg(0)), arg(1))
        return None

    @fn("__ZNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEE9push_backEc")
    def _string_push_back(e):
        string_set(arg(0), string_get(arg(0)) + bytes([arg(1) & 0xFF]), string_capacity(arg(0)))
        return None

    @fn("__ZNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEEaSEc")
    def _string_assign_char(e):
        string_set(arg(0), bytes([arg(1) & 0xFF]))
        return arg(0)

    @fn("__ZNSt3__112__next_primeEm")
    def _next_prime(e):
        n = max(arg(0), 2)
        while any(n % p == 0 for p in range(2, int(n ** 0.5) + 1)):
            n += 1
        return n

    @fn("__ZNSt3__115__thread_structC1Ev", "__ZNSt3__15mutex4lockEv", "__ZNSt3__15mutex6unlockEv",
        "__ZNSt3__15mutexD1Ev", "__ZNSt3__118condition_variableD1Ev", "__ZNSt3__118condition_variable10notify_allEv",
        "__ZNSt3__118condition_variable10notify_oneEv", "__ZNSt3__16thread6detachEv", "__ZNSt3__16threadD1Ev",
        "__ZNSt3__115__thread_structD1Ev", "__ZNSt3__114__shared_countD2Ev")
    def _cxx_nothing(e):
        return None

    @fn("__ZNSt3__111this_thread9sleep_forERKNS_6chrono8durationIxNS_5ratioILl1ELl1000000000EEEEE")
    def _sleep_for(e):
        block_if_thread("sleep_for")
        return None

    thread_local_data = emu.malloc(64)

    @fn("__ZNSt3__119__thread_local_dataEv")
    def _thread_local_data(e):
        return thread_local_data

    @fn("__ZNSt3__16chrono12steady_clock3nowEv")
    def _steady_now(e):
        return time.monotonic_ns()

    @fn("__ZNSt3__16chrono12system_clock3nowEv")
    def _system_now(e):
        return time.time_ns() // 1000

    @fn("__ZNSt3__118condition_variable4waitERNS_11unique_lockINS_5mutexEEE",
        "__ZNSt3__118condition_variable15__do_timed_waitERNS_11unique_lockINS_5mutexEEENS_6chrono10time_pointINS5_12system_clockENS5_8durationIxNS_5ratioILl1ELl1000000000EEEEEEE",
        "__ZNSt3__117__assoc_sub_state10__sub_waitERNS_11unique_lockINS_5mutexEEE")
    def _cxx_wait(e):
        block_if_thread(emu.hle_name)
        raise BootStop(f"the main thread waits on another thread ({emu.hle_name}); "
                       f"{len(emu.threads)} thread(s) started, none run here")

    d["__ZTVNSt3__117__assoc_sub_stateE"] = None

    import objc
    objc.register(emu, f, fn, arg, stack, BootStop)
    return SimpleNamespace(functions=f, data=d)
