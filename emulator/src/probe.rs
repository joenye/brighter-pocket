//! Probes into the client's own code, read only, for debugging the layer's answers: what runs,
//! when, with what. Written to a file under build/, never the report: probed buffers can hold a session's
//! secrets (a Steam ticket).
//!
//! --coverage FILE: the first call of every function the client has (LC_FUNCTION_STARTS), in
//! order, with the frame and the thread. Each function's first instruction becomes an svc; its
//! first call logs it, puts the instruction back and drops the translated code on every CPU, so
//! the function runs at full speed from then on.
//! --probe ADDR[:DUMP,...]: every time the instruction at client+ADDR runs, x0 to x7 and the
//! named memory: `xN+xM` (xM bytes at xN, at most 4 KiB), `xN:LEN` (LEN bytes at xN), `xN@OFF:LEN`
//! (LEN bytes at xN+OFF), `*xN+OFF:LEN` (LEN bytes at the pointer stored at xN+OFF). The
//! instruction runs from a copy beside a branch back, so it must not be PC-relative.
use std::collections::HashMap;
use std::fs::File;
use std::io::{BufWriter, Write};
use std::sync::Mutex;

use crate::cpu::Cpu;
use crate::machine::{CLIENT_BASE, Machine};

/// The svc immediate a probe's instruction becomes (answered imports use the low ids).
pub const PROBE_SVC: u32 = 0xFFFE;

enum Dump {
    Span { pointer: u32, length: u32 },
    Fixed { pointer: u32, offset: u64, length: u64 },
    Indirect { pointer: u32, offset: u64, length: u64 },
}

struct Probe {
    original: u32,
    /// For --probe: the original instruction at `trampoline`, then a branch back.
    persistent: Option<(u64, Vec<Dump>)>,
}

#[derive(Default)]
pub struct Probes {
    table: Mutex<HashMap<u64, Probe>>,
    log: Mutex<Option<BufWriter<File>>>,
}

fn svc_word() -> u32 {
    0xD400_0001 | (PROBE_SVC << 5)
}

fn pc_relative(word: u32) -> bool {
    word & 0x1F00_0000 == 0x1000_0000 // adr, adrp
        || word & 0x7C00_0000 == 0x1400_0000 // b, bl
        || word & 0xFF00_0010 == 0x5400_0000 // b.cond
        || word & 0x7E00_0000 == 0x3400_0000 // cbz, cbnz
        || word & 0x7E00_0000 == 0x3600_0000 // tbz, tbnz
        || word & 0x3B00_0000 == 0x1800_0000 // ldr (literal)
}

fn parse_dump(spec: &str) -> Result<Dump, String> {
    let reg = |s: &str| s.strip_prefix('x').and_then(|n| n.parse::<u32>().ok()).filter(|&n| n < 31).ok_or(format!("{spec}: no register in {s}"));
    if let Some(rest) = spec.strip_prefix('*') {
        let (place, length) = rest.split_once(':').ok_or(format!("{spec}: *xN+OFF:LEN"))?;
        let (pointer, offset) = place.split_once('+').unwrap_or((place, "0"));
        let offset = parse_number(offset)?;
        return Ok(Dump::Indirect { pointer: reg(pointer)?, offset, length: parse_number(length)? });
    }
    if let Some((pointer, length)) = spec.split_once('+') {
        return Ok(Dump::Span { pointer: reg(pointer)?, length: reg(length)? });
    }
    let (place, length) = spec.split_once(':').ok_or(format!("{spec}: xN+xM, xN:LEN, xN@OFF:LEN or *xN+OFF:LEN"))?;
    let (pointer, offset) = place.split_once('@').unwrap_or((place, "0"));
    Ok(Dump::Fixed { pointer: reg(pointer)?, offset: parse_number(offset)?, length: parse_number(length)? })
}

fn parse_number(text: &str) -> Result<u64, String> {
    let parsed = match text.strip_prefix("0x") {
        Some(hex) => u64::from_str_radix(hex, 16),
        None => text.parse(),
    };
    parsed.map_err(|_| format!("{text} is not a number"))
}

/// Patch the client for --coverage and --probe (after loading, before anything runs).
pub fn install(m: &Machine, client: &crate::macho::Image) -> Result<(), String> {
    let options = &m.options;
    if options.coverage.is_none() && options.probes.is_empty() {
        return Ok(());
    }
    let path = options.coverage.clone().or(options.probe_log.clone()).ok_or("--probe needs --probe-log FILE")?;
    let file = File::create(&path).map_err(|e| format!("{}: {e}", path.display()))?;
    let probes = m.probes.get_or_init(Probes::default);
    *probes.log.lock().unwrap() = Some(BufWriter::new(file));
    let mut table = probes.table.lock().unwrap();
    let text = client.section("__TEXT", "__text").ok_or("the client has no __text")?;
    if options.coverage.is_some() {
        for start in client.function_starts() {
            if (text.addr..text.addr + text.size).contains(&start) {
                let original = m.memory.u32(start);
                table.insert(start, Probe { original, persistent: None });
                m.memory.set_u32(start, svc_word());
            }
        }
    }
    // Trampolines go in a page just past the client, within a branch's reach (128 MiB) of its code.
    let client_end = client.segments.iter().map(|s| s.vmaddr + s.vmsize).max().unwrap_or(text.addr + text.size);
    let mut next_trampoline = crate::memory::align(client_end, crate::memory::PAGE) + crate::memory::PAGE;
    if !options.probes.is_empty() {
        m.memory.map(next_trampoline, crate::memory::PAGE);
    }
    for spec in &options.probes {
        let (address, dumps) = spec.split_once(':').unwrap_or((spec, ""));
        let offset = u64::from_str_radix(address.trim_start_matches("0x"), 16).map_err(|_| format!("--probe {spec}: {address} is not a hex address"))?;
        let address = CLIENT_BASE + offset;
        if !(text.addr..text.addr + text.size).contains(&address) || address % 4 != 0 {
            return Err(format!("--probe {spec}: not an instruction of the client"));
        }
        let original = m.memory.u32(address);
        if pc_relative(original) {
            return Err(format!("--probe {spec}: the instruction there ({original:#010x}) is PC-relative"));
        }
        let dumps = dumps.split(',').filter(|d| !d.is_empty()).map(parse_dump).collect::<Result<Vec<_>, _>>()?;
        let trampoline = next_trampoline;
        next_trampoline += 8;
        if trampoline + 8 - text.addr > 0x800_0000 {
            return Err(format!("--probe {spec}: no room for its trampoline within a branch's reach"));
        }
        m.memory.set_u32(trampoline, original);
        let back = ((address + 4).wrapping_sub(trampoline + 4) as i64 / 4) as u32 & 0x03FF_FFFF;
        m.memory.set_u32(trampoline + 4, 0x1400_0000 | back);
        table.insert(address, Probe { original, persistent: Some((trampoline, dumps)) });
        m.memory.set_u32(address, svc_word());
    }
    Ok(())
}

/// A probe's svc: log, then run on (the CPU halts, and runs on from its new PC).
pub fn hit(m: &Machine, cpu: &mut Cpu, thread: u32) {
    let address = cpu.pc() - 4;
    let Some(probes) = m.probes.get() else {
        m.stop(format!("a probe svc at {} with no probes installed", m.where_(address)));
        return;
    };
    let frame = m.frames.load(std::sync::atomic::Ordering::Relaxed);
    let mut table = probes.table.lock().unwrap();
    let mut line = format!("{frame} {thread} {:#x}", address - CLIENT_BASE);
    let resume = match table.get(&address) {
        None => {
            // A coverage probe another CPU already put back: this CPU still has the svc translated.
            drop(table);
            cpu.halter().invalidate(address, 4);
            address
        }
        Some(Probe { persistent: Some((trampoline, dumps)), .. }) => {
            for i in 0..8 {
                line += &format!(" x{i}={:#x}", cpu.reg(i));
            }
            for dump in dumps {
                let (start, length) = match *dump {
                    Dump::Span { pointer, length } => (cpu.reg(pointer), cpu.reg(length)),
                    Dump::Fixed { pointer, offset, length } => (cpu.reg(pointer).wrapping_add(offset), length),
                    Dump::Indirect { pointer, offset, length } => {
                        let at = cpu.reg(pointer).wrapping_add(offset);
                        (if m.memory.is_mapped(at, 8) { m.memory.u64(at) } else { 0 }, length)
                    }
                };
                let length = length.min(4096);
                if m.memory.is_mapped(start, length.max(1)) {
                    line += &format!(" [{start:#x}:{}]", hex(&m.memory.read(start, length as usize)));
                } else {
                    line += &format!(" [{start:#x}: unmapped]");
                }
            }
            *trampoline
        }
        Some(Probe { original, persistent: None }) => {
            let original = *original;
            table.remove(&address);
            drop(table);
            m.memory.set_u32(address, original);
            m.runtime.invalidate_all(address, 4);
            cpu.halter().invalidate(address, 4);
            address
        }
    };
    if let Some(log) = probes.log.lock().unwrap().as_mut() {
        let _ = writeln!(log, "{line}");
    }
    cpu.set_pc(resume);
    cpu.halt();
}

/// Flush the log (after the run).
pub fn finish(m: &Machine) {
    if let Some(probes) = m.probes.get() {
        if let Some(log) = probes.log.lock().unwrap().as_mut() {
            let _ = log.flush();
        }
    }
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tells_pc_relative_instructions_and_reads_dump_specs() {
        assert!(pc_relative(0x9000_0008)); // adrp x8, ...
        assert!(pc_relative(0x9400_0010)); // bl
        assert!(pc_relative(0xB400_0040)); // cbz x0
        assert!(!pc_relative(0xA9BF_7BFD)); // stp x29, x30, [sp, #-16]!
        assert!(!pc_relative(0xD100_83FF)); // sub sp, sp, #0x20
        assert!(matches!(parse_dump("x1+x2"), Ok(Dump::Span { pointer: 1, length: 2 })));
        assert!(matches!(parse_dump("x0:0x40"), Ok(Dump::Fixed { pointer: 0, offset: 0, length: 64 })));
        assert!(matches!(parse_dump("x21@0x24050:16"), Ok(Dump::Fixed { pointer: 21, offset: 0x24050, length: 16 })));
        assert!(matches!(parse_dump("*x19+0x80:16"), Ok(Dump::Indirect { pointer: 19, offset: 0x80, length: 16 })));
        assert!(parse_dump("y1:4").is_err());
    }
}
