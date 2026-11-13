//! The part of tools/macho.py the emulator needs: thin a fat file, read one 64-bit little-endian
//! image's segments, sections, dylibs, entry, exports trie and chained fixups.
use std::collections::HashMap;

const FAT_MAGIC: u32 = 0xCAFE_BABE;
const FAT_MAGIC_64: u32 = 0xCAFE_BABF;
const MH_MAGIC_64: u32 = 0xFEED_FACF;
const CPU_ARM64: u32 = 0x0100_000C;

const LC_REQ_DYLD: u32 = 0x8000_0000;
const LC_LOAD_DYLIB: u32 = 0xC;
const LC_LOAD_WEAK_DYLIB: u32 = 0x18 | LC_REQ_DYLD;
const LC_SEGMENT_64: u32 = 0x19;
const LC_REEXPORT_DYLIB: u32 = 0x1F | LC_REQ_DYLD;
const LC_MAIN: u32 = 0x28 | LC_REQ_DYLD;
const LC_DYLD_EXPORTS_TRIE: u32 = 0x33 | LC_REQ_DYLD;
const LC_DYLD_CHAINED_FIXUPS: u32 = 0x34 | LC_REQ_DYLD;
const LC_DYLD_INFO: u32 = 0x22;
const LC_DYLD_INFO_ONLY: u32 = 0x22 | LC_REQ_DYLD;
const LC_FUNCTION_STARTS: u32 = 0x26;

// dyld_chained_ptr formats this reader walks (mach-o/fixup-chains.h).
const DYLD_CHAINED_PTR_64: u16 = 2;
const DYLD_CHAINED_PTR_64_OFFSET: u16 = 6;
const DYLD_CHAINED_PTR_START_NONE: u16 = 0xFFFF;
const DYLD_CHAINED_PTR_START_MULTI: u16 = 0x8000;

#[derive(Clone, Debug)]
pub struct Segment {
    pub name: String,
    pub vmaddr: u64,
    pub vmsize: u64,
    pub fileoff: u64,
    pub filesize: u64,
}

#[derive(Clone, Debug)]
pub struct Section {
    pub segment: String,
    pub name: String,
    pub addr: u64,
    pub size: u64,
    pub offset: u32,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Import {
    pub name: String,
    pub ordinal: i32, // 1-based index into dylibs, or a special ordinal (0, -1, -2, -3)
    pub weak: bool,
    pub addend: i64,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Fixup {
    /// `target` is unslid: add the slide, then OR in `high8 << 56`.
    Rebase { target: u64, high8: u8 },
    /// `import` indexes imports(); `addend` adds to the import's own addend.
    Bind { import: u32, addend: i64 },
}

pub struct Image {
    pub data: Vec<u8>,
    pub segments: Vec<Segment>,
    pub sections: Vec<Section>,
    pub dylibs: Vec<String>,
    entry: Option<u64>,
    chained: Option<(u32, u32)>,
    function_starts: Option<(u32, u32)>,
    imports: Vec<Import>,
    exports: HashMap<String, u64>,
}

fn u16_at(data: &[u8], at: usize) -> Result<u16, String> {
    data.get(at..at + 2).map(|b| u16::from_le_bytes(b.try_into().unwrap())).ok_or_else(|| format!("read past the end at {at:#x}"))
}

fn u32_at(data: &[u8], at: usize) -> Result<u32, String> {
    data.get(at..at + 4).map(|b| u32::from_le_bytes(b.try_into().unwrap())).ok_or_else(|| format!("read past the end at {at:#x}"))
}

fn u64_at(data: &[u8], at: usize) -> Result<u64, String> {
    data.get(at..at + 8).map(|b| u64::from_le_bytes(b.try_into().unwrap())).ok_or_else(|| format!("read past the end at {at:#x}"))
}

fn be32(data: &[u8], at: usize) -> Result<u32, String> {
    data.get(at..at + 4).map(|b| u32::from_be_bytes(b.try_into().unwrap())).ok_or_else(|| format!("read past the end at {at:#x}"))
}

fn be64(data: &[u8], at: usize) -> Result<u64, String> {
    data.get(at..at + 8).map(|b| u64::from_be_bytes(b.try_into().unwrap())).ok_or_else(|| format!("read past the end at {at:#x}"))
}

fn uleb(data: &[u8], mut at: usize) -> Result<(u64, usize), String> {
    let (mut value, mut shift) = (0u64, 0u32);
    loop {
        let byte = *data.get(at).ok_or("ULEB128 runs past its data")?;
        at += 1;
        if shift < 64 {
            value |= u64::from(byte & 0x7F) << shift;
        }
        shift += 7;
        if byte & 0x80 == 0 {
            return Ok((value, at));
        }
    }
}

fn cstring(data: &[u8], at: usize, limit: usize) -> Result<String, String> {
    let window = data.get(at..data.len().min(at + limit)).ok_or_else(|| format!("unterminated string at {at:#x}"))?;
    let end = window.iter().position(|&b| b == 0).ok_or_else(|| format!("unterminated string at {at:#x}"))?;
    Ok(String::from_utf8_lossy(&window[..end]).into_owned())
}

/// A fixed-width name field, up to its first NUL.
fn name16(data: &[u8]) -> String {
    let end = data.iter().position(|&b| b == 0).unwrap_or(data.len());
    String::from_utf8_lossy(&data[..end]).into_owned()
}

impl Image {
    /// The arm64 image of a fat file, byte for byte (lipo -thin), or a thin file itself.
    pub fn thin(file: &[u8]) -> Result<Vec<u8>, String> {
        if file.len() < 8 {
            return Err("too short for a Mach-O file".into());
        }
        let magic = be32(file, 0)?;
        if magic == FAT_MAGIC || magic == FAT_MAGIC_64 {
            for i in 0..be32(file, 4)? as usize {
                let (cpu, offset, size) = if magic == FAT_MAGIC {
                    let at = 8 + 20 * i;
                    (be32(file, at)?, u64::from(be32(file, at + 8)?), u64::from(be32(file, at + 12)?))
                } else {
                    let at = 8 + 32 * i;
                    (be32(file, at)?, be64(file, at + 8)?, be64(file, at + 16)?)
                };
                if offset + size > file.len() as u64 {
                    return Err(format!("slice {i} runs past the end of the file"));
                }
                if cpu == CPU_ARM64 {
                    return Ok(file[offset as usize..(offset + size) as usize].to_vec());
                }
            }
            return Err("no arm64 slice".into());
        }
        if u32_at(file, 0)? == MH_MAGIC_64 {
            if u32_at(file, 4)? != CPU_ARM64 {
                return Err("no arm64 slice".into());
            }
            return Ok(file.to_vec());
        }
        Err(format!("not a 64-bit Mach-O or fat file (magic {magic:#x})"))
    }

    pub fn parse(data: Vec<u8>) -> Result<Image, String> {
        if data.len() < 32 || u32_at(&data, 0)? != MH_MAGIC_64 {
            return Err("not a thin 64-bit little-endian Mach-O image".into());
        }
        let ncmds = u32_at(&data, 16)?;
        let sizeofcmds = u32_at(&data, 20)? as usize;
        if 32 + sizeofcmds > data.len() {
            return Err("load commands run past the end of the image".into());
        }
        let mut image = Image {
            data: Vec::new(),
            segments: Vec::new(),
            sections: Vec::new(),
            dylibs: Vec::new(),
            entry: None,
            chained: None,
            function_starts: None,
            imports: Vec::new(),
            exports: HashMap::new(),
        };
        let mut exports_trie = None;
        let mut at = 32;
        for _ in 0..ncmds {
            let cmd = u32_at(&data, at)?;
            let size = u32_at(&data, at + 4)? as usize;
            if size < 8 || at + size > 32 + sizeofcmds {
                return Err(format!("load command {cmd:#x} has a bad size"));
            }
            let body = &data[at..at + size];
            match cmd {
                LC_SEGMENT_64 => {
                    let name = name16(body.get(8..24).ok_or("segment command cut short")?);
                    let nsects = u32_at(body, 64)? as usize;
                    for i in 0..nsects {
                        let s = body.get(72 + 80 * i..152 + 80 * i).ok_or("section header cut short")?;
                        image.sections.push(Section {
                            segment: name.clone(),
                            name: name16(&s[..16]),
                            addr: u64_at(s, 32)?,
                            size: u64_at(s, 40)?,
                            offset: u32_at(s, 48)?,
                        });
                    }
                    image.segments.push(Segment {
                        name,
                        vmaddr: u64_at(body, 24)?,
                        vmsize: u64_at(body, 32)?,
                        fileoff: u64_at(body, 40)?,
                        filesize: u64_at(body, 48)?,
                    });
                }
                LC_LOAD_DYLIB | LC_LOAD_WEAK_DYLIB | LC_REEXPORT_DYLIB => {
                    image.dylibs.push(cstring(body, u32_at(body, 8)? as usize, 4096)?);
                }
                LC_MAIN => image.entry = Some(u64_at(body, 8)?),
                LC_DYLD_CHAINED_FIXUPS => image.chained = Some((u32_at(body, 8)?, u32_at(body, 12)?)),
                LC_FUNCTION_STARTS => image.function_starts = Some((u32_at(body, 8)?, u32_at(body, 12)?)),
                LC_DYLD_EXPORTS_TRIE => exports_trie = Some((u32_at(body, 8)?, u32_at(body, 12)?)),
                LC_DYLD_INFO | LC_DYLD_INFO_ONLY => {
                    let (off, size) = (u32_at(body, 40)?, u32_at(body, 44)?);
                    if size != 0 {
                        exports_trie = Some((off, size));
                    }
                }
                _ => {}
            }
            at += size;
        }
        image.data = data;
        if image.chained.is_some() {
            image.imports = image.read_imports()?;
        }
        if let Some((off, size)) = exports_trie {
            let trie = image.data.get(off as usize..(off + size) as usize).ok_or("exports trie runs past the image")?;
            image.exports = read_exports(trie)?;
        }
        Ok(image)
    }

    pub fn segment(&self, name: &str) -> Option<&Segment> {
        self.segments.iter().find(|s| s.name == name)
    }

    pub fn section(&self, segment: &str, name: &str) -> Option<&Section> {
        self.sections.iter().find(|s| s.segment == segment && s.name == name)
    }

    pub fn imports(&self) -> &[Import] {
        &self.imports
    }

    pub fn library(&self, ordinal: i32) -> String {
        match ordinal {
            0 => "<self>".into(),
            -1 => "<main-executable>".into(),
            -2 => "<flat-namespace>".into(),
            -3 => "<weak-def-coalesce>".into(),
            n if n >= 1 && (n as usize) <= self.dylibs.len() => self.dylibs[n as usize - 1].clone(),
            n => format!("<library ordinal {n} out of range>"),
        }
    }

    /// Exported names and their trie addresses (offsets from the Mach-O header), re-exports left out.
    pub fn exports(&self) -> &HashMap<String, u64> {
        &self.exports
    }

    pub fn base(&self) -> u64 {
        self.segment("__TEXT").map_or(0, |s| s.vmaddr)
    }

    pub fn entry(&self) -> Option<u64> {
        self.entry
    }

    /// Every function's start (LC_FUNCTION_STARTS: ULEB128 deltas from the image's base), as
    /// unslid vmaddrs in order; empty when the image has none.
    pub fn function_starts(&self) -> Vec<u64> {
        let Some((off, size)) = self.function_starts else { return Vec::new() };
        let Some(blob) = self.data.get(off as usize..(off + size) as usize) else { return Vec::new() };
        let (mut starts, mut address, mut at) = (Vec::new(), self.base(), 0);
        while at < blob.len() {
            let (mut delta, mut shift) = (0u64, 0);
            while at < blob.len() {
                let byte = blob[at];
                at += 1;
                delta |= ((byte & 0x7F) as u64) << shift;
                shift += 7;
                if byte < 0x80 {
                    break;
                }
            }
            if delta == 0 {
                break;
            }
            address += delta;
            starts.push(address);
        }
        starts
    }

    fn header(&self) -> Result<(&[u8], [u32; 7]), String> {
        let (off, size) = self.chained.ok_or("no LC_DYLD_CHAINED_FIXUPS (opcode fixups are not read here)")?;
        let blob = self.data.get(off as usize..(off + size) as usize).ok_or("chained fixups run past the image")?;
        if blob.len() < 28 {
            return Err("chained fixups header is cut short".into());
        }
        let mut fields = [0u32; 7];
        for (i, f) in fields.iter_mut().enumerate() {
            *f = u32_at(blob, 4 * i)?;
        }
        Ok((blob, fields))
    }

    fn read_imports(&self) -> Result<Vec<Import>, String> {
        let (blob, [version, _, imports_off, symbols_off, count, fmt, symbols_fmt]) = self.header()?;
        if version != 0 || symbols_fmt != 0 {
            return Err(format!("chained fixups version {version}, symbol format {symbols_fmt} not read here"));
        }
        let (imports_off, symbols_off) = (imports_off as usize, symbols_off as usize);
        let mut out = Vec::with_capacity(count as usize);
        for i in 0..count as usize {
            let (ordinal, weak, name_off, addend) = match fmt {
                1 | 2 => {
                    // DYLD_CHAINED_IMPORT, DYLD_CHAINED_IMPORT_ADDEND
                    let width = if fmt == 1 { 4 } else { 8 };
                    let raw = u32_at(blob, imports_off + width * i)?;
                    let addend = if fmt == 2 { i64::from(u32_at(blob, imports_off + 8 * i + 4)? as i32) } else { 0 };
                    let ordinal = (raw & 0xFF) as i32;
                    (if ordinal >= 0xF0 { ordinal - 0x100 } else { ordinal }, (raw >> 8) & 1 != 0, (raw >> 9) as usize, addend)
                }
                3 => {
                    // DYLD_CHAINED_IMPORT_ADDEND64
                    let raw = u64_at(blob, imports_off + 16 * i)?;
                    let addend = u64_at(blob, imports_off + 16 * i + 8)? as i64;
                    let ordinal = (raw & 0xFFFF) as i32;
                    (if ordinal >= 0xFFF0 { ordinal - 0x10000 } else { ordinal }, (raw >> 16) & 1 != 0, (raw >> 32) as usize, addend)
                }
                _ => return Err(format!("chained import format {fmt} not read here")),
            };
            out.push(Import { name: cstring(blob, symbols_off + name_off, 4096)?, ordinal, weak, addend });
        }
        Ok(out)
    }

    /// Every chained fixup in chain order: the slot's unslid vmaddr and what goes there.
    pub fn fixups(&self) -> Result<Vec<(u64, Fixup)>, String> {
        let (blob, [_, starts_off, ..]) = self.header()?;
        let starts_off = starts_off as usize;
        let base = self.base();
        let mut out = Vec::new();
        for i in 0..u32_at(blob, starts_off)? as usize {
            let info = u32_at(blob, starts_off + 4 + 4 * i)? as usize;
            if info == 0 {
                continue;
            }
            let at = starts_off + info;
            let page_size = u64::from(u16_at(blob, at + 4)?);
            let fmt = u16_at(blob, at + 6)?;
            let page_count = u16_at(blob, at + 20)? as usize;
            if fmt != DYLD_CHAINED_PTR_64 && fmt != DYLD_CHAINED_PTR_64_OFFSET {
                return Err(format!("chained pointer format {fmt} not read here"));
            }
            let seg = self.segments.get(i).ok_or("chained starts name a segment that does not exist")?;
            for p in 0..page_count {
                let start = u16_at(blob, at + 22 + 2 * p)?;
                if start == DYLD_CHAINED_PTR_START_NONE {
                    continue;
                }
                if start & DYLD_CHAINED_PTR_START_MULTI != 0 {
                    return Err("multiple chain starts in a page are not read here".into());
                }
                let mut place = p as u64 * page_size + u64::from(start);
                loop {
                    if place + 8 > seg.filesize {
                        return Err("a chain runs past its segment".into());
                    }
                    let raw = u64_at(&self.data, (seg.fileoff + place) as usize)?;
                    let fixup = if raw >> 63 != 0 {
                        let import = (raw & 0xFF_FFFF) as u32;
                        if import as usize >= self.imports.len() {
                            return Err(format!("a bind names import {import} of {}", self.imports.len()));
                        }
                        Fixup::Bind { import, addend: ((raw >> 24) & 0xFF) as i64 }
                    } else {
                        let target = raw & ((1 << 36) - 1);
                        let high8 = ((raw >> 36) & 0xFF) as u8;
                        Fixup::Rebase { target: if fmt == DYLD_CHAINED_PTR_64_OFFSET { base + target } else { target }, high8 }
                    };
                    out.push((seg.vmaddr + place, fixup));
                    let step = (raw >> 51) & 0xFFF;
                    if step == 0 {
                        break;
                    }
                    place += step * 4;
                }
            }
        }
        Ok(out)
    }
}

fn read_exports(trie: &[u8]) -> Result<HashMap<String, u64>, String> {
    let mut out = HashMap::new();
    let mut stack = vec![(0usize, String::new())];
    let mut seen = std::collections::HashSet::new();
    while let Some((node, prefix)) = stack.pop() {
        if node >= trie.len() || !seen.insert(node) {
            return Err("exports trie loops or runs past its data".into());
        }
        let (info_size, mut at) = uleb(trie, node)?;
        if info_size != 0 {
            let (flags, p) = uleb(trie, at)?;
            if flags & 0x8 == 0 {
                // not a re-export
                out.insert(prefix.clone(), uleb(trie, p)?.0);
            }
        }
        at += info_size as usize;
        let children = *trie.get(at).ok_or("exports trie runs past its data")?;
        at += 1;
        for _ in 0..children {
            let label = cstring(trie, at, trie.len())?;
            let (child, next) = uleb(trie, at + label.len() + 1)?;
            at = next;
            stack.push((child as usize, format!("{prefix}{label}")));
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::settings;

    fn load(path: &std::path::Path) -> Image {
        Image::parse(Image::thin(&std::fs::read(path).unwrap()).unwrap()).unwrap()
    }

    fn client() -> Option<Image> {
        match settings::client_app(None) {
            Ok(app) => Some(load(&app.join(settings::BUNDLE_EXECUTABLE))),
            Err(e) => {
                eprintln!("skipped: {e}");
                None
            }
        }
    }

    fn adapter(name: &str) -> Option<Image> {
        let path = settings::build_dir().join("ios/Payload/BrighterPocket.app/Frameworks").join(name);
        if !path.is_file() {
            eprintln!("skipped: no {}", path.display());
            return None;
        }
        Some(load(&path))
    }

    /// The names the client imports from `library`.
    fn imported_from<'a>(image: &'a Image, library: &str) -> Vec<&'a str> {
        image.imports().iter().filter(|i| image.library(i.ordinal) == library).map(|i| i.name.as_str()).collect()
    }

    /// What the loader relies on, not what one build or compiler happens to produce: the image at
    /// its preferred base with its entry in __TEXT, the Steam and libSystem imports, every fixup
    /// naming an import that exists or a target inside the image, and each thread-local variable's
    /// descriptor bound to __tlv_bootstrap (src/loader.rs rewrites those).
    #[test]
    fn macho_client() {
        let Some(image) = client() else { return };
        assert_eq!(image.base(), 0x1_0000_0000);
        let text = image.segment("__TEXT").unwrap();
        let entry = image.entry().expect("an LC_MAIN entry");
        assert!(entry < text.vmsize, "the entry {entry:#x} is outside __TEXT");
        assert_eq!(image.library(-1), "<main-executable>");
        assert_eq!(image.exports().get("__mh_execute_header"), Some(&0));

        let imports = image.imports();
        let steam = imported_from(&image, "@loader_path/libsteam_api.dylib");
        assert!(steam.contains(&"_SteamAPI_RegisterCallback") && steam.contains(&"_SteamAPI_RunCallbacks"));
        let system = imported_from(&image, "/usr/lib/libSystem.B.dylib");
        for name in ["__tlv_bootstrap", "_connect", "_getaddrinfo", "_opendir"] {
            assert!(system.contains(&name), "the client no longer imports {name} from libSystem");
        }
        let tlv = imports.iter().position(|i| i.name == "__tlv_bootstrap").unwrap() as u32;

        let fixups = image.fixups().unwrap();
        let end = image.segments.iter().map(|s| s.vmaddr + s.vmsize).max().unwrap();
        for (at, fixup) in &fixups {
            match *fixup {
                Fixup::Bind { import, .. } => assert!((import as usize) < imports.len(), "a bind at {at:#x} names import {import}"),
                Fixup::Rebase { target, .. } => {
                    assert!((image.base()..end).contains(&target), "a rebase at {at:#x} targets {target:#x}")
                }
            }
        }
        let tv = image.section("__DATA", "__thread_vars").unwrap();
        assert!(tv.size > 0 && tv.size % 24 == 0);
        for descriptor in (tv.addr..tv.addr + tv.size).step_by(24) {
            let bound = fixups.iter().find(|(at, _)| *at == descriptor).map(|(_, f)| *f);
            assert!(matches!(bound, Some(Fixup::Bind { import, .. }) if import == tlv), "{descriptor:#x} is not bound to __tlv_bootstrap");
        }
    }

    /// The Steam adapter defines every Steam call the client imports (the loader stops otherwise).
    #[test]
    fn macho_adapter_steam_api() {
        let Some(image) = adapter("aklibsteam_api.dylib") else { return };
        assert_eq!(image.base(), 0);
        image.fixups().unwrap();
        let Some(client) = client() else { return };
        for name in imported_from(&client, "@loader_path/libsteam_api.dylib") {
            assert!(image.exports().contains_key(name), "the Steam adapter does not export {name}");
        }
    }

    /// The system adapter defines the calls the client's imports are bound to it for.
    #[test]
    fn macho_adapter_system() {
        let Some(image) = adapter("aklibSystem.B.dylib") else { return };
        assert_eq!(image.base(), 0);
        image.fixups().unwrap();
        assert!(image.exports().contains_key("_opendir"), "the system adapter does not export _opendir");
        for name in ["_connect", "_getaddrinfo"] {
            assert!(!image.exports().contains_key(name), "the system adapter still exports {name}");
        }
    }
}
