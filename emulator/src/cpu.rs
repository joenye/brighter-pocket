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
    fn pocket_cpu_invalidate(cpu: *mut RawCpu, start: u64, length: u64);
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

/// A handle that can stop a `Cpu`, or drop its translated code for a range, from another thread.
#[derive(Clone, Copy)]
pub struct Halter(*mut RawCpu);
unsafe impl Send for Halter {}
unsafe impl Sync for Halter {}
impl Halter {
    pub fn halt(&self) {
        unsafe { pocket_cpu_halt(self.0) }
    }
    /// The code at [start, start + length) is translated again from memory before it runs next.
    pub fn invalidate(&self, start: u64, length: u64) {
        unsafe { pocket_cpu_invalidate(self.0, start, length) }
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
        unsafe { *(user as *mut u32) |= immediate };
    }
    extern "C" fn fallback(user: *mut c_void, pc: u64) {
        unsafe { *(user as *mut u32) |= 0x1000_0000 | pc as u32 };
    }
    extern "C" fn exception(user: *mut c_void, _: u64, kind: u32) {
        unsafe { *(user as *mut u32) |= 0x2000_0000 | kind };
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
        let base = guest_memory();
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

    /// A reservation like src/memory.rs's, with [0x10000, 0x20000) readable and writable.
    fn guest_memory() -> *mut u8 {
        let size = 1usize << 36;
        let base = unsafe {
            libc::mmap(std::ptr::null_mut(), size, libc::PROT_NONE, libc::MAP_PRIVATE | libc::MAP_ANONYMOUS | libc::MAP_NORESERVE, -1, 0)
        } as *mut u8;
        unsafe { libc::mprotect(base.add(0x10000) as *mut c_void, 0x10000, libc::PROT_READ | libc::PROT_WRITE) };
        base
    }

    /// The instructions dynarmic's arm64 backend had no emitter for until
    /// emulator/dynarmic-patches/0002 and 0003: each runs through the JIT and on this Mac's own
    /// CPU, from the same v0, v1 and v2, and v2 must agree. The encoding is the assembler's, read
    /// back from a naked function holding the instruction.
    #[test]
    fn patched_emitters_agree_with_the_host() {
        use core::arch::aarch64::uint64x2_t;
        macro_rules! cases {
            ($($insn:literal),* $(,)?) => {{
                let mut cases: Vec<(&str, u32, fn([u64; 2], [u64; 2], [u64; 2]) -> [u64; 2])> = Vec::new();
                $({
                    #[unsafe(naked)]
                    extern "C" fn encoded() {
                        core::arch::naked_asm!($insn, "ret")
                    }
                    fn native(a: [u64; 2], b: [u64; 2], c: [u64; 2]) -> [u64; 2] {
                        let (a, b, mut c): (uint64x2_t, uint64x2_t, uint64x2_t) =
                            unsafe { (std::mem::transmute(a), std::mem::transmute(b), std::mem::transmute(c)) };
                        unsafe { core::arch::asm!($insn, in("v0") a, in("v1") b, inout("v2") c, options(nomem, nostack)) };
                        unsafe { std::mem::transmute(c) }
                    }
                    cases.push(($insn, unsafe { *(encoded as *const u32) }, native));
                })*
                cases
            }};
        }
        let cases = cases!(
            "cmhi v2.2d, v0.2d, v1.2d",
            "cmhs v2.2d, v0.2d, v1.2d",
            "cmhi d2, d0, d1",
            "cmhs d2, d0, d1",
            "cmgt v2.2d, v0.2d, v1.2d",
            "cmge v2.2d, v0.2d, v1.2d",
            "sqadd b2, b0, b1",
            "sqadd h2, h0, h1",
            "sqadd s2, s0, s1",
            "sqadd d2, d0, d1",
            "uqadd b2, b0, b1",
            "uqadd d2, d0, d1",
            "sqsub h2, h0, h1",
            "sqsub d2, d0, d1",
            "uqsub s2, s0, s1",
            "uqsub d2, d0, d1",
            "sqdmulh h2, h0, h1",
            "sqdmulh s2, s0, s1",
            "fabs h2, h0",
            "fneg h2, h0",
            "fmadd h2, h0, h1, h1",
            "fmsub h2, h1, h0, h0",
            "frintn h2, h0",
            "frintp h2, h0",
            "frintm h2, h0",
            "frintz h2, h0",
            "frinta h2, h0",
            "frintx h2, h0",
            "frecpe h2, h0",
            "frecpx h2, h0",
            "frecps h2, h0, h1",
            "frsqrte h2, h0",
            "frsqrts h2, h0, h1",
            "fneg v2.8h, v0.8h",
            "fcmeq v2.8h, v0.8h, v1.8h",
            "fmla v2.8h, v0.8h, v1.8h",
            "frecpe v2.8h, v0.8h",
            "frecps v2.8h, v0.8h, v1.8h",
            "frsqrte v2.8h, v0.8h",
            "frsqrts v2.8h, v0.8h, v1.8h",
        );
        let values: [[u64; 2]; 7] = [
            [0, 0],
            [1, u64::MAX],
            [0x7fff_ffff_ffff_ffff, 0x8000_0000_0000_0000],
            [0x8000_8000_8000_8080, 0x7fff_7fff_7fff_7f7f],
            [0x0123_4567_89ab_cdef, 0xfedc_ba98_7654_3210],
            [0xffff_ffff_ffff_ff80, 0x0000_0000_0000_007f],
            [0x3c00_c000_3555_7bff, 0x0001_7e00_4248_bc00], // halves: 1, -2, 0.333, max; subnormal, NaN, 3.14, -1
        ];

        let base = guest_memory();
        let mut seen = 0u32;
        let hooks = Hooks { user: &mut seen as *mut u32 as *mut c_void, svc, fallback, exception, mapped, fault, counter };
        let monitor = Monitor::new(1);
        let mut cpu = Cpu::new(hooks, base, 36, &monitor, 0);
        for (i, &(insn, word, native)) in cases.iter().enumerate() {
            let at = 0x10000 + 16 * i as u64;
            for (j, w) in [word, 0xd4000021 /* svc #1 */, 0x14000000 /* b . */].iter().enumerate() {
                unsafe { (base.add(at as usize + 4 * j) as *mut u32).write_unaligned(*w) };
            }
            for a in values {
                for b in values {
                    let c = [0x3c00_4000_3555_c000, 0x5555];
                    cpu.set_vector(0, a[0], a[1]);
                    cpu.set_vector(1, b[0], b[1]);
                    cpu.set_vector(2, c[0], c[1]);
                    cpu.set_pc(at);
                    seen = 0;
                    cpu.run(3);
                    assert_eq!(seen, 1, "{insn} did not run to the svc after it ({seen:#x})");
                    assert_eq!(cpu.vector(2), native(a, b, c), "{insn} with {a:x?} and {b:x?}");
                }
            }
        }
    }

    /// An instruction dynarmic does not decode (LDADD) ends the block with an Interpret terminal:
    /// the instructions before it have run and their registers are stored, and the fallback is
    /// called with its address (emulator/dynarmic-patches/0001).
    #[test]
    fn an_undecoded_instruction_reaches_the_fallback() {
        let base = guest_memory();
        let code: [u32; 3] = [
            0x91001ca5, // add x5, x5, #7
            0xf8200022, // ldadd x0, x2, [x1]
            0x14000000, // b .
        ];
        for (i, word) in code.iter().enumerate() {
            unsafe { (base.add(0x10000 + 4 * i) as *mut u32).write_unaligned(*word) };
        }
        let mut seen = 0u32;
        let hooks = Hooks { user: &mut seen as *mut u32 as *mut c_void, svc, fallback, exception, mapped, fault, counter };
        let monitor = Monitor::new(1);
        let mut cpu = Cpu::new(hooks, base, 36, &monitor, 0);
        cpu.set_pc(0x10000);
        cpu.run(1000);
        assert_eq!(seen, 0x1001_0004, "the fallback is called for the LDADD at 0x10004");
        assert_eq!(cpu.reg(5), 7);
        assert_eq!(cpu.pc(), 0x10004);
    }
}
