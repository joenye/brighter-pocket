//! One emulated arm64 CPU: dynarmic's A64 JIT through src/cpu/dynarmic.cpp. Each guest thread
//! that runs on its own host thread has its own `Cpu`; they share the guest's memory (fastmem,
//! src/memory.rs) and one exclusive monitor, so the client's atomics hold across them.
use std::ffi::c_void;

#[repr(C)]
pub struct Hooks {
    pub user: *mut c_void,
    pub svc: extern "C" fn(*mut c_void, u32),
    pub fallback: extern "C" fn(*mut c_void, u64),
    pub exception: extern "C" fn(*mut c_void, u64, u32),
    pub mapped: extern "C" fn(*mut c_void, u64, u64) -> bool,
    pub fault: extern "C" fn(*mut c_void, u64, u64, bool),
    pub counter: extern "C" fn(*mut c_void) -> u64,
}

#[repr(C)]
struct RawMonitor {
    _private: [u8; 0],
}
#[repr(C)]
struct RawCpu {
    _private: [u8; 0],
}

unsafe extern "C" {
    fn pocket_monitor_new(processors: usize) -> *mut RawMonitor;
    fn pocket_cpu_new(hooks: *const Hooks, base: *mut u8, bits: u32, monitor: *mut RawMonitor, id: usize) -> *mut RawCpu;
    fn pocket_cpu_free(cpu: *mut RawCpu);
    fn pocket_cpu_run(cpu: *mut RawCpu, ticks: u64) -> u32;
    fn pocket_cpu_halt(cpu: *mut RawCpu);
    fn pocket_cpu_reg(cpu: *mut RawCpu, i: u32) -> u64;
    fn pocket_cpu_set_reg(cpu: *mut RawCpu, i: u32, v: u64);
    fn pocket_cpu_sp(cpu: *mut RawCpu) -> u64;
    fn pocket_cpu_set_sp(cpu: *mut RawCpu, v: u64);
    fn pocket_cpu_pc(cpu: *mut RawCpu) -> u64;
    fn pocket_cpu_set_pc(cpu: *mut RawCpu, v: u64);
    fn pocket_cpu_vector(cpu: *mut RawCpu, i: u32, out: *mut u64);
    fn pocket_cpu_set_vector(cpu: *mut RawCpu, i: u32, lo: u64, hi: u64);
    fn pocket_cpu_tpidr(cpu: *mut RawCpu) -> u64;
    fn pocket_cpu_set_tpidr(cpu: *mut RawCpu, v: u64);
}

/// The exclusive monitor all CPUs share (ldxr/stxr across threads).
pub struct Monitor(*mut RawMonitor);
unsafe impl Send for Monitor {}
unsafe impl Sync for Monitor {}

impl Monitor {
    pub fn new(processors: usize) -> Monitor {
        Monitor(unsafe { pocket_monitor_new(processors) })
    }
}

pub struct Cpu {
    raw: *mut RawCpu,
    _hooks: Box<Hooks>,
}
unsafe impl Send for Cpu {}

/// A handle that can stop a `Cpu` from another thread.
#[derive(Clone, Copy)]
pub struct Halter(*mut RawCpu);
unsafe impl Send for Halter {}
unsafe impl Sync for Halter {}
impl Halter {
    pub fn halt(&self) {
        unsafe { pocket_cpu_halt(self.0) }
    }
}

impl Cpu {
    /// `base` is the host address of guest address 0, with `bits` of guest address space.
    pub fn new(hooks: Hooks, base: *mut u8, bits: u32, monitor: &Monitor, id: usize) -> Cpu {
        let hooks = Box::new(hooks);
        let raw = unsafe { pocket_cpu_new(&*hooks, base, bits, monitor.0, id) };
        Cpu { raw, _hooks: hooks }
    }
    /// Run until halted or until `ticks` instructions have run; the halt reasons.
    pub fn run(&mut self, ticks: u64) -> u32 {
        unsafe { pocket_cpu_run(self.raw, ticks) }
    }
    pub fn halter(&self) -> Halter {
        Halter(self.raw)
    }
    pub fn halt(&self) {
        unsafe { pocket_cpu_halt(self.raw) }
    }
    pub fn reg(&self, i: u32) -> u64 {
        unsafe { pocket_cpu_reg(self.raw, i) }
    }
    pub fn set_reg(&mut self, i: u32, v: u64) {
        unsafe { pocket_cpu_set_reg(self.raw, i, v) }
    }
    pub fn sp(&self) -> u64 {
        unsafe { pocket_cpu_sp(self.raw) }
    }
    pub fn set_sp(&mut self, v: u64) {
        unsafe { pocket_cpu_set_sp(self.raw, v) }
    }
    pub fn pc(&self) -> u64 {
        unsafe { pocket_cpu_pc(self.raw) }
    }
    pub fn set_pc(&mut self, v: u64) {
        unsafe { pocket_cpu_set_pc(self.raw, v) }
    }
    pub fn vector(&self, i: u32) -> [u64; 2] {
        let mut out = [0u64; 2];
        unsafe { pocket_cpu_vector(self.raw, i, out.as_mut_ptr()) };
        out
    }
    pub fn set_vector(&mut self, i: u32, lo: u64, hi: u64) {
        unsafe { pocket_cpu_set_vector(self.raw, i, lo, hi) }
    }
    pub fn tpidr(&self) -> u64 {
        unsafe { pocket_cpu_tpidr(self.raw) }
    }
    pub fn set_tpidr(&mut self, v: u64) {
        unsafe { pocket_cpu_set_tpidr(self.raw, v) }
    }
}

impl Drop for Cpu {
    fn drop(&mut self) {
        unsafe { pocket_cpu_free(self.raw) }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    extern "C" fn svc(user: *mut c_void, immediate: u32) {
        unsafe { *(user as *mut u32) = immediate };
    }
    extern "C" fn fallback(_: *mut c_void, pc: u64) {
        panic!("fallback at {pc:#x}");
    }
    extern "C" fn exception(_: *mut c_void, pc: u64, kind: u32) {
        panic!("exception {kind} at {pc:#x}");
    }
    extern "C" fn mapped(_: *mut c_void, address: u64, size: u64) -> bool {
        address >= 0x10000 && address + size <= 0x20000
    }
    extern "C" fn fault(_: *mut c_void, address: u64, _: u64, _: bool) {
        panic!("fault at {address:#x}");
    }
    extern "C" fn counter(_: *mut c_void) -> u64 {
        0
    }

    /// A loop of 4 instructions run 2^25 times, then an svc: the JIT runs it, the svc reaches
    /// Rust with its immediate, and registers come back as the loop left them.
    #[test]
    fn runs_a_loop_and_an_svc() {
        let size = 1usize << 36;
        let base = unsafe {
            libc::mmap(std::ptr::null_mut(), size, libc::PROT_NONE, libc::MAP_PRIVATE | libc::MAP_ANONYMOUS | libc::MAP_NORESERVE, -1, 0)
        } as *mut u8;
        unsafe { libc::mprotect(base.add(0x10000) as *mut c_void, 0x10000, libc::PROT_READ | libc::PROT_WRITE) };
        let code: [u32; 7] = [
            0xd2a00000 | (0x200 << 5), // movz x0, #0x200, lsl #16
            0x8b000021,                // add x1, x1, x0
            0xca010042,                // eor x2, x2, x1
            0xf1000400,                // subs x0, x0, #1
            0x54ffffa1,                // b.ne -12
            0xd4000541,                // svc #42
            0x14000000,                // b . (halted by the svc's caller)
        ];
        for (i, word) in code.iter().enumerate() {
            unsafe { (base.add(0x10000 + 4 * i) as *mut u32).write_unaligned(*word) };
        }
        let mut seen = 0u32;
        let hooks = Hooks { user: &mut seen as *mut u32 as *mut c_void, svc, fallback, exception, mapped, fault, counter };
        let monitor = Monitor::new(1);
        let mut cpu = Cpu::new(hooks, base, 36, &monitor, 0);
        cpu.set_pc(0x10000);
        let start = std::time::Instant::now();
        cpu.run(4 * (0x200 << 16) + 16);
        let seconds = start.elapsed().as_secs_f64();
        assert_eq!(seen, 42);
        assert_eq!(cpu.reg(0), 0);
        let n: u64 = 0x200 << 16;
        assert_eq!(cpu.reg(1), n * (n + 1) / 2);
        eprintln!("{:.0} M instructions/s", 4.0 * n as f64 / seconds / 1e6);
    }
}
