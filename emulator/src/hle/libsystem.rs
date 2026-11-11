//! libSystem's process, environment, string, formatting and maths answers, dl*, libc++'s
//! strings, audio output and Core Graphics displays as Tolkara's adapters answer them, and the
//! app's Steam session as the Steam library finds it with dlsym.
use std::sync::{Arc, Mutex};

use super::{Ctx, Registry, Stop};
use crate::machine::Machine;
use crate::steam::LiveSession;

const ENOENT: i32 = 2;
/// Public individual account 1.
const PLACEHOLDER_STEAM_ID: u64 = 0x0110_0001_0000_0001;
const TICKET_SIZE: u64 = 2560;

#[derive(Default)]
struct Sys {
    atexit: Vec<(u64, u64)>,
    bridge_table: u64,
    tickets: Vec<String>,
    audio: Vec<String>,
    live: Option<Arc<LiveSession>>,
}

fn state(m: &Machine) -> Arc<Mutex<Sys>> {
    m.state::<Sys>()
}

pub fn register(r: &mut Registry) {
    register_process(r);
    register_steam(r);
    register_strings(r);
    register_output(r);
    register_maths(r);
    register_devices(r);
    register_cxx(r);
    register_data(r);
}

// --- process -------------------------------------------------------------------------------
fn register_process(r: &mut Registry) {
    r.answer(&["_exit", "__exit"], |c| Err(Stop(format!("exit({})", c.arg32(0)))));
    r.answer(&["_abort", "___stack_chk_fail"], |_| Err(Stop("abort".into())));
    r.answer(&["___cxa_atexit"], |c| {
        state(c.m).lock().unwrap().atexit.push((c.arg(0), c.arg(1)));
        Ok(Some(0))
    });
    // A stack probe; the emulated stack is mapped whole.
    r.answer(&["___chkstk_darwin", "_srandomdev", "_dispatch_release"], |_| Ok(None));
    r.answer(&["___error"], |c| Ok(Some(c.thread.errno)));
    // An iOS app's HOME is its container; nothing else is set for the client.
    r.answer(&["_getenv"], |c| Ok(Some(if c.cstring(c.arg(0)) == "HOME" { c.new_cstring(super::files::CONTAINER) } else { 0 })));
    r.answer(&["_getpid"], |_| Ok(Some(4242)));
    r.answer(&["_geteuid"], |_| Ok(Some(501)));
    r.answer(&["_sysctlbyname"], |c| {
        let (name, out, size) = (c.cstring(c.arg(0)), c.arg(1), c.arg(2));
        let value: u64 = match name.as_str() {
            "hw.ncpu" | "hw.physicalcpu" | "hw.logicalcpu" => 8,
            "hw.memsize" => 8 << 30,
            _ => {
                c.set_errno(ENOENT);
                return Ok(Some(0xFFFF_FFFF));
            }
        };
        let length = if size != 0 { c.mem().u64(size) } else { 8 };
        if out != 0 {
            c.mem().write(out, &value.to_le_bytes()[..length.min(8) as usize]);
        }
        Ok(Some(0))
    });
    r.answer(&["_sysconf"], |c| {
        Ok(Some(match c.arg32(0) {
            29 => 16384,
            57 | 58 => 8,
            _ => 0,
        }))
    });
    r.answer(&["_confstr"], |c| {
        let value = b"/private/var/mobile/tmp/\0";
        if c.arg(1) != 0 && c.arg(2) != 0 {
            c.mem().write(c.arg(1), &value[..value.len().min(c.arg(2) as usize)]);
        }
        Ok(Some(value.len() as u64))
    });
    r.answer(&["_gethostuuid"], |c| {
        c.mem().fill(c.arg(0), 0, 16);
        Ok(Some(0))
    });
    r.answer(&["_random"], |_| Ok(Some(12345)));
    // Security's random bytes (the client's own, for its sign-in): the host's, as the device's
    // are the system's. errSecSuccess.
    r.answer(&["_SecRandomCopyBytes"], |c| {
        use std::io::Read;
        let mut bytes = vec![0u8; c.arg(1) as usize];
        std::fs::File::open("/dev/urandom").and_then(|mut f| f.read_exact(&mut bytes)).map_err(|e| Stop(format!("no host random bytes: {e}")))?;
        c.mem().write(c.arg(2), &bytes);
        Ok(Some(0))
    });
    r.answer(&["_atoi"], |c| Ok(Some(atoi(&c.cstring(c.arg(0))))));
    // The client's own dlopen and dlsym are the loader's on the device (they find nothing it
    // does not carry); an adapter's are the system's, which find the system's functions.
    r.answer(&["_dlopen"], |c| Ok(Some(if from_adapter(c) { c.alloc(16) } else { 0 })));
    r.answer(&["_dlsym"], |c| {
        Ok(Some(if from_adapter(c) { c.m.slot_address(&format!("_{}", c.cstring(c.arg(1)))) } else { 0 }))
    });
    r.answer(&["_dlclose", "_dlerror"], |_| Ok(Some(0)));
    r.answer(&["_localtime"], |c| {
        let time = c.mem().u64(c.arg(0)) as libc::time_t;
        // SAFETY: localtime_r writes only the tm it is given.
        let t = unsafe {
            let mut t: libc::tm = std::mem::zeroed();
            libc::localtime_r(&time, &mut t);
            t
        };
        let tm = c.alloc(64);
        for (i, v) in [t.tm_sec, t.tm_min, t.tm_hour, t.tm_mday, t.tm_mon, t.tm_year, t.tm_wday, t.tm_yday, t.tm_isdst].iter().enumerate() {
            c.mem().set_i32(tm + 4 * i as u64, *v);
        }
        Ok(Some(tm))
    });
}

/// Python's int() of the first word, as hle.py reads it: "12abc" is no number.
fn atoi(text: &str) -> u64 {
    text.split_whitespace().next().and_then(|word| word.parse::<i128>().ok()).map_or(0, |v| v as u64 & 0xFFFF_FFFF)
}

fn from_adapter(c: &Ctx) -> bool {
    let lr = c.lr();
    c.m.images.get().into_iter().flatten().any(|image| image.name != "client" && (image.start..image.end).contains(&lr))
}

// --- the app's Steam session ----------------------------------------------------------------
// PocketSteamBridge.h's table, as the Steam library finds it with dlsym. Signed in as a
// placeholder account unless --offline (the player chose to play offline), and its tickets
// placeholders, which no server accepts; with --steam-live, the real account and real tickets
// from a live session (src/steam.rs). A ticket is handed to the library's callback at once, on
// the caller's thread.
fn register_steam(r: &mut Registry) {
    r.answer(&["_PocketSteamBridgeGet"], |c| {
        let sys = state(c.m);
        let mut sys = sys.lock().unwrap();
        if sys.bridge_table == 0 {
            let table = c.alloc(32);
            c.mem().set_u32(table, 1);
            for (i, name) in ["account", "web_ticket", "cancel_ticket"].iter().enumerate() {
                c.mem().set_u64(table + 8 + 8 * i as u64, c.m.slot_address(&format!("bridge.{name}")));
            }
            sys.bridge_table = table;
        }
        Ok(Some(sys.bridge_table))
    });
    r.answer(&["bridge.account"], |c| {
        if c.m.options.offline {
            return Ok(Some(0));
        }
        let live = state(c.m).lock().unwrap().live.clone();
        if c.arg(0) != 0 {
            c.mem().set_u64(c.arg(0), live.as_ref().map_or(PLACEHOLDER_STEAM_ID, |l| l.steam_id()));
        }
        if c.arg(1) != 0 && c.arg(2) != 0 {
            let name = live.as_ref().map_or_else(|| "Emulated player".to_string(), |l| l.persona());
            let name = &name.as_bytes()[..name.len().min(c.arg(2) as usize - 1)];
            c.mem().write(c.arg(1), name);
            c.mem().set_u8(c.arg(1) + name.len() as u64, 0);
        }
        Ok(Some(1))
    });
    r.answer(&["bridge.web_ticket"], |c| {
        let (identity, done, context) = (c.cstring(c.arg(0)), c.arg(1), c.arg(2));
        let frames = c.m.frames.load(std::sync::atomic::Ordering::Relaxed);
        let live = {
            let sys = state(c.m);
            let mut sys = sys.lock().unwrap();
            sys.tickets.push(format!("{identity} (frame {frames})"));
            sys.live.clone()
        };
        let made = match live {
            Some(live) => live.web_ticket(&identity),
            None => Some((b"BRIGHTER-POCKET-EMULATED-TICKET.".repeat(80)[..TICKET_SIZE as usize].to_vec(), 0x0E0E_0E0E)),
        };
        let ticket = c.alloc(TICKET_SIZE);
        // done(context, result, ticket, size, crc), returning to the library's own caller.
        let values = match made {
            Some((bytes, crc)) => {
                c.mem().write(ticket, &bytes[..bytes.len().min(TICKET_SIZE as usize)]);
                [context, 1, ticket, TICKET_SIZE, crc as u64]
            }
            None => [context, 3, 0, 0, 0],
        };
        for (n, value) in values.iter().enumerate() {
            c.set(n as u32, *value);
        }
        c.jump(done);
        Ok(None)
    });
    r.answer(&["bridge.cancel_ticket"], |_| Ok(None));
    // The offline Steam library's own log.
    r.answer(&["_AKLogC"], |c| {
        let data = format_string(c.m, &c.mem().cbytes(c.arg(0)), c.cpu.sp());
        c.m.report.steam(format!("log: {}", String::from_utf8_lossy(&data).trim_end()));
        Ok(None)
    });
}

// --- strings -------------------------------------------------------------------------------
fn compare(a: &[u8], b: &[u8]) -> u64 {
    match a.cmp(b) {
        std::cmp::Ordering::Equal => 0,
        std::cmp::Ordering::Greater => 1,
        std::cmp::Ordering::Less => 0xFFFF_FFFF,
    }
}

fn register_strings(r: &mut Registry) {
    r.answer(&["_strcasecmp"], |c| {
        let (a, b) = (c.mem().cbytes(c.arg(0)).to_ascii_lowercase(), c.mem().cbytes(c.arg(1)).to_ascii_lowercase());
        Ok(Some(compare(&a, &b)))
    });
    r.answer(&["_strlen"], |c| Ok(Some(c.mem().cbytes(c.arg(0)).len() as u64)));
    r.answer(&["_strcmp"], |c| Ok(Some(compare(&c.mem().cbytes(c.arg(0)), &c.mem().cbytes(c.arg(1))))));
    r.answer(&["_strncmp"], |c| {
        let n = c.arg(2) as usize;
        let (a, b) = (c.mem().cbytes(c.arg(0)), c.mem().cbytes(c.arg(1)));
        Ok(Some(compare(&a[..a.len().min(n)], &b[..b.len().min(n)])))
    });
    r.answer(&["_strrchr"], |c| {
        let s = c.mem().cbytes(c.arg(0));
        Ok(Some(s.iter().rposition(|&b| b == c.arg(1) as u8).map_or(0, |at| c.arg(0) + at as u64)))
    });
    r.answer(&["_strcspn"], |c| {
        let (s, reject) = (c.mem().cbytes(c.arg(0)), c.mem().cbytes(c.arg(1)));
        Ok(Some(s.iter().position(|b| reject.contains(b)).unwrap_or(s.len()) as u64))
    });
    r.answer(&["_strspn"], |c| {
        let (s, accept) = (c.mem().cbytes(c.arg(0)), c.mem().cbytes(c.arg(1)));
        Ok(Some(s.iter().position(|b| !accept.contains(b)).unwrap_or(s.len()) as u64))
    });
    r.answer(&["___strlcpy_chk"], |c| {
        let (s, size) = (c.mem().cbytes(c.arg(1)), c.arg(2) as usize);
        if size != 0 {
            put_cstring(c, c.arg(0), &s[..s.len().min(size - 1)]);
        }
        Ok(Some(s.len() as u64))
    });
    r.answer(&["___strlcat_chk"], |c| {
        let (d, s, size) = (c.mem().cbytes(c.arg(0)), c.mem().cbytes(c.arg(1)), c.arg(2) as usize);
        let total = d.len() + s.len();
        let mut joined = [d.as_slice(), s.as_slice()].concat();
        joined.truncate(size.saturating_sub(1).max(d.len()));
        put_cstring(c, c.arg(0), &joined);
        Ok(Some(total as u64))
    });
    r.answer(&["_inet_pton"], |c| {
        let text = c.cstring(c.arg(1));
        let Ok(address) = text.parse::<std::net::IpAddr>() else { return Ok(Some(0)) };
        match (address, c.arg32(0)) {
            (std::net::IpAddr::V4(v4), 2) => c.mem().write(c.arg(2), &v4.octets()),
            (std::net::IpAddr::V6(v6), family) if family != 2 => c.mem().write(c.arg(2), &v6.octets()),
            _ => return Ok(Some(0)),
        }
        Ok(Some(1))
    });
    r.answer(&["_inet_ntop"], |c| {
        let (family, size) = (c.arg32(0), c.arg(3) as usize);
        let text = if family == 2 {
            let raw: [u8; 4] = c.mem().read(c.arg(1), 4).try_into().expect("4 bytes");
            std::net::Ipv4Addr::from(raw).to_string()
        } else {
            let raw: [u8; 16] = c.mem().read(c.arg(1), 16).try_into().expect("16 bytes");
            std::net::Ipv6Addr::from(raw).to_string()
        };
        let mut bytes = text.into_bytes();
        bytes.push(0);
        c.mem().write(c.arg(2), &bytes[..bytes.len().min(size)]);
        Ok(Some(c.arg(2)))
    });
}

fn put_cstring(c: &Ctx, address: u64, bytes: &[u8]) {
    c.mem().write(address, bytes);
    c.mem().set_u8(address + bytes.len() as u64, 0);
}

// --- formatted output ----------------------------------------------------------------------
fn register_output(r: &mut Registry) {
    r.answer(&["_snprintf"], |c| {
        let data = format_string(c.m, &c.mem().cbytes(c.arg(2)), c.cpu.sp());
        Ok(Some(bounded(c, c.arg(0), c.arg(1), &data)))
    });
    r.answer(&["_vsnprintf"], |c| {
        let data = format_string(c.m, &c.mem().cbytes(c.arg(2)), c.arg(3));
        Ok(Some(bounded(c, c.arg(0), c.arg(1), &data)))
    });
    r.answer(&["_printf"], |c| {
        let data = format_string(c.m, &c.mem().cbytes(c.arg(0)), c.cpu.sp());
        c.console(String::from_utf8_lossy(&data).into_owned());
        Ok(Some(data.len() as u64))
    });
    r.answer(&["_fprintf"], |c| {
        let data = format_string(c.m, &c.mem().cbytes(c.arg(1)), c.cpu.sp());
        c.console(String::from_utf8_lossy(&data).into_owned());
        Ok(Some(data.len() as u64))
    });
    r.answer(&["_fputs"], |c| {
        c.console(c.cstring(c.arg(0)));
        Ok(Some(1))
    });
    r.answer(&["_fflush"], |_| Ok(Some(0)));
    r.answer(&["_NSLog"], |c| {
        let format = describe(c.m, c.arg(0));
        let data = format_string(c.m, format.as_bytes(), c.cpu.sp());
        c.console(format!("NSLog: {}", String::from_utf8_lossy(&data)));
        Ok(None)
    });
}

/// snprintf's copy: at most size - 1 bytes and the NUL; the whole length returned.
fn bounded(c: &Ctx, to: u64, size: u64, data: &[u8]) -> u64 {
    if size != 0 {
        put_cstring(c, to, &data[..data.len().min(size as usize - 1)]);
    }
    data.len() as u64
}

/// An object as %@ shows it: a string's text, else what it is.
fn describe(m: &Machine, object: u64) -> String {
    if object == 0 {
        return "(null)".into();
    }
    super::objc::string_value(m, object).unwrap_or_else(|| format!("<object {object:#x}>"))
}

/// printf's formatting, as Apple's arm64 passes variadic arguments: every argument in its own
/// 8-byte slot from `slots` on (the stack for printf, the va_list for vprintf), doubles too.
/// %@ formats an object through objc::string_value.
pub fn format_string(m: &Machine, format: &[u8], slots: u64) -> Vec<u8> {
    let mut at = slots;
    let next = || {
        let value = m.memory.u64(at);
        at += 8;
        value
    };
    format_with(format, next, |s| m.memory.cbytes(s), |o| describe(m, o))
}

/// The formatter itself, over any source of argument slots, C strings and objects.
fn format_with(format: &[u8], mut next: impl FnMut() -> u64, cstring: impl Fn(u64) -> Vec<u8>, describe: impl Fn(u64) -> String) -> Vec<u8> {
    let mut out = Vec::new();
    let mut i = 0;
    while i < format.len() {
        if format[i] != b'%' {
            out.push(format[i]);
            i += 1;
            continue;
        }
        let mut j = i + 1;
        while j < format.len() && b"-+ #0123456789.*hlqjzt".contains(&format[j]) {
            j += 1;
        }
        if j >= format.len() {
            break;
        }
        let (spec, conv) = (&format[i + 1..j], format[j]);
        i = j + 1;
        if conv == b'%' {
            out.push(b'%');
            continue;
        }
        let mut s = Spec::parse(spec, &mut next);
        let value = next();
        match conv {
            b's' => {
                let mut text = if value != 0 { cstring(value) } else { b"(null)".to_vec() };
                if let Some(p) = s.precision {
                    text.truncate(p);
                }
                s.zero = false;
                out.extend(s.pad(String::new(), "", text));
            }
            b'd' | b'i' => {
                let v = if s.long { value as i64 } else { value as i32 as i64 };
                let sign = if v < 0 { "-" } else { s.sign() };
                out.extend(s.integer(sign, "", v.unsigned_abs().to_string()));
            }
            b'u' | b'x' | b'X' | b'o' => {
                let v = if s.long { value } else { value & 0xFFFF_FFFF };
                let (digits, prefix) = match conv {
                    b'u' => (v.to_string(), ""),
                    b'x' => (format!("{v:x}"), if s.alternate && v != 0 { "0x" } else { "" }),
                    b'X' => (format!("{v:X}"), if s.alternate && v != 0 { "0X" } else { "" }),
                    _ => (format!("{v:o}"), if s.alternate && v != 0 { "0" } else { "" }),
                };
                out.extend(s.integer("", prefix, digits));
            }
            b'p' => out.extend(format!("0x{value:x}").into_bytes()),
            b'c' => out.push(value as u8),
            b'f' | b'e' | b'E' | b'g' | b'G' | b'a' | b'A' => {
                let v = f64::from_bits(value);
                let sign = if v.is_sign_negative() && !v.is_nan() { "-" } else { s.sign() };
                let mut body = float_body(v.abs(), conv.to_ascii_lowercase(), s.precision, s.alternate);
                if conv.is_ascii_uppercase() {
                    body = body.to_ascii_uppercase();
                }
                if !v.is_finite() {
                    s.zero = false;
                }
                out.extend(s.pad(sign.to_string(), "", body.into_bytes()));
            }
            b'@' => out.extend(describe(value).into_bytes()),
            _ => {
                out.push(b'%');
                out.extend_from_slice(spec);
                out.push(conv);
            }
        }
    }
    out
}

/// A conversion's flags, width, precision and length.
#[derive(Default, Clone, Copy)]
struct Spec {
    left: bool,
    plus: bool,
    space: bool,
    alternate: bool,
    zero: bool,
    width: usize,
    precision: Option<usize>,
    long: bool,
}

impl Spec {
    fn parse(spec: &[u8], next: &mut impl FnMut() -> u64) -> Spec {
        let mut s = Spec::default();
        let mut k = 0;
        while k < spec.len() && b"-+ #0".contains(&spec[k]) {
            match spec[k] {
                b'-' => s.left = true,
                b'+' => s.plus = true,
                b' ' => s.space = true,
                b'#' => s.alternate = true,
                _ => s.zero = true,
            }
            k += 1;
        }
        let mut number = |k: &mut usize| -> Option<i64> {
            if *k < spec.len() && spec[*k] == b'*' {
                *k += 1;
                return Some(next() as u32 as i32 as i64);
            }
            let start = *k;
            while *k < spec.len() && spec[*k].is_ascii_digit() {
                *k += 1;
            }
            std::str::from_utf8(&spec[start..*k]).ok().and_then(|t| t.parse().ok())
        };
        if let Some(width) = number(&mut k) {
            if width < 0 {
                s.left = true;
            }
            s.width = width.unsigned_abs() as usize;
        }
        if k < spec.len() && spec[k] == b'.' {
            k += 1;
            let precision = number(&mut k).unwrap_or(0);
            s.precision = (precision >= 0).then_some(precision as usize);
        }
        s.long = spec[k..].iter().any(|b| b"lqjzt".contains(b));
        s
    }

    fn sign(&self) -> &'static str {
        if self.plus {
            "+"
        } else if self.space {
            " "
        } else {
            ""
        }
    }

    fn integer(&self, sign: &str, prefix: &str, mut digits: String) -> Vec<u8> {
        if let Some(p) = self.precision {
            if p == 0 && digits == "0" {
                digits.clear();
            }
            if digits.len() < p {
                digits.insert_str(0, &"0".repeat(p - digits.len()));
            }
        }
        let prefix = if prefix == "0" && digits.starts_with('0') { "" } else { prefix };
        let zero = self.zero && self.precision.is_none();
        Spec { zero, ..*self }.pad(sign.to_string(), prefix, digits.into_bytes())
    }

    /// Sign and prefix, then the body, padded to the width.
    fn pad(&self, sign: String, prefix: &str, body: Vec<u8>) -> Vec<u8> {
        let length = sign.len() + prefix.len() + body.len();
        let fill = self.width.saturating_sub(length);
        let mut out = Vec::with_capacity(length + fill);
        if self.left {
            out.extend(sign.bytes().chain(prefix.bytes()).chain(body));
            out.extend(std::iter::repeat_n(b' ', fill));
        } else if self.zero {
            out.extend(sign.bytes().chain(prefix.bytes()));
            out.extend(std::iter::repeat_n(b'0', fill));
            out.extend(body);
        } else {
            out.extend(std::iter::repeat_n(b' ', fill));
            out.extend(sign.bytes().chain(prefix.bytes()).chain(body));
        }
        out
    }
}

/// A non-negative double as %f, %e, %g or %a show it (lower case).
fn float_body(v: f64, conv: u8, precision: Option<usize>, alternate: bool) -> String {
    if v.is_nan() {
        return "nan".into();
    }
    if v.is_infinite() {
        return "inf".into();
    }
    let p = precision.unwrap_or(6);
    let dot = |mut text: String| {
        if alternate && !text.contains('.') {
            text.push('.');
        }
        text
    };
    match conv {
        b'f' => dot(format!("{v:.p$}")),
        b'e' => exponent_form(v, p, alternate),
        b'g' => {
            let p = if p == 0 { 1 } else { p };
            let x = if v == 0.0 { 0 } else { exponent_form(v, p - 1, false).rsplit_once('e').map_or(0, |(_, e)| e.parse::<i64>().unwrap_or(0)) };
            let text = if (p as i64) > x && x >= -4 {
                dot(format!("{v:.prec$}", prec = (p as i64 - 1 - x) as usize))
            } else {
                exponent_form(v, p - 1, alternate)
            };
            if alternate {
                return text;
            }
            let (mantissa, exponent) = match text.find('e') {
                Some(at) => (&text[..at], &text[at..]),
                None => (text.as_str(), ""),
            };
            let mantissa = if mantissa.contains('.') { mantissa.trim_end_matches('0').trim_end_matches('.') } else { mantissa };
            format!("{mantissa}{exponent}")
        }
        _ => hex_float(v),
    }
}

/// %e: d.ddde+XX (at least two exponent digits).
fn exponent_form(v: f64, p: usize, alternate: bool) -> String {
    let text = format!("{v:.p$e}");
    let (mantissa, exponent) = text.split_once('e').expect("Rust's e form has an exponent");
    let exponent: i64 = exponent.parse().expect("an exponent");
    let mut mantissa = mantissa.to_string();
    if alternate && !mantissa.contains('.') {
        mantissa.push('.');
    }
    format!("{mantissa}e{}{:02}", if exponent < 0 { '-' } else { '+' }, exponent.abs())
}

/// %a: the exact hexadecimal form.
fn hex_float(v: f64) -> String {
    if v == 0.0 {
        return "0x0p+0".into();
    }
    let bits = v.to_bits();
    let (exponent, fraction) = ((bits >> 52) & 0x7FF, bits & ((1 << 52) - 1));
    let (lead, exponent) = if exponent == 0 { (0, -1022) } else { (1, exponent as i64 - 1023) };
    let digits = format!("{fraction:013x}");
    let digits = digits.trim_end_matches('0');
    let point = if digits.is_empty() { "" } else { "." };
    format!("0x{lead}{point}{digits}p{}{}", if exponent < 0 { '-' } else { '+' }, exponent.abs())
}

// --- arithmetic and maths ------------------------------------------------------------------
fn register_maths(r: &mut Registry) {
    r.answer(&["___udivti3"], |c| {
        let a = c.arg(0) as u128 | (c.arg(1) as u128) << 64;
        let b = c.arg(2) as u128 | (c.arg(3) as u128) << 64;
        let q = a.checked_div(b).unwrap_or(0);
        c.set(1, (q >> 64) as u64);
        Ok(Some(q as u64))
    });
    r.answer(&["_cos"], |c| {
        let v = c.d(0).cos();
        c.set_d(0, v);
        Ok(None)
    });
    r.answer(&["_exp"], |c| {
        let v = c.d(0).exp();
        c.set_d(0, v);
        Ok(None)
    });
    r.answer(&["_fmodf"], |c| {
        let (a, b) = (c.s(0), c.s(1));
        c.set_s(0, if b != 0.0 { (a as f64 % b as f64) as f32 } else { f32::NAN });
        Ok(None)
    });
}

// --- audio output and displays, as Tolkara's adapters answer ---------------------------------
/// The screen in points, as translation/CoreGraphics/Displays.m has it: one display, number 1,
/// its size in millimetres at 132 points per inch.
const SCREEN_POINTS: (f64, f64) = (1366.0, 1024.0);

fn register_devices(r: &mut Registry) {
    // The default output unit (RemoteIO on the device) is found, made and started; nothing
    // renders here.
    r.answer(&["_AudioComponentFindNext"], |c| {
        let description = c.mem().read(c.arg(1), 20);
        let fourcc = |b: &[u8]| b.iter().rev().map(|&x| x as char).collect::<String>();
        let line = format!("find {}/{}", fourcc(&description[..4]), fourcc(&description[4..8]));
        state(c.m).lock().unwrap().audio.push(line);
        Ok(Some(c.alloc(32)))
    });
    r.answer(&["_AudioComponentInstanceNew"], |c| {
        let unit = c.alloc(64);
        c.mem().set_u64(c.arg(1), unit);
        Ok(Some(0))
    });
    r.answer(&["_AudioUnitSetProperty"], |c| {
        let line = format!("set property {} scope {}", c.arg32(1), c.arg32(2));
        state(c.m).lock().unwrap().audio.push(line);
        Ok(Some(0))
    });
    r.answer(&["_AudioUnitInitialize", "_AudioOutputUnitStart", "_AudioOutputUnitStop", "_AudioComponentInstanceDispose"], |c| {
        state(c.m).lock().unwrap().audio.push(c.name[1..].to_string());
        Ok(Some(0))
    });
    r.answer(&["_CGDisplayScreenSize"], |c| {
        let (w, h) = if c.arg32(0) == 1 { (SCREEN_POINTS.0 * 25.4 / 132.0, SCREEN_POINTS.1 * 25.4 / 132.0) } else { (0.0, 0.0) };
        c.set_d(0, w);
        c.set_d(1, h);
        Ok(None)
    });
    r.answer(&["_CGDisplayCopyDisplayMode"], |c| Ok(Some(if c.arg32(0) == 1 { c.alloc(64) } else { 0 })));
    r.answer(&["_CGDisplayModeGetRefreshRate"], |c| {
        let rate = if c.arg(0) != 0 { 120.0 } else { 0.0 };
        c.set_d(0, rate);
        Ok(None)
    });
    r.answer(&["_CGDisplayModeRelease"], |_| Ok(None));
}

// --- libc++: Apple's arm64 string layout: data, size, capacity with the top bit set when long;
//     short strings keep up to 22 bytes inline, their size in byte 23 --------------------------
const LONG: u64 = 1 << 63;

#[derive(Debug, PartialEq)]
enum Layout {
    Short(Vec<u8>),
    Long { data: u64, size: u64, capacity: u64 },
}

fn parse_string(raw: &[u8]) -> Layout {
    if raw[23] & 0x80 != 0 {
        let word = |i: usize| u64::from_le_bytes(raw[8 * i..8 * i + 8].try_into().expect("8 bytes"));
        Layout::Long { data: word(0), size: word(1), capacity: word(2) & !LONG }
    } else {
        Layout::Short(raw[..raw[23] as usize].to_vec())
    }
}

fn short_string(value: &[u8]) -> [u8; 24] {
    let mut raw = [0u8; 24];
    raw[..value.len()].copy_from_slice(value);
    raw[23] = value.len() as u8;
    raw
}

fn long_string(data: u64, size: u64, capacity: u64) -> [u8; 24] {
    let mut raw = [0u8; 24];
    raw[..8].copy_from_slice(&data.to_le_bytes());
    raw[8..16].copy_from_slice(&size.to_le_bytes());
    raw[16..].copy_from_slice(&(capacity | LONG).to_le_bytes());
    raw
}

fn string_get(m: &Machine, this: u64) -> Vec<u8> {
    match parse_string(m.memory.slice(this, 24)) {
        Layout::Short(bytes) => bytes,
        Layout::Long { data, size, .. } => m.memory.read(data, size as usize),
    }
}

fn string_capacity(m: &Machine, this: u64) -> u64 {
    match parse_string(m.memory.slice(this, 24)) {
        Layout::Short(_) => 22,
        Layout::Long { capacity, .. } => capacity - 1,
    }
}

fn string_set(m: &Machine, this: u64, value: &[u8], reserve: u64) {
    if value.len() <= 22 && reserve <= 22 {
        m.memory.write(this, &short_string(value));
        return;
    }
    let capacity = (value.len() as u64).max(reserve) + 1;
    let data = m.alloc(capacity);
    m.memory.write(data, value);
    m.memory.set_u8(data + value.len() as u64, 0);
    m.memory.write(this, &long_string(data, value.len() as u64, capacity));
}

fn next_prime(n: u64) -> u64 {
    let mut n = n.max(2);
    while (2..).take_while(|p: &u64| p.saturating_mul(*p) <= n).any(|p| n % p == 0) {
        n += 1;
    }
    n
}

fn register_cxx(r: &mut Registry) {
    r.answer(&["__ZNKSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEE4findEcm"], |c| {
        let s = string_get(c.m, c.arg(0));
        let from = (c.arg(2) as usize).min(s.len());
        Ok(Some(s[from..].iter().position(|&b| b == c.arg(1) as u8).map_or(u64::MAX, |at| (from + at) as u64)))
    });
    r.answer(&["__ZNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEE6assignEPKc"], |c| {
        string_set(c.m, c.arg(0), &c.mem().cbytes(c.arg(1)), 0);
        Ok(Some(c.arg(0)))
    });
    r.answer(&["__ZNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEE7reserveEm"], |c| {
        if c.arg(1) > string_capacity(c.m, c.arg(0)) {
            string_set(c.m, c.arg(0), &string_get(c.m, c.arg(0)), c.arg(1));
        }
        Ok(None)
    });
    r.answer(&["__ZNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEE9push_backEc"], |c| {
        let mut value = string_get(c.m, c.arg(0));
        value.push(c.arg(1) as u8);
        string_set(c.m, c.arg(0), &value, string_capacity(c.m, c.arg(0)));
        Ok(None)
    });
    r.answer(&["__ZNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEEaSEc"], |c| {
        string_set(c.m, c.arg(0), &[c.arg(1) as u8], 0);
        Ok(Some(c.arg(0)))
    });
    r.answer(&["__ZNSt3__112__next_primeEm"], |c| Ok(Some(next_prime(c.arg(0)))));
}

// --- data ----------------------------------------------------------------------------------
fn register_data(r: &mut Registry) {
    r.data("___stdoutp", |m, address| m.memory.set_u64(address, m.alloc(256)));
    r.data("___stderrp", |m, address| m.memory.set_u64(address, m.alloc(256)));
    r.data("___stack_chk_guard", |m, address| m.memory.set_u64(address, 0x5EED_5EED_5EED_5EED));
    for name in [
        "__NSConcreteGlobalBlock",
        "__NSConcreteStackBlock",
        "___CFConstantStringClassReference",
        "__objc_empty_cache",
        "_NSDefaultRunLoopMode",
        "_NSEventTrackingRunLoopMode",
        "_NSApp",
        "__ZTVNSt3__117__assoc_sub_stateE",
    ] {
        r.data(name, |_, _| {});
    }
}

// --- hooks ---------------------------------------------------------------------------------
pub fn prepare(m: &Machine, _app: &std::path::Path) -> Result<(), String> {
    if !m.options.steam_live {
        return Ok(());
    }
    if !m.options.vpn {
        return Err("--steam-live needs --vpn".into());
    }
    let vpn = crate::socks::Socks5::from_settings()?;
    let account = crate::settings::setting("STEAM_USER").unwrap_or_else(|| "joenye".into());
    let machine = Arc::downgrade(&m.arc());
    let log: crate::steam::Log = Box::new(move |line| {
        if let Some(m) = machine.upgrade() {
            let frames = m.frames.load(std::sync::atomic::Ordering::Relaxed);
            m.report.network(format!("frame {frames}: steam: {line}"));
        }
    });
    let live = LiveSession::open(&vpn, &account, log)?;
    println!("steam: signed in through the VPN ({}-character persona name)", live.persona().chars().count());
    state(m).lock().unwrap().live = Some(live);
    Ok(())
}

pub fn finish(m: &Machine) {
    if let Some(live) = state(m).lock().unwrap().live.take() {
        live.close();
    }
}

fn steam_started(m: &Machine) -> bool {
    let expected = if m.options.offline { "[steam] initialised offline" } else { "[steam] initialised: signed in to Steam" };
    m.report.steam_lines().iter().any(|line| line.contains(expected))
}

pub fn problems(m: &Machine) -> Vec<String> {
    if steam_started(m) { Vec::new() } else { vec!["Steam was not initialised as expected".into()] }
}

pub fn sections(m: &Machine) -> Vec<(String, Vec<String>)> {
    let sys = state(m);
    let sys = sys.lock().unwrap();
    vec![
        ("web API tickets asked of the app's session (identities)".into(), sys.tickets.clone()),
        ("audio".into(), sys.audio.clone()),
    ]
}

/// "signed in (the app's session)", "initialised offline" or "not initialised", for the verdict.
pub fn steam_summary(m: &Machine) -> String {
    match (steam_started(m), m.options.offline) {
        (false, _) => "not initialised",
        (true, true) => "initialised offline",
        (true, false) => "signed in (the app's session)",
    }
    .into()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn format(text: &str, slots: &[u64]) -> String {
        let mut slots = slots.iter().copied();
        let strings = |a: u64| if a == 1 { b"hello".to_vec() } else { Vec::new() };
        let objects = |o: u64| if o == 7 { "an NSString".to_string() } else { format!("<object {o:#x}>") };
        String::from_utf8(format_with(text.as_bytes(), || slots.next().unwrap_or(0), strings, objects)).unwrap()
    }

    #[test]
    fn integers() {
        assert_eq!(format("%d %i %u", &[(-5i64) as u64, 0xFFFF_FFFF, 0xFFFF_FFFF]), "-5 -1 4294967295");
        assert_eq!(format("%ld %llu", &[(-5i64) as u64, u64::MAX]), "-5 18446744073709551615");
        assert_eq!(format("%x %X %#x %o %#o", &[255, 255, 255, 8, 8]), "ff FF 0xff 10 010");
        assert_eq!(format("%05d|%-5d|%+d|% d", &[42, 42, 42, 42]), "00042|42   |+42| 42");
        assert_eq!(format("%.3d|%5.3d|%08.3d", &[7, 7, 7]), "007|  007|     007");
        assert_eq!(format("%*d|%-*d", &[4, 1, 3, 2]), "   1|2  ");
        assert_eq!(format("%p %c", &[0x1234, b'z' as u64]), "0x1234 z");
    }

    #[test]
    fn strings_and_objects() {
        assert_eq!(format("[%s] [%s]", &[1, 0]), "[hello] [(null)]");
        assert_eq!(format("[%8s] [%-8s] [%.3s]", &[1, 1, 1]), "[   hello] [hello   ] [hel]");
        assert_eq!(format("%@ and %@", &[7, 0x40]), "an NSString and <object 0x40>");
        assert_eq!(format("100%% %y", &[]), "100% %y");
        assert_eq!(format("tail %", &[]), "tail ");
    }

    #[test]
    fn floats() {
        let f = |v: f64| v.to_bits();
        assert_eq!(format("%f %.2f %8.3f %-8.1f|", &[f(1.5), f(3.14159), f(-2.5), f(0.25)]), "1.500000 3.14   -2.500 0.2     |");
        assert_eq!(format("%e %.2E", &[f(12345.678), f(0.000123)]), "1.234568e+04 1.23E-04");
        assert_eq!(format("%g %g %g %g", &[f(100000.0), f(1000000.0), f(0.0001), f(1.5)]), "100000 1e+06 0.0001 1.5");
        assert_eq!(format("%a %f %F", &[f(1.0), f(f64::INFINITY), f(0.0)]), "0x1p+0 inf %F");
        assert_eq!(format("%06.2f %+.1f", &[f(-1.5), f(2.0)]), "-01.50 +2.0");
    }

    #[test]
    fn libcxx_string_layout() {
        let short = short_string(b"abc");
        assert_eq!(short[23], 3);
        assert_eq!(parse_string(&short), Layout::Short(b"abc".to_vec()));
        let long = long_string(0x4000_0000, 30, 31);
        assert_eq!(long[23] & 0x80, 0x80);
        assert_eq!(parse_string(&long), Layout::Long { data: 0x4000_0000, size: 30, capacity: 31 });
    }

    #[test]
    fn small_helpers() {
        assert_eq!(next_prime(0), 2);
        assert_eq!(next_prime(24), 29);
        assert_eq!(next_prime(97), 97);
        assert_eq!(atoi("  42 apples"), 42);
        assert_eq!(atoi("-1"), 0xFFFF_FFFF);
        assert_eq!(atoi("12abc"), 0);
        assert_eq!(compare(b"a", b"b"), 0xFFFF_FFFF);
        assert_eq!(hex_float(0.5), "0x1p-1");
        assert_eq!(hex_float(1.5), "0x1.8p+0");
    }
}
