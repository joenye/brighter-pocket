//! The client's threads, each on a host thread of its own with its own CPU, all at once as on
//! the device; and what they wait on (mutexes, condition variables, futures, semaphores, joins,
//! sleeps), answered with host waits behind one lock. Clocks are the host's.
use std::collections::{HashMap, HashSet, VecDeque};
use std::ffi::c_void;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use crate::cpu::{Cpu, Halter, Hooks};
use crate::hle::{Ctx, EXIT_ID, Registry, Stop};
use crate::machine::{HLE_BASE, Machine};
use crate::memory::ADDRESS_BITS;

pub const MAIN_STACK: u64 = 0x100_0000;
pub const THREAD_STACK: u64 = 0x10_0000;
/// pthread_t as the client sees it: 0x7000 + the thread's id.
const PTHREAD_BASE: u64 = 0x7000;

pub struct GuestThread {
    pub id: u32,
    pub errno: u64,
    pub tls: u64,
    halter: Mutex<Option<Halter>>,
    returned: std::sync::atomic::AtomicBool,
    /// The answer running on this thread (a wait is an answer) and its caller, for the report.
    state: Mutex<Option<(String, u64)>>,
    entry: std::sync::atomic::AtomicU64,
}

#[derive(Default)]
pub struct Runtime {
    threads: Mutex<HashMap<u32, Arc<GuestThread>>>,
    next: AtomicU32,
    sync: Mutex<SyncState>,
    changed: Condvar,
    handles: Mutex<Vec<std::thread::JoinHandle<()>>>,
    idle: Mutex<Vec<std::sync::mpsc::Sender<Job>>>, // workers waiting for a guest thread to run
    pub started: Mutex<Vec<(u64, u64)>>, // (entry, argument) of every thread the client started
    /// Every live thread when the run stopped: (id, entry, the answer it was in and its caller).
    pub at_stop: Mutex<Option<Vec<(u32, u64, Option<(String, u64)>)>>>,
}

/// A guest thread for a worker to run: the thread, its entry and two arguments.
struct Job {
    thread: Arc<GuestThread>,
    entry: u64,
    arguments: [u64; 2],
}

#[derive(Default)]
struct SyncState {
    owners: HashMap<u64, (u32, u32)>, // mutex -> (owner, depth)
    waiters: HashMap<u64, VecDeque<u64>>, // condition -> tickets in arrival order
    woken: HashSet<u64>,                // tickets notified
    next_ticket: u64,
    counts: HashMap<u64, i64>, // semaphore -> count
    finished: HashSet<u32>,
    specific: HashMap<(u32, u64), u64>,
}

static START: std::sync::LazyLock<Instant> = std::sync::LazyLock::new(Instant::now);

/// The host time since the run began (the first clock read).
pub fn uptime() -> Duration {
    START.elapsed()
}

/// What the CPU's hooks reach: the machine, and the guest thread the CPU runs now (a worker's
/// CPU runs one guest thread after another).
pub struct ThreadContext {
    m: Arc<Machine>,
    thread: Arc<GuestThread>,
    cpu: *mut Cpu,
}

impl Runtime {
    pub fn halt_all(&self) {
        let threads = self.threads.lock().unwrap();
        let mut at_stop = self.at_stop.lock().unwrap();
        if at_stop.is_none() {
            let mut live: Vec<_> = threads
                .values()
                .map(|t| (t.id, t.entry.load(Ordering::Relaxed), t.state.lock().unwrap().clone()))
                .collect();
            live.sort_by_key(|t| t.0);
            *at_stop = Some(live);
        }
        drop(at_stop);
        for thread in threads.values() {
            if let Some(halter) = *thread.halter.lock().unwrap() {
                halter.halt();
            }
        }
        drop(threads);
        // Wake every waiter so it sees the stop.
        let _sync = self.sync.lock().unwrap();
        self.changed.notify_all();
    }

    /// Drop the translated code for a range on every live thread's CPU (a probe put back).
    pub fn invalidate_all(&self, start: u64, length: u64) {
        for thread in self.threads.lock().unwrap().values() {
            if let Some(halter) = *thread.halter.lock().unwrap() {
                halter.invalidate(start, length);
            }
        }
    }

    /// Wait for every host thread the client started to end (after a stop).
    pub fn join_all(&self) {
        loop {
            let handle = self.handles.lock().unwrap().pop();
            match handle {
                Some(handle) => {
                    let _ = handle.join();
                }
                None => return,
            }
        }
    }

    fn lock(&self) -> MutexGuard<'_, SyncState> {
        self.sync.lock().unwrap()
    }

    /// Wait on the shared condition until `ready` holds, `deadline` passes (false) or the run stops.
    fn wait_until<'a>(
        &'a self,
        m: &Machine,
        mut sync: MutexGuard<'a, SyncState>,
        deadline: Option<Instant>,
        mut ready: impl FnMut(&mut SyncState) -> bool,
    ) -> Result<(MutexGuard<'a, SyncState>, bool), Stop> {
        loop {
            if ready(&mut sync) {
                return Ok((sync, true));
            }
            if m.is_stopping() {
                return Err(Stop("stopping".into()));
            }
            match deadline {
                Some(deadline) => {
                    let now = Instant::now();
                    if now >= deadline {
                        return Ok((sync, false));
                    }
                    sync = self.changed.wait_timeout(sync, (deadline - now).min(Duration::from_millis(250))).unwrap().0;
                }
                None => sync = self.changed.wait_timeout(sync, Duration::from_millis(250)).unwrap().0,
            }
        }
    }
}

/// Make a guest thread: its id, errno slot, thread-local block and stack.
pub fn new_thread(m: &Machine) -> Arc<GuestThread> {
    let id = m.runtime.next.fetch_add(1, Ordering::SeqCst);
    let thread = Arc::new(GuestThread {
        id,
        errno: m.alloc(16),
        tls: crate::loader::tls_block(m),
        halter: Mutex::new(None),
        returned: std::sync::atomic::AtomicBool::new(false),
        state: Mutex::new(None),
        entry: std::sync::atomic::AtomicU64::new(0),
    });
    m.runtime.threads.lock().unwrap().insert(id, thread.clone());
    thread
}

/// Forget a thread's CPU before it is dropped, so a stop no longer reaches it.
pub fn retire(thread: &GuestThread) {
    *thread.halter.lock().unwrap() = None;
}

/// The CPU a guest thread runs on, wired to the machine.
pub fn new_cpu(m: &Arc<Machine>, thread: &Arc<GuestThread>) -> (Box<Cpu>, Box<ThreadContext>) {
    let mut context = Box::new(ThreadContext { m: m.clone(), thread: thread.clone(), cpu: std::ptr::null_mut() });
    let hooks = Hooks {
        user: &mut *context as *mut ThreadContext as *mut c_void,
        svc: on_svc,
        fallback: on_fallback,
        exception: on_exception,
        mapped: on_mapped,
        fault: on_fault,
        counter: on_counter,
    };
    let mut cpu = Box::new(Cpu::new(hooks, m.memory.base(), ADDRESS_BITS, &m.monitor, thread.id as usize % crate::machine::MAX_THREADS));
    context.cpu = &mut *cpu;
    cpu.set_tpidr(thread.tls);
    *thread.halter.lock().unwrap() = Some(cpu.halter());
    (cpu, context)
}

/// Run `function(args)` on `cpu` until it returns; its x0. Stops early if the run stops.
pub fn call(m: &Machine, cpu: &mut Cpu, thread: &GuestThread, function: u64, args: &[u64]) -> Result<u64, Stop> {
    for (i, &value) in args.iter().enumerate() {
        cpu.set_reg(i as u32, value);
    }
    cpu.set_reg(30, HLE_BASE + EXIT_ID as u64 * crate::hle::SLOT_SIZE);
    cpu.set_pc(function);
    thread.returned.store(false, Ordering::SeqCst);
    thread.entry.store(function, Ordering::Relaxed);
    loop {
        cpu.run(u64::MAX);
        if let Some(reason) = m.stop_reason() {
            return Err(Stop(reason));
        }
        if thread.returned.load(Ordering::SeqCst) {
            return Ok(cpu.reg(0));
        }
    }
}

/// Start a guest thread running `entry(argument, second)` at once, on a worker of its own: an
/// idle one if there is one (the client starts a thread for every Metal completion handler, so
/// workers and their CPUs, whose translated code is the costly part, are kept), else a new one.
pub fn spawn(m: &Arc<Machine>, entry: u64, argument: u64, second: u64) -> u32 {
    let thread = new_thread(m);
    let id = thread.id;
    m.runtime.started.lock().unwrap().push((entry, argument));
    let mut job = Job { thread, entry, arguments: [argument, second] };
    loop {
        let Some(worker) = m.runtime.idle.lock().unwrap().pop() else { break };
        match worker.send(job) {
            Ok(()) => return id,
            Err(returned) => job = returned.0, // that worker has ended: try another
        }
    }
    let (sender, receiver) = std::sync::mpsc::channel::<Job>();
    sender.send(job).expect("a new worker's channel");
    let machine = m.clone();
    let handle = std::thread::Builder::new()
        .name(format!("guest-worker-{id}"))
        .stack_size(8 << 20)
        .spawn(move || worker(machine, sender, receiver))
        .expect("starting a host thread");
    m.runtime.handles.lock().unwrap().push(handle);
    id
}

fn worker(m: Arc<Machine>, me: std::sync::mpsc::Sender<Job>, jobs: std::sync::mpsc::Receiver<Job>) {
    let stack = m.alloc(THREAD_STACK);
    let mut cpu_and_context: Option<(Box<Cpu>, Box<ThreadContext>)> = None;
    loop {
        let job = match jobs.recv_timeout(Duration::from_millis(250)) {
            Ok(job) => job,
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) if !m.is_stopping() => continue,
            Err(_) => return,
        };
        let thread = job.thread.clone();
        let (cpu, _) = match cpu_and_context.as_mut() {
            Some((cpu, context)) => {
                context.thread = thread.clone();
                cpu.set_tpidr(thread.tls);
                *thread.halter.lock().unwrap() = Some(cpu.halter());
                (cpu, context)
            }
            None => {
                let made = new_cpu(&m, &thread);
                let made = cpu_and_context.insert(made);
                (&mut made.0, &mut made.1)
            }
        };
        cpu.set_sp(stack + THREAD_STACK - 0x100);
        let result = call(&m, cpu, &thread, job.entry, &job.arguments);
        retire(&thread);
        if let Err(stop) = result {
            if stop.0 != "stopping" {
                m.stop_with(stop);
            }
        }
        let runtime = &m.runtime;
        {
            let mut sync = runtime.lock();
            sync.finished.insert(thread.id);
            runtime.threads.lock().unwrap().remove(&thread.id);
            runtime.changed.notify_all();
        }
        if m.is_stopping() {
            return;
        }
        runtime.idle.lock().unwrap().push(me.clone());
    }
}

// --- the CPU's hooks ------------------------------------------------------------------------
fn context<'a>(user: *mut c_void) -> &'a mut ThreadContext {
    unsafe { &mut *(user as *mut ThreadContext) }
}

extern "C" fn on_svc(user: *mut c_void, immediate: u32) {
    let context = context(user);
    let cpu = unsafe { &mut *context.cpu };
    let m = &*context.m;
    if immediate == EXIT_ID {
        context.thread.returned.store(true, Ordering::SeqCst);
        cpu.halt();
        return;
    }
    if immediate == crate::probe::PROBE_SVC {
        crate::probe::hit(m, cpu, context.thread.id);
        return;
    }
    let caller = cpu.reg(30);
    cpu.set_reg(16, caller);
    let Some((name, answer)) = m.hle.lookup(immediate) else {
        m.stop(format!("svc #{immediate} at {}", m.where_(cpu.pc())));
        return;
    };
    m.report.answered(&name);
    let Some(answer) = answer else {
        m.report.unanswered(&name);
        m.stop(format!("{name} is not answered here (called from {})", m.where_(caller)));
        return;
    };
    let mut ctx = Ctx { m, cpu, thread: &context.thread, name: &name };
    *context.thread.state.lock().unwrap() = Some((name.clone(), caller));
    let result = answer(&mut ctx);
    *context.thread.state.lock().unwrap() = None;
    match result {
        Ok(Some(value)) => ctx.cpu.set_reg(0, value),
        Ok(None) => {}
        Err(stop) if stop.0 == "stopping" => {}
        Err(stop) => m.stop(stop.0),
    }
}

/// The few instructions dynarmic does not decode, all ARMv8.1 and later: LDADD (with any
/// ordering, 32 or 64 bits) and LDAPR. Done on the host's own atomics, then on to the next.
extern "C" fn on_fallback(user: *mut c_void, pc: u64) {
    let context = context(user);
    let cpu = unsafe { &mut *context.cpu };
    let m = &*context.m;
    let word = m.memory.u32(pc);
    let (size64, rs, rn, rt) = (word >> 30 == 3, (word >> 16) & 31, (word >> 5) & 31, word & 31);
    let base = if rn == 31 { cpu.sp() } else { cpu.reg(rn) };
    let value = |i: u32| if i == 31 { 0 } else { cpu.reg(i) };
    let is_ldadd = word & 0x3F20_FC00 == 0x3820_0000;
    let is_ldapr = word & 0x3FFF_FC00 == 0x38BF_C000;
    let loaded = if is_ldadd && (word >> 30) >= 2 && m.memory.is_mapped(base, if size64 { 8 } else { 4 }) {
        let host = unsafe { m.memory.base().add(base as usize) };
        if size64 {
            unsafe { std::sync::atomic::AtomicU64::from_ptr(host as *mut u64) }.fetch_add(value(rs), Ordering::SeqCst)
        } else {
            unsafe { std::sync::atomic::AtomicU32::from_ptr(host as *mut u32) }.fetch_add(value(rs) as u32, Ordering::SeqCst) as u64
        }
    } else if is_ldapr && (word >> 30) >= 2 && m.memory.is_mapped(base, if size64 { 8 } else { 4 }) {
        if size64 { m.memory.u64(base) } else { m.memory.u32(base) as u64 }
    } else {
        m.stop(format!("an instruction the emulator does not decode ({word:#010x}) at {}", m.where_(pc)));
        return;
    };
    if rt != 31 {
        cpu.set_reg(rt, loaded);
    }
    cpu.set_pc(pc + 4);
}

extern "C" fn on_exception(user: *mut c_void, pc: u64, kind: u32) {
    let context = context(user);
    let m = &*context.m;
    m.stop(format!("exception {kind} at {}", m.where_(pc)));
}

extern "C" fn on_mapped(user: *mut c_void, address: u64, size: u64) -> bool {
    context(user).m.memory.is_mapped(address, size)
}

extern "C" fn on_fault(user: *mut c_void, address: u64, _size: u64, write: bool) {
    let context = context(user);
    let cpu = unsafe { &*context.cpu };
    let m = &*context.m;
    let what = if write { "write to" } else { "read of" };
    m.stop(format!("{what} unmapped {address:#x} from {} (return address {})", m.where_(cpu.pc()), m.where_(cpu.reg(30))));
}

/// CNTPCT_EL0: Apple silicon's 24 MHz counter, from the host's monotonic clock.
extern "C" fn on_counter(_: *mut c_void) -> u64 {
    (START.elapsed().as_nanos() * 24 / 1000) as u64
}

// --- clocks ----------------------------------------------------------------------------------
pub fn now_ns() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() as u64
}

fn steady_ns() -> u64 {
    START.elapsed().as_nanos() as u64 + 1_000_000_000
}

fn instant_for_system_ns(ns: u64) -> Instant {
    let now = now_ns();
    if ns <= now { Instant::now() } else { Instant::now() + Duration::from_nanos(ns - now) }
}

// --- the answers ------------------------------------------------------------------------------
pub fn register(r: &mut Registry) {
    r.answer(&["_pthread_mutex_init", "_pthread_mutex_destroy", "_pthread_mutexattr_init", "_pthread_mutexattr_destroy", "_pthread_mutexattr_settype"], |_| Ok(Some(0)));
    r.answer(&["_pthread_mutex_lock", "__ZNSt3__15mutex4lockEv"], |c| {
        lock(c, c.arg(0))?;
        Ok(Some(0))
    });
    r.answer(&["_pthread_mutex_trylock"], |c| {
        let me = c.thread.id;
        let mut sync = c.m.runtime.lock();
        Ok(Some(match sync.owners.get_mut(&c.arg(0)) {
            None => {
                sync.owners.insert(c.arg(0), (me, 1));
                0
            }
            Some(owner) if owner.0 == me => {
                owner.1 += 1;
                0
            }
            Some(_) => 16, // EBUSY
        }))
    });
    r.answer(&["_pthread_mutex_unlock", "__ZNSt3__15mutex6unlockEv"], |c| {
        unlock(c, c.arg(0));
        Ok(Some(0))
    });
    r.answer(&["_pthread_create"], |c| {
        let m = c.m.arc();
        let id = spawn(&m, c.arg(2), c.arg(3), 0);
        c.mem().set_u64(c.arg(0), PTHREAD_BASE + id as u64);
        Ok(Some(0))
    });
    r.answer(&["_pthread_join"], |c| {
        let id = c.arg(0).wrapping_sub(PTHREAD_BASE) as u32;
        let runtime = &c.m.runtime;
        let sync = runtime.lock();
        let _ = runtime.wait_until(c.m, sync, None, |s| s.finished.contains(&id))?;
        Ok(Some(0))
    });
    r.answer(&["_pthread_self"], |c| Ok(Some(PTHREAD_BASE + c.thread.id as u64)));
    r.answer(&["_pthread_setspecific"], |c| {
        c.m.runtime.lock().specific.insert((c.thread.id, c.arg(0)), c.arg(1));
        Ok(Some(0))
    });
    r.answer(&["_pthread_getspecific"], |c| Ok(Some(c.m.runtime.lock().specific.get(&(c.thread.id, c.arg(0))).copied().unwrap_or(0))));

    // condition_variable::wait(unique_lock&) and the timed wait: the lock's mutex is its first
    // word. __assoc_sub_state::__sub_wait (a future's get): its condition variable is at offset
    // 88 (after the shared count, the exception pointer and the 64-byte mutex), its state word
    // at 136, and ready is bit 4.
    r.answer(&["__ZNSt3__118condition_variable4waitERNS_11unique_lockINS_5mutexEEE"], |c| {
        let mutex = c.mem().u64(c.arg(1));
        wait(c, c.arg(0), mutex, None)?;
        Ok(None)
    });
    r.answer(&["__ZNSt3__118condition_variable15__do_timed_waitERNS_11unique_lockINS_5mutexEEENS_6chrono10time_pointINS5_12system_clockENS5_8durationIxNS_5ratioILl1ELl1000000000EEEEEEE"], |c| {
        let mutex = c.mem().u64(c.arg(1));
        wait(c, c.arg(0), mutex, Some(instant_for_system_ns(c.arg(2))))?;
        Ok(None)
    });
    r.answer(&["__ZNSt3__117__assoc_sub_state10__sub_waitERNS_11unique_lockINS_5mutexEEE"], |c| {
        let state = c.arg(0);
        if c.mem().u32(state + 136) & 4 != 0 {
            return Ok(None);
        }
        let mutex = c.mem().u64(c.arg(1));
        wait(c, state + 88, mutex, None)?;
        Ok(None)
    });
    r.answer(&["__ZNSt3__118condition_variable10notify_allEv"], |c| {
        notify(c, c.arg(0), usize::MAX);
        Ok(None)
    });
    r.answer(&["__ZNSt3__118condition_variable10notify_oneEv"], |c| {
        notify(c, c.arg(0), 1);
        Ok(None)
    });
    r.answer(&["_pthread_cond_wait"], |c| {
        wait(c, c.arg(0), c.arg(1), None)?;
        Ok(Some(0))
    });
    r.answer(&["_pthread_cond_signal"], |c| {
        notify(c, c.arg(0), 1);
        Ok(Some(0))
    });
    r.answer(&["_pthread_cond_broadcast"], |c| {
        notify(c, c.arg(0), usize::MAX);
        Ok(Some(0))
    });
    r.answer(&["_pthread_cond_init", "_pthread_cond_destroy"], |_| Ok(Some(0)));

    r.answer(&["_dispatch_semaphore_create"], |c| {
        let semaphore = c.alloc(32);
        c.m.runtime.lock().counts.insert(semaphore, c.arg(0) as i64);
        Ok(Some(semaphore))
    });
    // dispatch_semaphore_wait(semaphore, timeout): DISPATCH_TIME_NOW tries once, FOREVER waits;
    // any other timeout (the client builds none with dispatch_time) waits up to 10 ms.
    r.answer(&["_dispatch_semaphore_wait"], |c| {
        let (semaphore, timeout) = (c.arg(0), c.arg(1));
        let deadline = match timeout {
            u64::MAX => None,
            0 => Some(Instant::now()),
            _ => Some(Instant::now() + Duration::from_millis(10)),
        };
        let runtime = &c.m.runtime;
        let sync = runtime.lock();
        let (_guard, taken) = runtime.wait_until(c.m, sync, deadline, |s| {
            let count = s.counts.entry(semaphore).or_insert(0);
            if *count > 0 {
                *count -= 1;
                true
            } else {
                false
            }
        })?;
        Ok(Some(if taken { 0 } else { 1 }))
    });
    r.answer(&["_dispatch_semaphore_signal"], |c| {
        let runtime = &c.m.runtime;
        let mut sync = runtime.lock();
        *sync.counts.entry(c.arg(0)).or_insert(0) += 1;
        runtime.changed.notify_all();
        Ok(Some(0))
    });

    r.answer(&["_sched_yield"], |_| {
        std::thread::yield_now();
        Ok(Some(0))
    });
    r.answer(&["_nanosleep"], |c| {
        let (seconds, nanos) = (c.mem().u64(c.arg(0)), c.mem().u64(c.arg(0) + 8));
        sleep(c, Duration::from_nanos(seconds.saturating_mul(1_000_000_000).saturating_add(nanos)))?;
        Ok(Some(0))
    });
    r.answer(&["_usleep"], |c| {
        sleep(c, Duration::from_micros(c.arg32(0) as u64))?;
        Ok(Some(0))
    });
    r.answer(&["__ZNSt3__111this_thread9sleep_forERKNS_6chrono8durationIxNS_5ratioILl1ELl1000000000EEEEE"], |c| {
        sleep(c, Duration::from_nanos(c.mem().u64(c.arg(0)).max(0)))?;
        Ok(None)
    });

    r.answer(&["_time"], |c| {
        let now = now_ns() / 1_000_000_000;
        if c.arg(0) != 0 {
            c.mem().set_u64(c.arg(0), now);
        }
        Ok(Some(now))
    });
    r.answer(&["_gettimeofday"], |c| {
        if c.arg(0) != 0 {
            let now = now_ns();
            c.mem().set_u64(c.arg(0), now / 1_000_000_000);
            c.mem().set_u32(c.arg(0) + 8, (now / 1000 % 1_000_000) as u32);
        }
        Ok(Some(0))
    });
    r.answer(&["__ZNSt3__16chrono12steady_clock3nowEv"], |_| Ok(Some(steady_ns())));
    r.answer(&["__ZNSt3__16chrono12system_clock3nowEv"], |_| Ok(Some(now_ns() / 1000)));
    r.answer(&["_mach_absolute_time"], |_| Ok(Some(on_counter(std::ptr::null_mut()))));

    r.answer(&["__ZNSt3__115__thread_structC1Ev", "__ZNSt3__15mutexD1Ev", "__ZNSt3__118condition_variableD1Ev", "__ZNSt3__16thread6detachEv", "__ZNSt3__16threadD1Ev", "__ZNSt3__115__thread_structD1Ev", "__ZNSt3__114__shared_countD2Ev"], |_| Ok(None));
    r.answer(&["__ZNSt3__119__thread_local_dataEv"], |c| {
        let data = *c.state::<ThreadLocalData>().lock().unwrap().0.get_or_insert_with(|| c.m.alloc(64));
        Ok(Some(data))
    });
    // A future's exception_ptr going away: null unless something was thrown (then its exception
    // object is only kept, never freed, here).
    r.answer(&["__ZNSt13exception_ptrD1Ev"], |c| {
        if c.mem().u64(c.arg(0)) != 0 {
            c.console("[harness] an exception_ptr holding an exception went away");
        }
        Ok(None)
    });
}

#[derive(Default)]
struct ThreadLocalData(Option<u64>);

fn lock(c: &Ctx, mutex: u64) -> Result<(), Stop> {
    let me = c.thread.id;
    let runtime = &c.m.runtime;
    let sync = runtime.lock();
    let _ = runtime.wait_until(c.m, sync, None, |s| match s.owners.get_mut(&mutex) {
        None => {
            s.owners.insert(mutex, (me, 1));
            true
        }
        Some(owner) if owner.0 == me => {
            owner.1 += 1;
            true
        }
        Some(_) => false,
    })?;
    Ok(())
}

fn unlock(c: &Ctx, mutex: u64) {
    let runtime = &c.m.runtime;
    let mut sync = runtime.lock();
    if let Some(owner) = sync.owners.get_mut(&mutex) {
        owner.1 = owner.1.saturating_sub(1);
        if owner.1 == 0 {
            sync.owners.remove(&mutex);
            runtime.changed.notify_all();
        }
    }
}

/// A condition variable's wait: release the mutex (whatever its depth), wait to be notified or
/// for the deadline, take the mutex back at the same depth.
fn wait(c: &Ctx, condition: u64, mutex: u64, deadline: Option<Instant>) -> Result<(), Stop> {
    let me = c.thread.id;
    let runtime = &c.m.runtime;
    let mut sync = runtime.lock();
    let depth = match sync.owners.get(&mutex) {
        Some(&(owner, depth)) if owner == me => depth,
        _ => 1,
    };
    sync.owners.remove(&mutex);
    let ticket = sync.next_ticket;
    sync.next_ticket += 1;
    sync.waiters.entry(condition).or_default().push_back(ticket);
    runtime.changed.notify_all();
    let (mut sync, woken) = runtime.wait_until(c.m, sync, deadline, |s| s.woken.remove(&ticket))?;
    if !woken {
        if let Some(queue) = sync.waiters.get_mut(&condition) {
            queue.retain(|&t| t != ticket);
        }
    }
    let (_guard, _) = runtime.wait_until(c.m, sync, None, |s| {
        if s.owners.contains_key(&mutex) {
            return false;
        }
        s.owners.insert(mutex, (me, depth));
        true
    })?;
    Ok(())
}

fn notify(c: &Ctx, condition: u64, count: usize) {
    let runtime = &c.m.runtime;
    let mut sync = runtime.lock();
    let mut woken = Vec::new();
    if let Some(queue) = sync.waiters.get_mut(&condition) {
        while woken.len() < count {
            match queue.pop_front() {
                Some(ticket) => woken.push(ticket),
                None => break,
            }
        }
    }
    sync.woken.extend(woken);
    runtime.changed.notify_all();
}

fn sleep(c: &Ctx, length: Duration) -> Result<(), Stop> {
    let deadline = Instant::now() + length;
    let runtime = &c.m.runtime;
    let sync = runtime.lock();
    let _ = runtime.wait_until(c.m, sync, Some(deadline), |_| false)?;
    Ok(())
}
