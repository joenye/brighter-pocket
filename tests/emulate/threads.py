"""Threads for the boot harness: the client's own threads, run by turns on one emulated CPU.

Each thread the client starts (pthread_create) gets its own stack, registers and thread-local
storage. The scheduler runs one at a time: a thread runs until it waits (a mutex someone else
holds, a condition variable, a future, a semaphore, a sleep, a join), or for SLICE_BLOCKS
translated blocks (host/turns.c counts them), then the next ready one runs. Waits follow the
primitives' own rules: a condition variable's wait releases its mutex and takes it again when
woken, notify wakes one or all, a timed wait also ends when the emulated clock (hle.py, "time")
reaches its deadline, and when nothing can run the clock moves on to the nearest one; a
semaphore counts. So work the main thread hands to a pool is done by the pool, as on the
device, only slower, in a fixed order, and the same on every run.
"""
from __future__ import annotations

import ctypes
import subprocess
import time
from collections import Counter, deque
from pathlib import Path

from unicorn import UC_HOOK_BLOCK
from unicorn.arm64_const import UC_ARM64_REG_PC, UC_ARM64_REG_SP, UC_ARM64_REG_TPIDR_EL0, UC_ARM64_REG_X30
from unicorn.unicorn_py3 import unicorn as unicorn_core

SLICE_BLOCKS = 400_000     # translated blocks a thread runs before the next one's turn
TURNS_SOURCE = Path(__file__).resolve().parent / "host/turns.c"
TURNS_LIBRARY = Path(__file__).resolve().parents[2] / "build/emulate/host/libturns.so"
TIMED_WAIT_ROUNDS = 8       # rounds after which a timed wait with no deadline on the clock returns
THREAD_STACK = 0x10_0000
EBUSY = 16


class Turn(ctypes.Structure):
    _fields_ = [("blocks", ctypes.c_uint64), ("limit", ctypes.c_uint64), ("stop", ctypes.c_void_p)]


def turn_counter(uc) -> Turn:
    """host/turns.c, built for this machine if needed, as a block hook on uc: a turn ends once
    its limit of blocks has run (set before each turn; unlimited until the first)."""
    if not TURNS_LIBRARY.is_file() or TURNS_LIBRARY.stat().st_mtime < TURNS_SOURCE.stat().st_mtime:
        TURNS_LIBRARY.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["cc", "-O2", "-shared", "-fPIC", str(TURNS_SOURCE), "-o", str(TURNS_LIBRARY)], check=True)
    library = ctypes.CDLL(str(TURNS_LIBRARY))
    core = unicorn_core.uclib
    turn = Turn(0, 2**64 - 1, ctypes.cast(core.uc_emu_stop, ctypes.c_void_p))
    handle = ctypes.c_size_t()
    # The Python binding's hook_add takes Python callables only; the C API takes this one. uc._uch
    # is the binding's engine handle (unicorn 2.1).
    status = core.uc_hook_add(uc._uch, ctypes.byref(handle), ctypes.c_int(UC_HOOK_BLOCK),
                              ctypes.c_void_p(ctypes.cast(library.pocket_turn_block, ctypes.c_void_p).value),
                              ctypes.byref(turn), ctypes.c_uint64(1), ctypes.c_uint64(0))
    if status:
        raise RuntimeError(f"uc_hook_add for the turn counter failed ({status})")
    turn._keep = (library, handle)
    return turn


class Thread:
    def __init__(self, ident: int, entry: int, argument: int, stack: int, second: int = 0):
        self.ident = ident
        self.entry = entry
        self.stack = stack
        self.context = None                 # saved registers once it has run
        self.start = (entry, argument, second, stack + THREAD_STACK - 0x100)
        self.state = "ready"
        self.waiting: tuple | None = None   # what it waits on
        self.deadline: int | None = None    # round a timed wait gives up
        self.after_wake = None              # what waking it does first (take a mutex back)
        self.where = ""                     # the wait it is in, and its caller
        self.deadline_ns = 0                # a timed wait's deadline on the emulated clock


class Scheduler:
    def __init__(self, emu, sentinel: int, stop):
        self.emu = emu
        self.sentinel = sentinel
        self.Stop = stop
        self.threads: dict[int, Thread] = {}
        self.ready: deque[int] = deque()
        self.current: Thread | None = None
        self.round = 0
        self.owners: dict[int, list] = {}   # mutex -> [thread id, depth]
        self.counts: dict[int, int] = {}    # semaphore -> count
        self.switch = False                 # set by a waiting answer: end this thread's turn
        self.spare_stacks: list[int] = []   # stacks of threads that returned
        self.finished = 0
        self.queues: dict[tuple, deque[int]] = {}   # what is waited on -> its waiters, oldest first
        self.timed: list[Thread] = []               # threads in a wait that gives up
        self.main_calls: Counter = Counter()        # (answered import, caller) on thread 0 since the last frame
        self.turn = emu.turn                        # host/turns.c's counter (boot.Emulator)

    # --- threads ------------------------------------------------------------------------------
    def spawn(self, entry: int, argument: int, second: int = 0) -> int:
        ident = len(self.threads) + self.finished
        stack = self.spare_stacks.pop() if self.spare_stacks else self.emu.malloc(THREAD_STACK)
        self.threads[ident] = Thread(ident, entry, argument, stack, second)
        # Its thread-local block (boot.tls_block), in TPIDR_EL0 whenever it runs; the main
        # thread keeps the one its initializers used.
        self.threads[ident].tls = self.emu.main_tls if ident == 0 else self.emu.tls_block()
        self.ready.append(ident)
        return ident

    def run(self, stall_seconds: float = 900) -> None:
        """Run every thread by turns until the main thread (0) ends the run, none can run, or no
        frame has been presented for self.stall seconds of the host's time (a try from a save
        point sets its own)."""
        uc = self.emu.uc
        self.stall = stall_seconds
        frames, since = self.emu.frames, time.monotonic()
        while True:
            self.round += 1
            if self.emu.interrupted:
                raise self.Stop(f"interrupted after {self.emu.frames} frames, between turns")
            if self.emu.frames != frames:
                frames, since = self.emu.frames, time.monotonic()
                self.main_calls.clear()
            elif self.round % 256 == 0 and time.monotonic() - since > self.stall:
                main = self.threads[0]
                where = (main.where if main.state == "blocked" else
                         self.emu.where(main.context.reg_read(UC_ARM64_REG_PC)) if main.context else "?")
                calls = ", ".join(f"{name} from {self.emu.where(caller)} x{n}"
                                  for (name, caller), n in self.main_calls.most_common(6))
                raise self.Stop(f"no frame for {self.stall:.0f} s after frame {frames} "
                                f"(the main thread {main.state}: {where}; since that frame it called {calls})")
            self._expire_timed_waits()
            if not self.ready:
                waits = sorted({str(t.waiting[0]) for t in self.threads.values() if t.state == "blocked"})
                raise self.Stop(f"every thread waits ({', '.join(waits)}): a deadlock, or work the harness cannot do")
            thread = self.threads[self.ready.popleft()]
            self.current = thread
            self.emu.current_thread = thread.ident
            if thread.context is None:
                entry, argument, second, stack_top = thread.start
                self.emu.set_reg(0, argument)
                self.emu.set_reg(1, second)
                uc.reg_write(UC_ARM64_REG_SP, stack_top)
                uc.reg_write(UC_ARM64_REG_X30, self.sentinel)
                pc = entry
            else:
                uc.context_restore(thread.context)
                pc = uc.reg_read(UC_ARM64_REG_PC)
            uc.reg_write(UC_ARM64_REG_TPIDR_EL0, thread.tls)
            self.switch = False
            self.turn.blocks, self.turn.limit = 0, SLICE_BLOCKS
            try:
                uc.emu_start(pc, self.sentinel)
            except Exception as error:   # a fault: name the thread
                if isinstance(error, self.Stop):
                    raise
                raise self.Stop(f"thread {thread.ident}: emulation fault {error} at "
                                f"{self.emu.where(uc.reg_read(UC_ARM64_REG_PC))} "
                                f"(return address {self.emu.where(uc.reg_read(UC_ARM64_REG_X30))})")
            if uc.reg_read(UC_ARM64_REG_PC) == self.sentinel:
                if thread.ident == 0:
                    raise self.Stop("returned from the entry point")
                del self.threads[thread.ident]   # a join on it now returns at once
                self.finished += 1
                self.spare_stacks.append(thread.stack)
                self.emu.spare_tls.append(thread.tls)
                self._wake(("join", thread.ident))
                continue
            thread.context = uc.context_save()
            if thread.state == "ready":       # its slice ended, or it yielded
                self.ready.append(thread.ident)

    def _expire_timed_waits(self) -> None:
        """A timed wait with a deadline on the emulated clock ends once the clock reaches it, one
        without (a semaphore's) after TIMED_WAIT_ROUNDS rounds. With nothing else to run, the clock
        moves on to the nearest deadline, as time passes on an idle device; on the host's clock
        (emu.live_clock), the host waits for it instead, a quarter of a second at a time."""
        if self.emu.live_clock:
            self.emu.pass_time(0)
        if not self.ready:
            pending = [t.deadline_ns for t in self.timed if t.state == "blocked" and t.deadline_ns]
            if pending and self.emu.live_clock:
                time.sleep(min(max(min(pending) - time.time_ns(), 0) / 1e9, 0.25))
                self.emu.pass_time(0)
            elif pending:
                self.emu.clock_ns = max(self.emu.clock_ns, min(pending))
        for thread in self.timed:
            if thread.state != "blocked" or thread.deadline is None:
                continue
            if (self.emu.clock_ns >= thread.deadline_ns) if thread.deadline_ns else (self.round >= thread.deadline):
                self._remove_waiter(thread)
                self._resume(thread)
        self.timed = [t for t in self.timed if t.state == "blocked" and t.deadline is not None]

    # --- waiting: each thing waited on keeps its waiters in the order they came ----------------
    def block(self, waiting: tuple, after_wake=None, rounds: int | None = None) -> None:
        """End the current thread's turn until something wakes it (from inside an answer)."""
        thread = self.current
        thread.after_wake, thread.deadline_ns = after_wake, 0
        self._enqueue(thread, waiting)
        if rounds:
            thread.deadline = self.round + rounds
            self.timed.append(thread)
        thread.where = f"{self.emu.hle_name} from {self.emu.where(self.emu.uc.reg_read(UC_ARM64_REG_X30))}"
        self.switch = True
        self.emu.uc.emu_stop()

    def yield_turn(self) -> None:
        self.switch = True
        self.emu.uc.emu_stop()

    def _enqueue(self, thread: Thread, waiting: tuple) -> None:
        thread.state, thread.waiting = "blocked", waiting
        self.queues.setdefault(waiting, deque()).append(thread.ident)

    def _remove_waiter(self, thread: Thread) -> None:
        queue = self.queues.get(thread.waiting)
        if queue is not None:
            queue.remove(thread.ident)
            if not queue:
                del self.queues[thread.waiting]
        thread.waiting, thread.deadline = None, None

    def _resume(self, thread: Thread) -> None:
        action, thread.after_wake = thread.after_wake, None
        thread.state = "ready"
        if action and not action(thread):
            return                            # it waits again (for the mutex it needs back)
        self.ready.append(thread.ident)

    def _wake(self, waiting: tuple, count: int | None = None) -> int:
        woken = 0
        while self.queues.get(waiting) and (count is None or woken < count):
            thread = self.threads[self.queues[waiting][0]]
            self._remove_waiter(thread)
            self._resume(thread)
            woken += 1
        return woken

    # --- mutexes ------------------------------------------------------------------------------
    def lock(self, mutex: int) -> None:
        owner = self.owners.get(mutex)
        me = self.current.ident
        if owner is None:
            self.owners[mutex] = [me, 1]
        elif owner[0] == me:
            owner[1] += 1
        else:
            self.block(("mutex", mutex), lambda t: self._set_depth(mutex, t, 1))

    def trylock(self, mutex: int) -> int:
        owner = self.owners.get(mutex)
        me = self.current.ident
        if owner is None:
            self.owners[mutex] = [me, 1]
            return 0
        if owner[0] == me:
            owner[1] += 1
            return 0
        return EBUSY

    def unlock(self, mutex: int) -> None:
        owner = self.owners.get(mutex)
        if not owner:
            return
        owner[1] -= 1
        if owner[1] <= 0:
            self._release(mutex)

    def _release(self, mutex: int) -> None:
        """Free the mutex; the thread that has waited longest for it takes it."""
        del self.owners[mutex]
        self._wake(("mutex", mutex), 1)

    def _take_back(self, mutex: int, depth: int):
        def action(thread: Thread) -> bool:
            if mutex not in self.owners:
                self.owners[mutex] = [thread.ident, depth]
                return True
            self._enqueue(thread, ("mutex", mutex))
            thread.after_wake = lambda t: self._set_depth(mutex, t, depth)
            return False
        return action

    def _set_depth(self, mutex: int, thread: Thread, depth: int) -> bool:
        self.owners[mutex] = [thread.ident, depth]
        return True

    # --- condition variables, futures, semaphores, sleeps, joins --------------------------------
    def wait(self, condition: int, mutex: int, rounds: int | None = None, deadline_ns: int = 0) -> None:
        owner = self.owners.get(mutex)
        depth = owner[1] if owner else 1
        if owner:
            self._release(mutex)
        self.block(("condition", condition), self._take_back(mutex, depth), rounds)
        self.current.deadline_ns = deadline_ns

    def notify(self, condition: int, everyone: bool) -> None:
        self._wake(("condition", condition), None if everyone else 1)

    def semaphore_wait(self, semaphore: int, timeout: int) -> int:
        if self.counts.get(semaphore, 0) > 0:
            self.counts[semaphore] -= 1
            return 0
        if timeout == 0:
            return 1
        self.block(("semaphore", semaphore), None, None if timeout == 2**64 - 1 else TIMED_WAIT_ROUNDS)
        return 0

    def semaphore_signal(self, semaphore: int) -> int:
        if self._wake(("semaphore", semaphore), 1):
            return 1
        self.counts[semaphore] = self.counts.get(semaphore, 0) + 1
        return 0

    def sleep_until(self, deadline_ns: int) -> None:
        """A sleep on the host's clock: the thread waits until the clock reaches deadline_ns."""
        self.block(("sleep", self.current.ident), None, rounds=1)
        self.current.deadline_ns = deadline_ns

    def join(self, ident: int) -> None:
        thread = self.threads.get(ident)
        if thread and thread.state != "done":
            self.block(("join", ident))
