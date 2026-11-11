#!/usr/bin/env python3
"""Run the client's own startup on the host, in an arm64 emulator, until it presents frames.

usage: tests/emulate/boot.py [--client DIR] [--frameworks DIR] [--frames N] [--pinned-appkit] [--check]

The executable's arm64 slice is mapped at its preferred addresses and fixed up
(tools/macho.py), its initializers run, then main, on one thread. This layer's adapters are
the real arm64 iOS builds from tools/build_ios.py (the app's Frameworks folder), loaded beside
it and fixed up the same way: the client's Steam calls, and its connect, getaddrinfo and
opendir, run the adapters' own instructions. Everything else is answered here, in Python, as
the device would answer it, as far as startup asks: the C library (allocation, strings, the
staged bundle read-only, the app's container in memory, a sandbox that refuses the folders
above the container); Objective-C, with the client's own classes running their own methods
and Tolkara's AppKit answering exactly the selectors its adapter and this layer implement
(tests/emulate/appkit.py) and nil for the rest, as on the device; Core Graphics, audio output
and Metal as Tolkara's adapters present them, with every shader library put through the
on-device rewrap's checks. Threads the client starts are recorded, not run. Nothing is
written outside the emulator, and nothing reaches a network.

It stops after --frames presented frames, when the client exits, or when it calls something
not answered here, and reports what it saw. --pinned-appkit answers AppKit as the pinned
Tolkara alone does. --check prints only the verdict and fails unless the run presented its
frames with every shader accepted and nothing but harmless AppKit calls left unanswered.
"""
from __future__ import annotations

import argparse
import struct
import sys
from collections import Counter
from pathlib import Path

from unicorn import Uc, UcError, UC_ARCH_ARM64, UC_MODE_ARM, UC_HOOK_CODE, UC_HOOK_MEM_UNMAPPED
from unicorn.arm64_const import (UC_ARM64_REG_D0, UC_ARM64_REG_PC, UC_ARM64_REG_SP, UC_ARM64_REG_X0, UC_ARM64_REG_X29,
                                 UC_ARM64_REG_X30, UC_CPU_ARM64_MAX)

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import common  # noqa: E402
import macho  # noqa: E402

PAGE = 0x4000
ADAPTER_BASE = 0x2_0000_0000
HLE_BASE = 0x3_0000_0000          # one 16-byte slot per answered import
HLE_SIZE = 0x10_0000
DATA_BASE = 0x3_1000_0000         # imported data: classes, constants
DATA_SIZE = 0x100_0000
HEAP_BASE = 0x4_0000_0000
HEAP_SIZE = 0x4000_0000           # 1 GiB, committed lazily by the host
STACK_TOP = 0x5_0100_0000
STACK_SIZE = 0x100_0000
TLS_BASE = 0x5_1000_0000
TLS_SIZE = 0x100_0000
EXIT_SENTINEL = HLE_BASE + HLE_SIZE - 16


def align(value: int, to: int = PAGE) -> int:
    return (value + to - 1) & ~(to - 1)


class Stop(Exception):
    pass


class Image:
    """An image mapped into the emulator at its own addresses plus `slide`."""

    def __init__(self, emu: "Emulator", data: bytes, slide: int, name: str):
        self.image = macho.Image(data)
        self.slide = slide
        self.name = name
        for seg in self.image.segments:
            if seg.name == "__PAGEZERO" or not seg.vmsize:
                continue
            start = slide + seg.vmaddr
            emu.uc.mem_map(start & ~(PAGE - 1), align(seg.vmsize + (start & (PAGE - 1))))
            emu.uc.mem_write(start, self.image.data[seg.fileoff:seg.fileoff + seg.filesize])
        self.exports = {name: slide + addr for name, addr in self.image.exports().items()}

    def fix_up(self, emu: "Emulator", resolve) -> tuple[int, int]:
        imports = self.image.imports()
        rebases = binds = 0
        for vmaddr, raw, fmt in self.image.chain():
            kind, value, extra = self.image.decode(raw, fmt)
            if kind == "rebase":
                emu.uc.mem_write(self.slide + vmaddr, struct.pack("<Q", (value + self.slide) | (extra << 56)))
                rebases += 1
            else:
                imp = imports[value]
                address = resolve(imp, self)
                emu.uc.mem_write(self.slide + vmaddr, struct.pack("<Q", (address + imp.addend + extra) & (2**64 - 1)))
                binds += 1
        return rebases, binds


class Emulator:
    def __init__(self, app: Path, frameworks: Path, limit: int, trace: bool, pinned_appkit: bool = False):
        self.uc = Uc(UC_ARCH_ARM64, UC_MODE_ARM)
        # The client is built for Apple silicon: LSE atomics and the rest of ARMv8.x.
        self.uc.ctl_set_cpu_model(UC_CPU_ARM64_MAX)
        self.app = app
        self.limit = limit
        self.trace = trace
        self.console: list[str] = []
        self.files_opened: list[str] = []
        self.objc_sends: Counter = Counter()
        self.steam_calls: list[str] = []
        self.unanswered: list[str] = []
        self.hle: dict[int, tuple[str, callable]] = {}
        self.hle_by_name: dict[str, int] = {}
        self.data: dict[str, int] = {}
        self.next_hle = HLE_BASE
        self.next_data = DATA_BASE
        self.heap = HEAP_BASE
        self.sizes: dict[int, int] = {}
        self.objects: dict[int, str] = {}          # fake Objective-C objects: address -> class name
        self.fds: dict[int, bytes] = {}
        self.fd_pos: dict[int, int] = {}
        self.next_fd = 10
        self.tls_keys: dict[int, int] = {}
        self.next_tls = TLS_BASE
        self.atexit: list = []
        self.threads: list = []
        self.audio: list[str] = []
        self.frame_limit = 30
        self.current_thread = 0           # 0 the main thread, n the n-th thread the client started
        self.thread_runs: list[tuple[str, str]] = []
        self.library_refusals: list[str] = []
        self.specific: dict[int, int] = {}
        self.selectors: dict[str, int] = {}
        self.jump_to: int | None = None
        self.hle_name: str | None = None
        self.Stop = Stop
        for base, size in ((HLE_BASE, HLE_SIZE), (DATA_BASE, DATA_SIZE), (HEAP_BASE, HEAP_SIZE),
                           (STACK_TOP - STACK_SIZE, STACK_SIZE), (TLS_BASE, TLS_SIZE)):
            self.uc.mem_map(base, size)
        self.uc.hook_add(UC_HOOK_CODE, self._on_hle, begin=HLE_BASE, end=HLE_BASE + HLE_SIZE - 1)
        self.uc.hook_add(UC_HOOK_MEM_UNMAPPED, self._on_unmapped)
        if trace:
            self.uc.hook_add(UC_HOOK_CODE, self._on_trace)
        import hle
        self.answers = hle.answers(self)
        executable = (app / common.BUNDLE_EXECUTABLE).read_bytes()
        self.client = Image(self, macho.thin(executable), 0, "client")
        # This layer's adapters, as the app carries them (tools/build_ios.py): the client's binds
        # to libsteam_api, and those of its libSystem imports the guard defines, run their code.
        self.adapters = {
            "libsteam_api.dylib": Image(self, (frameworks / "aklibsteam_api.dylib").read_bytes(), ADAPTER_BASE, "aklibsteam_api"),
            "libSystem.B.dylib": Image(self, (frameworks / "aklibSystem.B.dylib").read_bytes(), ADAPTER_BASE + 0x1000_0000,
                                       "aklibSystem.B"),
        }
        self.client_fixups = self.client.fix_up(self, self._resolve)
        self.adapter_fixups = tuple(map(sum, zip(*(a.fix_up(self, self._resolve) for a in self.adapters.values()))))
        # The device's AppKit, as a build from the prepared tree would have it (or, with
        # pinned_appkit, as the pinned Tolkara alone has it, without this layer's additions).
        import appkit
        import prepare
        if pinned_appkit:
            tree = ROOT / "platform"
        else:
            tree = common.BUILD / "emulate/platform"
            prepare.prepare(tree)
        appkit_classes = {i.name[len("_OBJC_CLASS_$_"):] for i in self.client.image.imports()
                          if i.name.startswith("_OBJC_CLASS_$_") and self.client.image.library(i.ordinal).endswith("/AppKit")}
        self.appkit = appkit.AppKitCoverage(tree, appkit_classes)

    # --- imports ------------------------------------------------------------------------
    def _resolve(self, imp: macho.Import, image: Image) -> int:
        library = image.image.library(imp.ordinal)
        adapter = self.adapters.get(library.rsplit("/", 1)[-1]) if image is self.client else None
        if adapter and imp.name in adapter.exports:
            return adapter.exports[imp.name]
        if adapter and library.endswith("libsteam_api.dylib"):
            raise SystemExit(f"the Steam adapter does not export {imp.name}")
        if imp.name in self.answers.data:
            return self.data_symbol(imp.name)
        if imp.name.startswith(("_OBJC_CLASS_$_", "_OBJC_METACLASS_$_")):
            return self.data_symbol(imp.name)
        return self.function_slot(imp.name)

    def function_slot(self, name: str) -> int:
        if name in self.hle_by_name:
            return self.hle_by_name[name]
        address = self.next_hle
        self.next_hle += 16
        self.uc.mem_write(address, struct.pack("<I", 0xD65F03C0))   # ret, never reached: the hook answers first
        self.hle[address] = (name, self.answers.functions.get(name))
        self.hle_by_name[name] = address
        return address

    def data_symbol(self, name: str) -> int:
        if name in self.data:
            return self.data[name]
        size = 256
        address = self.next_data
        self.next_data += size
        self.data[name] = address
        if name.startswith(("_OBJC_CLASS_$_", "_OBJC_METACLASS_$_")):
            self.objects[address] = name.split("$_", 1)[1]
        init = self.answers.data.get(name)
        if init:
            init(address)
        return address

    # --- memory -------------------------------------------------------------------------
    def malloc(self, size: int, zero: bool = True) -> int:
        size = max(16, (size + 15) & ~15)
        address = self.heap
        self.heap += size
        if self.heap > HEAP_BASE + HEAP_SIZE:
            raise Stop("the emulated heap is full")
        self.sizes[address] = size
        return address

    def read(self, address: int, size: int) -> bytes:
        return bytes(self.uc.mem_read(address, size))

    def write(self, address: int, data: bytes) -> None:
        self.uc.mem_write(address, data)

    def u64(self, address: int) -> int:
        return struct.unpack("<Q", self.read(address, 8))[0]

    def cstring(self, address: int, limit: int = 4096) -> str:
        out = bytearray()
        while len(out) < limit:
            chunk = self.read(address + len(out), 64)
            end = chunk.find(b"\0")
            if end >= 0:
                out += chunk[:end]
                break
            out += chunk
        return out.decode("utf-8", "replace")

    def reg(self, n: int) -> int:
        return self.uc.reg_read(UC_ARM64_REG_X0 + n) if n < 29 else self.uc.reg_read(
            {29: UC_ARM64_REG_X29, 30: UC_ARM64_REG_X30}[n])

    def set_reg(self, n: int, value: int) -> None:
        self.uc.reg_write(UC_ARM64_REG_X0 + n, value & (2**64 - 1))

    # --- hooks --------------------------------------------------------------------------
    def _on_hle(self, uc, address, size, user):
        if address == EXIT_SENTINEL:
            raise Stop("returned from the entry point")
        name, answer = self.hle.get(address, (None, None))
        if name is None:
            return
        lr = uc.reg_read(UC_ARM64_REG_X30)
        if answer is None:
            self.unanswered.append(name)
            raise Stop(f"{name} is not answered here (called from {self.where(lr)})")
        self.hle_name = name
        try:
            result = answer(self)
        except Stop:
            raise
        except Exception as error:   # a gap in the model, not in the client: say where
            import traceback
            raise Stop(f"the answer for {name} failed (called from {self.where(lr)}): {error!r}\n"
                       + "".join(traceback.format_exc().splitlines(True)[-4:]))
        if result is not None:
            self.set_reg(0, result)
        # A message to one of the client's own classes continues in its implementation,
        # which returns to the caller itself.
        target, self.jump_to = (self.jump_to, None) if self.jump_to else (lr, None)
        uc.reg_write(UC_ARM64_REG_PC, target)

    def _on_unmapped(self, uc, access, address, size, value, user):
        pc = uc.reg_read(UC_ARM64_REG_PC)
        raise Stop(f"unmapped access at {address:#x} from {self.where(pc)}")

    def _on_trace(self, uc, address, size, user):
        pass

    def tls_block(self) -> int:
        """A thread's copy of the client's thread-local template (__thread_data, then zeroed __thread_bss)."""
        image = self.client.image
        data = image.section("__DATA", "__thread_data")
        bss = image.section("__DATA", "__thread_bss")
        start = data.addr if data else bss.addr
        end = max(s.addr + s.size for s in (data, bss) if s)
        block = self.next_tls
        self.next_tls += (end - start + 0xFFF) & ~0xFFF
        if data:
            self.write(block, self.read(data.addr, data.size))
        return block

    def set_doubles(self, *values: float) -> None:
        """A floating-point result: one double in d0, or a homogeneous aggregate (NSRect) in d0 to d3."""
        for i, value in enumerate(values):
            self.uc.reg_write(UC_ARM64_REG_D0 + i, struct.unpack("<Q", struct.pack("<d", float(value)))[0])

    def selector(self, name: str) -> int:
        if name not in self.selectors:
            address = self.malloc(len(name) + 1)
            self.write(address, name.encode() + b"\0")
            self.selectors[name] = address
        return self.selectors[name]

    def where(self, address: int) -> str:
        if 0x1_0000_0000 <= address < ADAPTER_BASE:
            return f"client+{address - 0x100000000:#x}"
        for adapter in self.adapters.values():
            if adapter.slide <= address < adapter.slide + 0x1000_0000:
                return f"{adapter.name}+{address - adapter.slide:#x}"
        return hex(address)

    # --- running --------------------------------------------------------------------------
    def call(self, function: int, *args: int, budget: int, stack_top: int = STACK_TOP) -> int:
        """Run function(args) until it returns to the sentinel; the result in x0."""
        sp = stack_top - 0x1000
        self.uc.reg_write(UC_ARM64_REG_SP, sp)
        for i, value in enumerate(args):
            self.set_reg(i, value)
        self.uc.reg_write(UC_ARM64_REG_X30, EXIT_SENTINEL)
        try:
            self.uc.emu_start(function, EXIT_SENTINEL, count=budget)
        except UcError as error:
            pc = self.uc.reg_read(UC_ARM64_REG_PC)
            lr = self.uc.reg_read(UC_ARM64_REG_X30)
            raise Stop(f"emulation fault {error} at {self.where(pc)} (return address {self.where(lr)})")
        if self.uc.reg_read(UC_ARM64_REG_PC) != EXIT_SENTINEL:
            raise Stop(f"instruction budget spent at {self.where(self.uc.reg_read(UC_ARM64_REG_PC))}")
        return self.reg(0)

    def initializers(self) -> list[int]:
        section = self.client.image.section("__TEXT", "__init_offsets")
        offsets = struct.unpack(f"<{section.size // 4}I", self.read(section.addr, section.size))
        return [self.client.image.base + o for o in offsets]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--client", type=Path)
    parser.add_argument("--frameworks", type=Path, default=common.BUILD / "ios/Payload/BrighterPocket.app/Frameworks",
                        help="the app's Frameworks folder from tools/build_ios.py (its adapters run here)")
    parser.add_argument("--limit", type=int, default=2_000_000_000)
    parser.add_argument("--trace", action="store_true")
    parser.add_argument("--frames", type=int, default=30, help="stop after this many presented frames")
    parser.add_argument("--pinned-appkit", action="store_true",
                        help="answer AppKit as the pinned Tolkara alone does, without pocket/translation/AppKit")
    parser.add_argument("--check", action="store_true", help="print the verdict only; fail unless startup completed")
    parser.add_argument("--threads", action="store_true",
                        help="then run each thread the client started, one after another, up to its first wait")
    args = parser.parse_args()
    if not (args.frameworks / "aklibsteam_api.dylib").is_file():
        raise SystemExit(f"no adapters in {args.frameworks}: build the app with tools/build_ios.py")
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    emu = Emulator(common.client_app(args.client), args.frameworks, args.limit, args.trace, args.pinned_appkit)
    emu.frame_limit = args.frames
    if not args.check:
        print(f"client fixed up: {emu.client_fixups[0]} rebases, {emu.client_fixups[1]} binds; "
              f"adapters: {emu.adapter_fixups[0]} rebases, {emu.adapter_fixups[1]} binds")
    outcome = "ok"
    try:
        for i, init in enumerate(emu.initializers()):
            emu.call(init, 0, 0, 0, 0, budget=args.limit)
        if not args.check:
            print(f"{len(emu.initializers())} initializers ran")
        argv = emu.malloc(32)
        path = emu.malloc(256)
        emu.write(path, str(emu.app / common.BUNDLE_EXECUTABLE).encode() + b"\0")
        emu.write(argv, struct.pack("<QQ", path, 0))
        entry = emu.client.image.base + emu.client.image.entry
        emu.call(entry, 1, argv, 0, 0, budget=args.limit)
    except Stop as stop:
        outcome = str(stop)
    if args.threads:
        run_threads(emu)
    if args.check:
        return verdict(emu, outcome, args.frames)
    print("stopped:", outcome)
    print("console:")
    for line in "".join(emu.console).splitlines():
        print("  | " + line)
    print("steam:", *emu.steam_calls, sep="\n  ")
    print("files opened:", *emu.files_opened, sep="\n  ")
    unimplemented = sorted(f"[{cls} {sel.split()[0]}]" for (cls, sel) in emu.objc_sends if "unimplemented" in sel)
    print("AppKit messages the device answers with nil (unimplemented):", *unimplemented, sep="\n  ")
    print("objective-c sends to system classes (top 40):")
    for (cls, sel), n in emu.objc_sends.most_common(40):
        print(f"  {n:6d} [{cls} {sel}]")
    print("last objective-c sends:", *emu.recent[-15:], sep="\n  ")
    print(f"shader libraries: {emu.libraries['accepted']} accepted, {emu.libraries['refused']} refused"
          + (f" ({emu.library_refusals[0]})" if emu.library_refusals else ""))
    print(f"frames presented: {emu.frames}")
    print("images made from data (pointer images):", dict(Counter(emu.image_formats)))
    print("audio:", *emu.audio, sep="\n  ")
    print(f"threads started: {len(emu.threads)}" + ("" if args.threads else " (not run; --threads runs them)"))
    for where, result in emu.thread_runs:
        print(f"  {where}: {result}")
    return 0


THREAD_STACK = 0x10_0000
THREAD_BUDGET = 50_000_000
MAX_THREADS = 100


def run_threads(emu) -> None:
    """Each thread the client started, in the order it started them, on its own stack and its own
    thread-local storage, until it returns, waits (a condition variable, a semaphore, a sleep), or
    spends THREAD_BUDGET instructions. Threads they start join the end of the list. On the device
    they run together; here each runs alone, so what one waits for another may never produce."""
    index = 0
    while index < len(emu.threads) and index < MAX_THREADS:
        entry, argument = emu.threads[index]
        index += 1
        emu.current_thread = index
        stack = emu.malloc(THREAD_STACK)
        try:
            emu.call(entry, argument, budget=THREAD_BUDGET, stack_top=stack + THREAD_STACK)
            result = "returned"
        except Stop as stop:
            result = str(stop)
        emu.thread_runs.append((f"thread {index} at {emu.where(entry)}", result))
    emu.current_thread = 0


# Tolkara AppKit selectors the client sends that the adapter leaves to its stub (nil): each
# returns nothing, and nothing the client does depends on it.
HARMLESS = {"[-NSApplication setMenu:]", "[-NSWindow center]", "[-NSWindow setMaxSize:]"}


def verdict(emu, outcome: str, frames: int) -> int:
    unimplemented = {f"[{cls} {sel.split()[0]}]" for (cls, sel) in emu.objc_sends if "unimplemented" in sel}
    problems = []
    if outcome != f"presented {frames} frames":
        problems.append(f"stopped before presenting {frames} frames: {outcome}")
    if emu.libraries["refused"]:
        problems.append(f"{emu.libraries['refused']} shader libraries refused")
    if unimplemented - HARMLESS:
        problems.append("unanswered AppKit calls: " + ", ".join(sorted(unimplemented - HARMLESS)))
    if "exception:" in "".join(emu.console):
        problems.append("the client reported an exception")
    steam = "initialised offline" if any("[steam] initialised offline" in line for line in emu.steam_calls) else "not initialised"
    if steam != "initialised offline":
        problems.append("Steam was not initialised")
    print(f"startup: Steam {steam}, {emu.libraries['accepted']} shader libraries accepted, "
          f"{emu.frames} frames presented, {len(emu.threads)} threads started (not run here)")
    for problem in problems:
        print("  problem: " + problem)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
