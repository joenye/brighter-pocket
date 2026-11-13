//! A small Objective-C runtime for the client.
//!
//! The client's own classes are read from its metadata (after fix-ups, so every pointer is
//! absolute) and their methods run as the client's code: a message to one of them jumps to its
//! implementation. System classes are opaque: each imported class is an imported data symbol,
//! an instance is a small block whose first word points at it, and the messages the client
//! sends them are answered from the selector table below (Metal's from metal.rs; anything else
//! is recorded and answers nil, as a message to nil would). Tolkara's AppKit classes answer
//! exactly the selectors its adapter implements (appkit.rs) and nil for the rest. Strings,
//! arrays, dictionaries and numbers the emulator makes keep their contents here beside the
//! objects.
use std::collections::{HashMap, HashSet, VecDeque};
use std::path::Path;
use std::sync::LazyLock;

use super::{Ctx, Registry, Stop};
use crate::machine::{HEAP_BASE, HEAP_SIZE, Machine};
use crate::memory::Memory;

#[path = "appkit.rs"]
mod appkit;

/// An answer for a selector sent to one of the harness's own objects (Metal's, here).
pub type SelectorAnswer = fn(&mut Ctx, u64, &str) -> Result<Option<u64>, Stop>;

/// What the client sends to real iOS classes that only macOS has (the SDK marks them
/// API_UNAVAILABLE(ios)); PocketCompat.m adds them at load.
const IOS_LACKS: &[(&str, &str)] = &[("CAMetalLayer", "setDisplaySyncEnabled:"), ("CAMetalLayer", "displaySyncEnabled")];
/// Tolkara AppKit selectors the client sends that the adapter leaves to its stub (nil): each
/// returns nothing, and nothing the client does depends on it.
const HARMLESS: &[&str] = &["[-NSApplication setMenu:]", "[-NSWindow center]", "[-NSWindow setMaxSize:]"];
const UNIMPLEMENTED: &str = "  [unimplemented: nil]";
const CLASS_PREFIX: &str = "_OBJC_CLASS_$_";

struct ClientClass {
    name: String,
    instance_size: u64,
    methods: HashMap<String, u64>,
    class_methods: HashMap<String, u64>,
    superclass: u64,
}

#[derive(Default)]
struct Objc {
    classlist: Option<(u64, u64)>,
    appkit: Option<appkit::Coverage>,
    loaded: bool,
    classes: HashMap<u64, ClientClass>,
    imported: HashMap<u64, String>,
    cfstring: u64,
    strings: HashMap<u64, String>,
    arrays: HashMap<u64, Vec<u64>>,
    dicts: HashMap<u64, Vec<(String, u64)>>,
    numbers: HashMap<u64, u64>,
    ns_data: HashMap<u64, (u64, u64)>,
    image_formats: Vec<String>,
    content_views: HashMap<u64, u64>,
    instances: HashMap<String, Vec<u64>>,
    events: VecDeque<(u32, f64, f64)>,
    event_info: HashMap<u64, (u32, f64, f64)>,
    handled: Vec<String>,
    /// Sends to system classes: (class with its side, selector) -> (count, first seen).
    sends: HashMap<(String, String), (u64, usize)>,
    recent: VecDeque<String>,
    selectors: HashMap<String, u64>,
    singletons: HashMap<String, u64>,
    /// The mutations word fast enumeration hands out (nothing mutates an array here).
    mutations: u64,
    /// The app bundle's path, for -bundlePath.
    app: String,
    /// --click: (frame, x, y).
    clicks: Vec<(u64, f64, f64)>,
}

/// A receiver's class: its address, whether the receiver is the class itself, whether the
/// class is the client's, and the system class's name.
struct Kind {
    address: u64,
    is_class: bool,
    client: bool,
    system: Option<String>,
}

impl Objc {
    fn isa(&self, mem: &Memory, obj: u64) -> u64 {
        if obj == 0 || !mem.is_mapped(obj, 8) { 0 } else { mem.u64(obj) & 0x0000_000F_FFFF_FFF8 }
    }

    fn class_of(&self, mem: &Memory, obj: u64) -> Kind {
        if self.classes.contains_key(&obj) {
            return Kind { address: obj, is_class: true, client: true, system: None };
        }
        if let Some(name) = self.imported.get(&obj) {
            return Kind { address: obj, is_class: true, client: false, system: Some(name.clone()) };
        }
        let isa = self.isa(mem, obj);
        let (client, system) = if self.classes.contains_key(&isa) {
            (true, None)
        } else if let Some(name) = self.imported.get(&isa) {
            (false, Some(name.clone()))
        } else if isa != 0 && isa == self.cfstring {
            (false, Some("NSString".to_string()))
        } else {
            (false, None)
        };
        Kind { address: isa, is_class: false, client, system }
    }

    /// A client implementation along the client's own superclass chain.
    fn lookup(&self, mut class: u64, selector: &str, class_side: bool) -> Option<u64> {
        while let Some(info) = self.classes.get(&class) {
            let methods = if class_side { &info.class_methods } else { &info.methods };
            if let Some(&implementation) = methods.get(selector) {
                return Some(implementation);
            }
            class = info.superclass;
        }
        None
    }

    fn system_class_of(&self, mut class: u64) -> Option<String> {
        while let Some(info) = self.classes.get(&class) {
            class = info.superclass;
        }
        self.imported.get(&class).cloned()
    }

    fn string(&self, mem: &Memory, obj: u64) -> Option<String> {
        if let Some(text) = self.strings.get(&obj) {
            return Some(text.clone());
        }
        if self.cfstring != 0 && self.isa_raw(mem, obj) == self.cfstring {
            let (pointer, length) = (mem.u64(obj + 16), mem.u64(obj + 24));
            return Some(String::from_utf8_lossy(&mem.read(pointer, length as usize)).into_owned());
        }
        None
    }

    fn isa_raw(&self, mem: &Memory, obj: u64) -> u64 {
        if obj == 0 || !mem.is_mapped(obj, 32) { 0 } else { mem.u64(obj) }
    }

    fn nsstring(&self, mem: &Memory, obj: u64) -> String {
        self.string(mem, obj).unwrap_or_else(|| format!("<object {obj:#x}>"))
    }

    fn describe(&self, mem: &Memory, obj: u64) -> String {
        if obj == 0 {
            return "(null)".into();
        }
        let kind = self.class_of(mem, obj);
        if self.strings.contains_key(&obj) || kind.system.as_deref() == Some("NSString") {
            return self.nsstring(mem, obj);
        }
        let name = if kind.client {
            self.classes[&kind.address].name.clone()
        } else {
            kind.system.unwrap_or_else(|| "?".into())
        };
        if kind.is_class { name } else { format!("<{name} {obj:#x}>") }
    }

    /// An argument for the log: an object we know, else the number.
    fn describe_arg(&self, mem: &Memory, value: u64) -> String {
        let known = self.strings.contains_key(&value)
            || self.arrays.contains_key(&value)
            || self.classes.contains_key(&value)
            || self.imported.contains_key(&value)
            || ((HEAP_BASE..HEAP_BASE + HEAP_SIZE).contains(&value)
                && mem.is_mapped(value, 8)
                && self.imported.contains_key(&mem.u64(value)));
        if known { self.describe(mem, value) } else { format!("{value:#x}") }
    }

    fn record(&mut self, class: String, selector: String) {
        let order = self.sends.len();
        self.sends.entry((class, selector)).or_insert((0, order)).0 += 1;
    }

    fn unimplemented(&self) -> Vec<String> {
        let mut out: Vec<String> = self
            .sends
            .keys()
            .filter(|(_, selector)| selector.contains("unimplemented"))
            .map(|(class, selector)| format!("[{class} {}]", selector.split_whitespace().next().unwrap_or("")))
            .collect();
        out.sort();
        out.dedup();
        out
    }
}

fn state(m: &Machine) -> std::sync::Arc<std::sync::Mutex<Objc>> {
    m.state::<Objc>()
}

/// The client's classes, once the images are fixed up (the first message comes after that).
fn ensure(m: &Machine) {
    let st = state(m);
    let classlist = {
        let st = st.lock().unwrap();
        if st.loaded {
            return;
        }
        st.classlist
    };
    let classes = classlist.map(|section| read_client_classes(&m.memory, section)).unwrap_or_default();
    let cfstring = m.data_symbol("___CFConstantStringClassReference");
    let imported: Vec<(u64, String)> = m
        .data_symbols()
        .into_iter()
        .filter_map(|(name, address)| name.strip_prefix(CLASS_PREFIX).map(|n| (address, n.to_string())))
        .collect();
    let mut st = st.lock().unwrap();
    if !st.loaded {
        st.loaded = true;
        st.classes = classes;
        st.imported.extend(imported);
        st.cfstring = cfstring;
    }
}

/// The client's classes from __objc_classlist: name, superclass, instance size, methods by selector.
fn read_client_classes(mem: &Memory, (address, size): (u64, u64)) -> HashMap<u64, ClientClass> {
    let mut out = HashMap::new();
    for i in 0..size / 8 {
        let class = mem.u64(address + 8 * i);
        let meta = mem.u64(class);
        let (name, instance_size, methods) = read_class(mem, class);
        let (_, _, class_methods) = read_class(mem, meta);
        out.insert(class, ClientClass { name, instance_size, methods, class_methods, superclass: mem.u64(class + 8) });
    }
    out
}

fn read_class(mem: &Memory, class: u64) -> (String, u64, HashMap<String, u64>) {
    let ro = mem.u64(class + 32) & !7;
    let instance_size = mem.u32(ro + 8) as u64;
    let name = mem.cstring(mem.u64(ro + 24));
    let mut methods = HashMap::new();
    let list = mem.u64(ro + 32);
    if list != 0 {
        let (flags, count) = (mem.u32(list), mem.u32(list + 4));
        let (entsize, relative) = ((flags & 0xFFFC) as u64, flags & 0x8000_0000 != 0);
        for k in 0..count as u64 {
            let entry = list + 8 + k * entsize;
            if relative {
                let name_off = mem.i32(entry) as i64;
                let imp_off = mem.i32(entry + 8) as i64;
                let selector = mem.cstring(mem.u64(entry.wrapping_add_signed(name_off)));
                methods.insert(selector, (entry + 8).wrapping_add_signed(imp_off));
            } else {
                methods.insert(mem.cstring(mem.u64(entry)), mem.u64(entry + 16));
            }
        }
    }
    (name, instance_size, methods)
}

fn imported_class(m: &Machine, name: &str) -> u64 {
    let address = m.data_symbol(&format!("{CLASS_PREFIX}{name}"));
    state(m).lock().unwrap().imported.insert(address, name.to_string());
    address
}

fn new_object_of(m: &Machine, class: u64, size: u64) -> u64 {
    let obj = m.alloc(size);
    m.memory.set_u64(obj, class);
    obj
}

fn selector_address(m: &Machine, name: &str) -> u64 {
    if let Some(&address) = state(m).lock().unwrap().selectors.get(name) {
        return address;
    }
    let address = m.new_cstring(name);
    *state(m).lock().unwrap().selectors.entry(name.to_string()).or_insert(address)
}

/// --click X,Y[@FRAME]: (frame, x, y), frame 30 when not given.
fn parse_click(spec: &str) -> Result<(u64, f64, f64), String> {
    let bad = || format!("--click {spec}: expected X,Y[@FRAME]");
    let (place, frame) = spec.split_once('@').unwrap_or((spec, ""));
    let (x, y) = place.split_once(',').ok_or_else(bad)?;
    let x: f64 = x.trim().parse().map_err(|_| bad())?;
    let y: f64 = y.trim().parse().map_err(|_| bad())?;
    let frame = if frame.is_empty() { 30 } else { frame.trim().parse().map_err(|_| bad())? };
    Ok((frame, x, y))
}

// NSStringEncoding: NSUTF8StringEncoding (4), NSASCIIStringEncoding (1), NSISOLatin1 (5),
// NSUTF16LittleEndianStringEncoding (0x94000100), the one the client's own strings (UTF-16 code
// units) travel in, its big-endian twin and NSUnicodeStringEncoding (10).
#[derive(Clone, Copy, PartialEq, Debug)]
enum Codec {
    Ascii,
    Utf8,
    Latin1,
    Utf16Le,
    Utf16Be,
}

fn codec(encoding: u64) -> Codec {
    match encoding & 0xFFFF_FFFF {
        1 => Codec::Ascii,
        5 => Codec::Latin1,
        0x9400_0100 | 10 => Codec::Utf16Le,
        0x9000_0100 => Codec::Utf16Be,
        _ => Codec::Utf8,
    }
}

fn encode(text: &str, encoding: u64) -> Vec<u8> {
    match codec(encoding) {
        Codec::Utf8 => text.as_bytes().to_vec(),
        Codec::Ascii => text.chars().map(|c| if c.is_ascii() { c as u8 } else { b'?' }).collect(),
        Codec::Latin1 => text.chars().map(|c| if (c as u32) < 256 { c as u8 } else { b'?' }).collect(),
        Codec::Utf16Le => text.encode_utf16().flat_map(u16::to_le_bytes).collect(),
        Codec::Utf16Be => text.encode_utf16().flat_map(u16::to_be_bytes).collect(),
    }
}

fn decode(data: &[u8], encoding: u64) -> String {
    let units = |big: bool| -> Vec<u16> {
        data.chunks_exact(2).map(|p| if big { u16::from_be_bytes([p[0], p[1]]) } else { u16::from_le_bytes([p[0], p[1]]) }).collect()
    };
    match codec(encoding) {
        Codec::Utf8 => String::from_utf8_lossy(data).into_owned(),
        Codec::Ascii => data.iter().map(|&b| if b.is_ascii() { b as char } else { '\u{FFFD}' }).collect(),
        Codec::Latin1 => data.iter().map(|&b| b as char).collect(),
        Codec::Utf16Le => String::from_utf16_lossy(&units(false)),
        Codec::Utf16Be => String::from_utf16_lossy(&units(true)),
    }
}

fn terminator(encoding: u64) -> &'static [u8] {
    if matches!(codec(encoding), Codec::Utf16Le | Codec::Utf16Be) { b"\0\0" } else { b"\0" }
}

/// What PNG, JPEG, TIFF or GIF bytes start with; else their first bytes in hex.
fn image_format(head: &[u8]) -> String {
    const SIGNATURES: &[(&[u8], &str)] =
        &[(b"\x89PNG", "PNG"), (b"\xff\xd8\xff", "JPEG"), (b"II*\x00", "TIFF"), (b"MM\x00*", "TIFF"), (b"GIF8", "GIF")];
    SIGNATURES
        .iter()
        .find(|(magic, _)| head.starts_with(magic))
        .map_or_else(|| head.iter().map(|b| format!("{b:02x}")).collect(), |(_, name)| name.to_string())
}

pub fn register(r: &mut Registry) {
    r.answer(&["_objc_msgSend"], msg_send);
    r.answer(&["_objc_alloc"], |c| alloc(c, c.arg(0), "alloc"));
    r.answer(&["_objc_alloc_init"], |c| {
        ensure(c.m);
        let class = c.arg(0);
        let obj = alloc(c, class, "alloc")?.unwrap_or(0);
        let implementation = {
            let st = state(c.m);
            let st = st.lock().unwrap();
            if st.classes.contains_key(&class) { st.lookup(class, "init", false) } else { None }
        };
        if let Some(implementation) = implementation {
            let init = selector_address(c.m, "init");
            c.set(0, obj);
            c.set(1, init);
            c.jump(implementation);
            return Ok(None);
        }
        Ok(Some(obj))
    });
    r.answer(&["_objc_retain", "_objc_autorelease"], |c| Ok(Some(c.arg(0))));
    r.answer(&["_objc_release", "_objc_autoreleasePoolPop"], |_| Ok(None));
    r.answer(&["_objc_autoreleasePoolPush"], |c| Ok(Some(c.alloc(16))));
    r.answer(&["_objc_opt_class"], |c| {
        let obj = c.arg(0);
        if obj == 0 {
            return Ok(Some(0));
        }
        ensure(c.m);
        let kind = state(c.m).lock().unwrap().class_of(c.mem(), obj);
        Ok(Some(if kind.is_class { obj } else { kind.address }))
    });
    r.answer(&["_objc_enumerationMutation"], |_| Err(Stop::from("objc_enumerationMutation")));
    for name in [
        "__NSConcreteGlobalBlock",
        "__NSConcreteStackBlock",
        "___CFConstantStringClassReference",
        "__objc_empty_cache",
        "_NSDefaultRunLoopMode",
        "_NSEventTrackingRunLoopMode",
        "_NSApp",
    ] {
        r.data(name, |_, _| {});
    }
}

fn msg_send(c: &mut Ctx) -> Result<Option<u64>, Stop> {
    let (recv, sel) = (c.arg(0), c.arg(1));
    if recv == 0 {
        return Ok(Some(0));
    }
    let selector = c.cstring(sel);
    ensure(c.m);
    {
        let st = state(c.m);
        let mut st = st.lock().unwrap();
        let mem = c.mem();
        let kind = st.class_of(mem, recv);
        if kind.client {
            if let Some(implementation) = st.lookup(kind.address, &selector, kind.is_class) {
                drop(st);
                c.jump(implementation);
                return Ok(None);
            }
        }
        let name = kind
            .system
            .clone()
            .or_else(|| if kind.client { st.system_class_of(kind.address) } else { None })
            .unwrap_or_else(|| "?".into());
        let side = if kind.is_class { "+" } else { "-" };
        if let Some(appkit) = &st.appkit {
            if appkit.contains(&name) && !appkit.implements(&name, &selector, kind.is_class) {
                // Tolkara's AppKit classes answer an unimplemented selector with nil (AKStubObject).
                st.record(format!("{side}{name}"), format!("{selector}{UNIMPLEMENTED}"));
                return Ok(Some(0));
            }
        }
        // Real iOS classes that lack a macOS method raise on it (NSInvalidArgumentException),
        // unless PocketCompat.m added it at load.
        let compat = st.appkit.as_ref().is_some_and(|a| a.compat);
        if IOS_LACKS.contains(&(name.as_str(), selector.as_str())) && !compat {
            return Err(Stop(format!("-[{name} {selector}]: unrecognized selector on iOS (the app would end here)")));
        }
        st.record(format!("{side}{name}"), selector.clone());
        let args: Vec<String> =
            (0..selector.matches(':').count() as u32).map(|i| st.describe_arg(mem, c.cpu.reg(2 + i))).collect();
        let line = format!("[{} {selector}] {}", st.describe(mem, recv), args.join(" "));
        st.recent.push_back(line);
        while st.recent.len() > 40 {
            st.recent.pop_front();
        }
    }
    if let Some(answer) = table().get(selector.as_str()) {
        return answer(c, recv, &selector);
    }
    Ok(Some(if selector.starts_with("init") { recv } else { 0 }))
}

/// The selectors system classes answer, as far as the client asks: these and Metal's.
fn table() -> &'static HashMap<&'static str, SelectorAnswer> {
    static TABLE: LazyLock<HashMap<&'static str, SelectorAnswer>> = LazyLock::new(|| {
        let own: &[(&[&'static str], SelectorAnswer)] = &[
            (&["alloc", "new"], alloc),
            (&["init", "retain", "autorelease", "self", "copy"], |_, r, _| Ok(Some(r))),
            (&["release"], |_, _, _| Ok(Some(0))),
            (&["isMainThread", "isKeyWindow", "clickCount"], |_, _, _| Ok(Some(1))),
            (&["occlusionState"], |_, _, _| Ok(Some(2))),
            (&["maximumFramesPerSecond"], |_, _, _| Ok(Some(120))),
            (&["physicalMemory"], |_, _, _| Ok(Some(8 << 30))),
            (&["stringWithUTF8String:"], |c, _, _| {
                let text = c.cstring(c.arg(2));
                Ok(Some(new_string(c.m, &text)))
            }),
            (&["UTF8String"], |c, r, _| {
                let text = string_of(c.m, r);
                Ok(Some(c.new_cstring(&text)))
            }),
            (&["stringByAppendingPathComponent:"], |c, r, _| {
                let (base, part) = (string_of(c.m, r), string_of(c.m, c.arg(2)));
                Ok(Some(new_string(c.m, &format!("{}/{}", base.trim_end_matches('/'), part.trim_start_matches('/')))))
            }),
            (&["mainBundle"], |c, _, _| Ok(Some(new_object(c.m, "NSBundle")))),
            (&["bundlePath"], |c, _, _| {
                let app = state(c.m).lock().unwrap().app.clone();
                Ok(Some(new_string(c.m, &app)))
            }),
            (
                &[
                    "sharedApplication", "mainScreen", "screen", "defaultManager", "processInfo", "mainRunLoop",
                    "sharedWorkspace", "generalPasteboard", "arrowCursor", "IBeamCursor", "crosshairCursor",
                    "pointingHandCursor", "operationNotAllowedCursor",
                ],
                |c, _, s| Ok(Some(singleton_for(c.m, s))),
            ),
            (&["screens"], |c, _, _| {
                let screen = singleton(c.m, "NSScreen", None);
                Ok(Some(new_array(c.m, vec![screen])))
            }),
            // Tolkara's NSWindow: on the main screen, visible, holding the content view it was given.
            (&["setContentView:"], |c, r, _| {
                state(c.m).lock().unwrap().content_views.insert(r, c.arg(2));
                Ok(None)
            }),
            (&["contentView"], |c, r, _| Ok(Some(state(c.m).lock().unwrap().content_views.get(&r).copied().unwrap_or(0)))),
            (&["count"], |c, r, _| Ok(Some(state(c.m).lock().unwrap().arrays.get(&r).map_or(0, |a| a.len() as u64)))),
            (&["objectAtIndex:", "objectAtIndexedSubscript:"], |c, r, _| {
                let item = state(c.m).lock().unwrap().arrays.get(&r).map(|items| items.get(c.arg(2) as usize).copied().unwrap_or(0));
                // A Metal descriptor array: an element for each index.
                Ok(Some(item.unwrap_or_else(|| new_object(c.m, "MTLArrayElement"))))
            }),
            (&["countByEnumeratingWithState:objects:count:"], fast_enumeration),
            (&["dataWithBytesNoCopy:length:freeWhenDone:"], |c, r, _| {
                let data = new_object_of(c.m, r, 64);
                state(c.m).lock().unwrap().ns_data.insert(data, (c.arg(2), c.arg(3)));
                Ok(Some(data))
            }),
            // NSData keeps its bytes; an image made from one records what format the bytes are
            // in, since on the device PocketCompat.m decodes them with UIImage.
            (&["imageRepWithData:"], |c, r, _| {
                let (pointer, size) = state(c.m).lock().unwrap().ns_data.get(&c.arg(2)).copied().unwrap_or((0, 0));
                let head = if pointer != 0 && size >= 8 { c.mem().read(pointer, 8) } else { Vec::new() };
                state(c.m).lock().unwrap().image_formats.push(image_format(&head));
                Ok(Some(new_object_of(c.m, r, 64)))
            }),
            (&["frame", "bounds", "visibleFrame", "frameRectForContentRect:"], |c, _, _| Ok(doubles(c, &[0.0, 0.0, 1366.0, 1024.0]))),
            (&["convertRectToBacking:"], |c, _, _| Ok(doubles(c, &[0.0, 0.0, 2732.0, 2048.0]))),
            (&["backingScaleFactor"], |c, _, _| Ok(doubles(c, &[2.0]))),
            (&["fileExistsAtPath:"], |c, _, _| {
                let path = string_of(c.m, c.arg(2));
                Ok(Some(super::files::exists(c.m, &path) as u64))
            }),
            (&["createDirectoryAtPath:withIntermediateDirectories:attributes:error:"], |c, _, _| {
                let path = string_of(c.m, c.arg(2));
                Ok(Some(super::files::make_directories(c.m, &path) as u64))
            }),
            (&["lengthOfBytesUsingEncoding:"], |c, r, _| Ok(Some(encode(&string_of(c.m, r), c.arg(2)).len() as u64))),
            (&["initWithBytes:length:encoding:"], |c, r, _| {
                let text = decode(&c.mem().read(c.arg(2), c.arg(3) as usize), c.arg(4));
                state(c.m).lock().unwrap().strings.insert(r, text);
                Ok(Some(r))
            }),
            // Variadic: the format in x2, its arguments on the stack (Apple arm64).
            (&["stringWithFormat:"], |c, _, _| {
                let format = string_of(c.m, c.arg(2));
                let text = super::libsystem::format_string(c.m, format.as_bytes(), c.cpu.sp());
                Ok(Some(new_string(c.m, &String::from_utf8_lossy(&text))))
            }),
            (&["getCString:maxLength:encoding:"], |c, r, _| {
                let encoding = c.arg(4);
                let mut text = encode(&string_of(c.m, r), encoding);
                text.extend_from_slice(terminator(encoding));
                if text.len() as u64 > c.arg(3) {
                    return Ok(Some(0));
                }
                c.mem().write(c.arg(2), &text);
                Ok(Some(1))
            }),
            (&["nextEventMatchingMask:untilDate:inMode:dequeue:"], next_event),
            (&["sendEvent:"], send_event),
            // Tolkara's -[NSApplication terminate:] tells the delegate and calls exit(0).
            (&["terminate:"], |_, _, _| Err(Stop::from("the client quit: -[NSApplication terminate:]"))),
            (&["locationInWindow"], |c, r, _| {
                let (_, x, y) = state(c.m).lock().unwrap().event_info.get(&r).copied().unwrap_or((0, 0.0, 0.0));
                Ok(doubles(c, &[x, y]))
            }),
            (&["deviceDescription"], |c, _, _| {
                let number = new_object(c.m, "NSNumber");
                state(c.m).lock().unwrap().numbers.insert(number, 1);
                Ok(Some(dictionary(c.m, vec![("NSScreenNumber".into(), number)])))
            }),
            (&["objectForKey:"], |c, r, _| {
                let key = string_of(c.m, c.arg(2));
                let st = state(c.m);
                let st = st.lock().unwrap();
                Ok(Some(st.dicts.get(&r).and_then(|e| e.iter().rev().find(|(k, _)| *k == key)).map_or(0, |(_, v)| *v)))
            }),
            (&["unsignedIntValue", "intValue", "integerValue", "unsignedIntegerValue"], |c, r, _| {
                Ok(Some(state(c.m).lock().unwrap().numbers.get(&r).copied().unwrap_or(0)))
            }),
        ];
        let mut table = HashMap::new();
        for (names, answer) in own {
            for name in *names {
                table.insert(*name, *answer);
            }
        }
        table.extend(super::metal::selectors());
        table
    });
    &TABLE
}

/// A floating-point result: one double in d0, or a homogeneous aggregate (NSRect) in d0 to d3.
fn doubles(c: &mut Ctx, values: &[f64]) -> Option<u64> {
    for (i, &value) in values.iter().enumerate() {
        c.set_d(i as u32, value);
    }
    None
}

fn string_of(m: &Machine, obj: u64) -> String {
    ensure(m);
    let st = state(m);
    let st = st.lock().unwrap();
    st.nsstring(&m.memory, obj)
}

fn alloc(c: &mut Ctx, class: u64, _: &str) -> Result<Option<u64>, Stop> {
    ensure(c.m);
    let client = {
        let st = state(c.m);
        let st = st.lock().unwrap();
        st.classes.get(&class).map(|info| (info.name.clone(), info.instance_size))
    };
    Ok(Some(match client {
        Some((name, size)) => {
            let obj = new_object_of(c.m, class, size.max(64));
            state(c.m).lock().unwrap().instances.entry(name).or_default().push(obj);
            obj
        }
        None => new_object_of(c.m, class, 64),
    }))
}

fn singleton_for(m: &Machine, selector: &str) -> u64 {
    match selector {
        "sharedApplication" => singleton(m, "NSApplication", Some("_NSApp")),
        "mainScreen" | "screen" => singleton(m, "NSScreen", None),
        "defaultManager" => singleton(m, "NSFileManager", None),
        "processInfo" => singleton(m, "NSProcessInfo", None),
        "mainRunLoop" => singleton(m, "NSRunLoop", None),
        "sharedWorkspace" => singleton(m, "NSWorkspace", None),
        "generalPasteboard" => singleton(m, "NSPasteboard", None),
        _ => singleton(m, "NSCursor", None),
    }
}

fn singleton(m: &Machine, class: &str, global: Option<&str>) -> u64 {
    if let Some(&obj) = state(m).lock().unwrap().singletons.get(class) {
        return obj;
    }
    let obj = new_object(m, class);
    let obj = *state(m).lock().unwrap().singletons.entry(class.to_string()).or_insert(obj);
    if let Some(global) = global {
        let address = m.data_symbol(global);
        m.memory.set_u64(address, obj);
    }
    obj
}

fn fast_enumeration(c: &mut Ctx, recv: u64, _: &str) -> Result<Option<u64>, Stop> {
    // NSFastEnumerationState: state, itemsPtr, mutationsPtr, extra[5]; all items in one pass.
    let (enumeration, buffer, capacity) = (c.arg(2), c.arg(3), c.arg(4));
    let mutations = state(c.m).lock().unwrap().mutations;
    let items = state(c.m).lock().unwrap().arrays.get(&recv).cloned().unwrap_or_default();
    if c.mem().u64(enumeration) != 0 || items.is_empty() {
        return Ok(Some(0));
    }
    let items = &items[..items.len().min(capacity as usize)];
    for (i, item) in items.iter().enumerate() {
        c.mem().set_u64(buffer + 8 * i as u64, *item);
    }
    c.mem().set_u64(enumeration, 1);
    c.mem().set_u64(enumeration + 8, buffer);
    c.mem().set_u64(enumeration + 16, mutations);
    Ok(Some(items.len() as u64))
}

// Input, as Tolkara's AppKit delivers it: -nextEventMatchingMask:... hands out queued events and
// -sendEvent: passes each to the window's first responder, the client's MyWindowView, whose
// handler runs as the client's own code. The queue is filled by --click (on_frame).
fn handler(event_type: u32) -> &'static str {
    match event_type {
        1 => "mouseDown:",
        2 => "mouseUp:",
        _ => "mouseMoved:",
    }
}

fn next_event(c: &mut Ctx, _: u64, _: &str) -> Result<Option<u64>, Stop> {
    let Some(event) = state(c.m).lock().unwrap().events.pop_front() else { return Ok(Some(0)) };
    let obj = new_object(c.m, "NSEvent");
    state(c.m).lock().unwrap().event_info.insert(obj, event);
    Ok(Some(obj))
}

fn send_event(c: &mut Ctx, _: u64, _: &str) -> Result<Option<u64>, Stop> {
    let event = c.arg(2);
    let found = {
        let st = state(c.m);
        let mut st = st.lock().unwrap();
        let info = st.event_info.get(&event).copied();
        let view = st.instances.get("MyWindowView").and_then(|v| v.last().copied());
        match (info, view) {
            (Some((event_type, x, y)), Some(view)) => {
                let name = handler(event_type);
                let class = st.isa(c.mem(), view);
                st.lookup(class, name, false).map(|implementation| {
                    st.handled.push(format!("{name} at {x:.0},{y:.0}"));
                    (view, name, implementation)
                })
            }
            _ => None,
        }
    };
    let Some((view, name, implementation)) = found else { return Ok(Some(0)) };
    let selector = selector_address(c.m, name);
    c.set(0, view);
    c.set(1, selector);
    c.set(2, event);
    c.jump(implementation);
    Ok(None)
}

/// Before loading: where the client's class list is, which classes it imports from AppKit,
/// AppKit's coverage from the prepared tree, and the --click script.
pub fn prepare(m: &Machine, app: &Path) -> Result<(), String> {
    let executable = std::fs::read(app.join(crate::settings::BUNDLE_EXECUTABLE)).map_err(|e| e.to_string())?;
    let image = crate::macho::Image::parse(crate::macho::Image::thin(&executable)?)?;
    let classlist = image
        .section("__DATA_CONST", "__objc_classlist")
        .or_else(|| image.section("__DATA", "__objc_classlist"))
        .map(|s| (s.addr, s.size));
    let imported: HashSet<String> = image
        .imports()
        .iter()
        .filter(|i| image.library(i.ordinal).ends_with("/AppKit"))
        .filter_map(|i| i.name.strip_prefix(CLASS_PREFIX).map(str::to_string))
        .collect();
    // The device's AppKit, as a build from the prepared tree would have it (or, with
    // --pinned-appkit, as the pinned Tolkara alone has it, without this layer's additions).
    let root = crate::settings::root();
    let tree = if m.options.pinned_appkit {
        root.join("platform")
    } else {
        let tree = crate::settings::build_dir().join("emulate/platform");
        let status = std::process::Command::new(root.join(".venv/bin/python"))
            .current_dir(&root)
            .arg("-c")
            .arg("import sys; from pathlib import Path; sys.path.insert(0, 'tools'); import prepare; prepare.prepare(Path(sys.argv[1]))")
            .arg(&tree)
            .status()
            .map_err(|e| format!("tools/prepare.py: {e}"))?;
        if !status.success() {
            return Err(format!("tools/prepare.py could not prepare {}", tree.display()));
        }
        tree
    };
    let coverage = appkit::Coverage::read(&tree, &imported)?;
    let clicks = m.options.clicks.iter().map(|spec| parse_click(spec)).collect::<Result<Vec<_>, _>>()?;
    let st = state(m);
    let mut st = st.lock().unwrap();
    st.classlist = classlist;
    st.appkit = Some(coverage);
    st.clicks = clicks;
    st.app = app.display().to_string();
    st.mutations = m.alloc(8);
    Ok(())
}

pub fn finish(_m: &Machine) {}

pub fn problems(m: &Machine) -> Vec<String> {
    let unimplemented: Vec<String> =
        state(m).lock().unwrap().unimplemented().into_iter().filter(|s| !HARMLESS.contains(&s.as_str())).collect();
    if unimplemented.is_empty() { Vec::new() } else { vec![format!("unanswered AppKit calls: {}", unimplemented.join(", "))] }
}

pub fn sections(m: &Machine) -> Vec<(String, Vec<String>)> {
    let st = state(m);
    let st = st.lock().unwrap();
    let mut sends: Vec<(&(String, String), &(u64, usize))> = st.sends.iter().collect();
    sends.sort_by_key(|(_, (count, order))| (std::cmp::Reverse(*count), *order));
    let top = sends.iter().take(40).map(|((class, selector), (count, _))| format!("{count:6} [{class} {selector}]")).collect();
    let recent = st.recent.iter().skip(st.recent.len().saturating_sub(15)).cloned().collect();
    vec![
        ("AppKit messages the device answers with nil (unimplemented)".into(), st.unimplemented()),
        ("objective-c sends to system classes (top 40)".into(), top),
        ("last objective-c sends".into(), recent),
        ("images made from data (pointer images)".into(), vec![format_counts(&st.image_formats)]),
        ("input delivered".into(), st.handled.clone()),
    ]
}

/// Counts in order of first appearance, as Python prints dict(Counter(...)).
fn format_counts(items: &[String]) -> String {
    let mut counts: Vec<(&str, u64)> = Vec::new();
    for item in items {
        match counts.iter_mut().find(|(name, _)| *name == item) {
            Some(entry) => entry.1 += 1,
            None => counts.push((item, 1)),
        }
    }
    let inner: Vec<String> = counts.iter().map(|(name, n)| format!("'{name}': {n}")).collect();
    format!("{{{}}}", inner.join(", "))
}

/// A new object of a system class (the harness's stand-in for the device's).
pub fn new_object(m: &Machine, class: &str) -> u64 {
    let class = imported_class(m, class);
    new_object_of(m, class, 64)
}

/// A new NSString (immutable, UTF-8).
pub fn new_string(m: &Machine, text: &str) -> u64 {
    let obj = new_object(m, "NSString");
    state(m).lock().unwrap().strings.insert(obj, text.to_string());
    obj
}

/// The text of an NSString or CFString the harness or the client made; None for anything else.
pub fn string_value(m: &Machine, object: u64) -> Option<String> {
    if object == 0 {
        return None;
    }
    ensure(m);
    state(m).lock().unwrap().string(&m.memory, object)
}

pub fn new_array(m: &Machine, items: Vec<u64>) -> u64 {
    let array = new_object(m, "NSArray");
    state(m).lock().unwrap().arrays.insert(array, items);
    array
}

/// A new NSDictionary (also a CFDictionaryRef) with string keys.
pub fn dictionary(m: &Machine, entries: Vec<(String, u64)>) -> u64 {
    let obj = new_object(m, "NSDictionary");
    state(m).lock().unwrap().dicts.insert(obj, entries);
    obj
}

/// After each presented frame (Metal calls it): deliver the --click events due at `frame`. The
/// pointer arrives, is pressed a frame later and released a frame after that, as a tap reaches
/// the client through Tolkara's AppKit (hover, then down, then up).
pub fn on_frame(m: &Machine, frame: u64) {
    let st = state(m);
    let mut st = st.lock().unwrap();
    let due: Vec<(u32, f64, f64)> = st
        .clicks
        .iter()
        .flat_map(|&(at, x, y)| [5u32, 1, 2].into_iter().enumerate().filter(move |(step, _)| at + *step as u64 == frame).map(move |(_, t)| (t, x, y)))
        .collect();
    st.events.extend(due);
}

/// Stop delivering scripted clicks (the game reached a server: none may land on its screens).
pub fn stop_clicks(m: &Machine) -> bool {
    let st = state(m);
    let mut st = st.lock().unwrap();
    let pending = !st.events.is_empty() || !st.clicks.is_empty();
    st.events.clear();
    st.clicks.clear();
    pending
}

#[cfg(test)]
mod tests {
    use super::*;

    fn machine() -> std::sync::Arc<Machine> {
        Machine::new(crate::Options::default())
    }

    #[test]
    fn click_specs() {
        assert_eq!(parse_click("100,200").unwrap(), (30, 100.0, 200.0));
        assert_eq!(parse_click("1.5,2@7").unwrap(), (7, 1.5, 2.0));
        assert!(parse_click("1@2").is_err());
        assert!(parse_click("a,b").is_err());
    }

    #[test]
    fn clicks_become_hover_down_up() {
        let m = machine();
        state(&m).lock().unwrap().clicks = vec![(3, 10.0, 20.0)];
        for frame in 1..=6 {
            on_frame(&m, frame);
        }
        let events: Vec<u32> = state(&m).lock().unwrap().events.iter().map(|e| e.0).collect();
        assert_eq!(events, [5, 1, 2]);
        assert!(stop_clicks(&m));
        assert!(!stop_clicks(&m));
    }

    #[test]
    fn strings_and_dictionaries_round_trip() {
        let m = machine();
        let s = new_string(&m, "héllo");
        assert_eq!(string_value(&m, s).as_deref(), Some("héllo"));
        assert_eq!(string_value(&m, new_object(&m, "NSObject")), None);
        let d = dictionary(&m, vec![("a".into(), 1), ("b".into(), s)]);
        assert_eq!(state(&m).lock().unwrap().dicts.get(&d), Some(&vec![("a".into(), 1), ("b".into(), s)]));
        assert!(!state(&m).lock().unwrap().dicts.contains_key(&s));
        let a = new_array(&m, vec![s, d]);
        assert_eq!(state(&m).lock().unwrap().arrays[&a], vec![s, d]);
        assert_eq!(m.memory.u64(s), m.data_symbol("_OBJC_CLASS_$_NSString"));
    }

    #[test]
    fn constant_strings_read_in_place() {
        let m = machine();
        let class = m.data_symbol("___CFConstantStringClassReference");
        let text = m.new_cstring("constant");
        let obj = m.alloc(32);
        m.memory.set_u64(obj, class);
        m.memory.set_u64(obj + 16, text);
        m.memory.set_u64(obj + 24, 8);
        assert_eq!(string_value(&m, obj).as_deref(), Some("constant"));
    }

    #[test]
    fn encodings() {
        let utf16 = 0x9400_0100;
        assert_eq!(encode("hi", utf16), b"h\0i\0");
        assert_eq!(decode(b"h\0i\0", utf16), "hi");
        assert_eq!(encode("é", 1), b"?");
        assert_eq!(encode("é", 5), [0xE9]);
        assert_eq!(terminator(utf16), b"\0\0");
        assert_eq!(terminator(4), b"\0");
    }

    #[test]
    fn image_formats_and_counts() {
        assert_eq!(image_format(b"\x89PNG\r\n\x1a\n"), "PNG");
        assert_eq!(image_format(b""), "");
        assert_eq!(image_format(&[1, 2]), "0102");
        assert_eq!(format_counts(&["PNG".into(), "JPEG".into(), "PNG".into()]), "{'PNG': 2, 'JPEG': 1}");
        assert_eq!(format_counts(&[]), "{}");
    }

    /// The real client's classes, read after loading (skipped without a client and adapters).
    #[test]
    fn client_class_metadata() {
        let Ok(app) = crate::settings::client_app(None) else { return };
        let frameworks = crate::settings::build_dir().join("ios/Payload/BrighterPocket.app/Frameworks");
        if !frameworks.join("aklibsteam_api.dylib").is_file() {
            return;
        }
        let m = machine();
        let loaded = crate::loader::load(&m, &app, &frameworks).expect("the client loads");
        let section = loaded.client.section("__DATA_CONST", "__objc_classlist").or_else(|| loaded.client.section("__DATA", "__objc_classlist"));
        let section = section.expect("a class list");
        let classes = read_client_classes(&m.memory, (section.addr, section.size));
        let view = classes.values().find(|c| c.name == "MyWindowView").expect("MyWindowView");
        assert!(view.methods.contains_key("mouseDown:"));
        assert!(view.instance_size > 0);
        for info in classes.values() {
            for &implementation in info.methods.values().chain(info.class_methods.values()) {
                assert!((crate::machine::CLIENT_BASE..crate::machine::ADAPTER_BASE).contains(&implementation), "{}", info.name);
            }
        }
    }
}
