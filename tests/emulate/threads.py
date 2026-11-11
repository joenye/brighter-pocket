"""Threads for the boot harness: the client's own threads, run by turns on one emulated CPU.

Each thread the client starts (pthread_create) gets its own stack, registers and thread-local
storage. The scheduler runs one at a time: a thread runs until it waits (a mutex someone else
holds, a condition variable, a future, a semaphore, a sleep, a join), or for SLICE
instructions, then the next ready one runs. Waits follow the primitives' own rules: a
condition variable's wait releases its mutex and takes it again when woken, notify wakes one
or all, a timed wait also wakes after a few rounds, a semaphore counts. So work the main
thread hands to a pool is done by the pool, as on the device, only slower and in a fixed order.
"""
from __future__ import annotations

from collections import deque

from unicorn.arm64_const import UC_ARM64_REG_PC, UC_ARM64_REG_SP, UC_ARM64_REG_X30

SLICE = 2_000_000          # instructions a thread runs before the next one's turn
TIMED_WAIT_ROUNDS = 8       # rounds after which a timed wait returns (as on a timeout)
THREAD_STACK = 0x10_0000
EBUSY = 16


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

    # --- threads ------------------------------------------------------------------------------
    def spawn(self, entry: int, argument: int, second: int = 0) -> int:
        ident = len(self.threads) + self.finished
        stack = self.spare_stacks.pop() if self.spare_stacks else self.emu.malloc(THREAD_STACK)
        self.threads[ident] = Thread(ident, entry, argument, stack, second)
        self.ready.append(ident)
        return ident

    def run(self, round_limit: int = 1_000_000) -> None:
        """Run every thread by turns until the main thread (0) ends the run, or none can run."""
        uc = self.emu.uc
        while self.round < round_limit:
            self.round += 1
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
            self.switch = False
            try:
                uc.emu_start(pc, self.sentinel, count=SLICE)
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
                self._wake(("join", thread.ident))
                continue
            thread.context = uc.context_save()
            if thread.state == "ready":       # its slice ended, or it yielded
                self.ready.append(thread.ident)
        raise self.Stop(f"{round_limit} rounds without an end")

    def _expire_timed_waits(self) -> None:
        for thread in self.timed:
            if thread.state == "blocked" and self.round >= thread.deadline:
                self._remove_waiter(thread)
                self._resume(thread)
        self.timed = [t for t in self.timed if t.state == "blocked" and t.deadline is not None]

    # --- waiting: each thing waited on keeps its waiters in the order they came ----------------
    def block(self, waiting: tuple, after_wake=None, rounds: int | None = None) -> None:
        """End the current thread's turn until something wakes it (from inside an answer)."""
        thread = self.current
        thread.after_wake = after_wake
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
    def wait(self, condition: int, mutex: int, rounds: int | None = None) -> None:
        owner = self.owners.get(mutex)
        depth = owner[1] if owner else 1
        if owner:
            self._release(mutex)
        self.block(("condition", condition), self._take_back(mutex, depth), rounds)

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

    def join(self, ident: int) -> None:
        thread = self.threads.get(ident)
        if thread and thread.state != "done":
            self.block(("join", ident))
