//! The client's shader libraries: the on-device rewrap's checks (tools/check_shaders.py,
//! `accepts`, as pocket/patches/0003 makes them) and the shader bundles they come from
//! (tools/translate_shaders.py, `distinct_libraries`).
//!
//! A bundle is a big-endian u32 header size, a zstd frame holding the object count and one
//! varint length per object, then one zstd frame per object; an object is one or more (u32
//! little-endian size, MTLB) pairs.
use std::collections::BTreeMap;
use std::io::Read;
use std::path::Path;

use sha2::{Digest, Sha256};

/// assetBundle4 holds the fragment shaders, assetBundle7 the vertex shaders.
pub const SHADER_BUNDLES: [u32; 2] = [4, 7];

/// The little-endian number at `at`, `count` bytes long; bytes past the end read as zero.
fn number(b: &[u8], at: u64, count: u64) -> u64 {
    let mut value = 0u64;
    for i in 0..count {
        let byte = usize::try_from(at + i).ok().and_then(|i| b.get(i)).copied().unwrap_or(0);
        value |= (byte as u64) << (8 * i);
    }
    value
}

/// `b[from..from + count]`, cut short at the end as Python's slices are.
fn bytes(b: &[u8], from: u64, count: u64) -> &[u8] {
    let start = (from as usize).min(b.len());
    let end = (from.saturating_add(count) as usize).min(b.len());
    &b[start..end]
}

/// The SHA-256 of `data` in lowercase hex: the adapter's name for a library.
pub fn sha256_hex(data: &[u8]) -> String {
    Sha256::digest(data).iter().map(|byte| format!("{byte:02x}")).collect()
}

/// LibraryContainer.m airMinor(): legacy containers 2, 3, 5 hold AIR 2.0, 2.1, 2.3; current
/// 7, 8 hold 2.6, 2.7.
fn air_minor(container: u8) -> Option<u64> {
    match container {
        2 => Some(0),
        3 => Some(1),
        5 => Some(3),
        7 => Some(6),
        8 => Some(7),
        _ => None,
    }
}

/// LegacyMetal.h AKMetalModuleEnd(): the next function's module offset after this one, else the
/// code section's end.
fn module_end(b: &[u8], table: u64, public_start: u64, offset: u64, code_size: u64) -> u64 {
    let mut end = code_size.max(offset);
    if public_start < table || public_start - table < 4 {
        return end;
    }
    let (count, mut pos) = (number(b, table, 4), table + 4);
    for _ in 0..count {
        if public_start - pos < 4 {
            break;
        }
        let size = number(b, pos, 4);
        if size < 8 || size > public_start - pos {
            break;
        }
        let record_end = pos + size;
        pos += 4;
        while record_end - pos >= 6 {
            let tag = bytes(b, pos, 4);
            if tag == b"ENDT" {
                break;
            }
            let n = number(b, pos + 4, 2);
            pos += 6;
            if n > record_end - pos {
                break;
            }
            if tag == b"OFFT" && n == 24 {
                let other = number(b, pos + 16, 8);
                if offset < other && other < end {
                    end = other;
                }
            }
            pos += n;
        }
        pos = record_end;
    }
    end
}

/// None when AKLocalMetalLibraryData would rewrap this library for iOS, else why not.
/// `air1_libraries`: with pocket/patches/0003 (AIR 1.x libraries in container 2), else the
/// pinned Tolkara's rules.
pub fn accepts(b: &[u8], air1_libraries: bool) -> Option<String> {
    let length = b.len() as u64;
    if length < 88 || length > 64 * 1024 * 1024 || &b[..8] != b"MTLB\x01\x80\x02\x00" {
        return Some("not a macOS Metal library of a known platform header".into());
    }
    let container = b[8];
    let Some(minor) = air_minor(container) else { return Some(format!("container version {container} unknown")) };
    let legacy = container < 7;
    if number(b, 16, 8) != length {
        return Some("size field does not match".into());
    }
    if legacy && number(b, 9, 7) != 0 {
        return Some("legacy header bytes not zero".into());
    }
    if !legacy && (b[9] != 0 || b[10] != 0 || b[11] != 0x81 || b[12] == 0 || number(b, 13, 3) != 0) {
        return Some("current header does not name macOS".into());
    }
    let field = |i: u64| number(b, 24 + 8 * i, 8);
    let (table, table_size, public, public_size) = (field(0), field(1), field(2), field(3));
    let (private, private_size, code, code_size) = (field(4), field(5), field(6), field(7));
    let section = |offset: u64, size: u64| (88..=length).contains(&offset) && size <= length - offset;
    if !(section(table, table_size)
        && section(public, public_size)
        && section(private, private_size)
        && section(code, code_size)
        && table <= public
        && public - table >= 4
        && table_size <= public - table
        && private >= public
        && public_size <= private - public
        && code >= private
        && private_size <= code - private)
    {
        return Some("sections out of order or outside the file".into());
    }
    let (count, mut pos) = (number(b, table, 4), table + 4);
    if count == 0 || count > 65536 {
        return Some("function count out of range".into());
    }
    for _ in 0..count {
        if pos > public || public - pos < 4 {
            return Some("function table cut short".into());
        }
        let size = number(b, pos, 4);
        if size < 8 || size > public - pos {
            return Some("function record size out of range".into());
        }
        let end = pos + size;
        pos += 4;
        let (mut hash, mut offt, mut mdsz, mut vers): (Option<&[u8]>, Option<&[u8]>, Option<&[u8]>, Option<&[u8]>) =
            (None, None, None, None);
        let mut terminated = false;
        while end - pos >= 4 {
            let tag = bytes(b, pos, 4);
            pos += 4;
            if tag == b"ENDT" {
                terminated = true;
                break;
            }
            if end - pos < 2 {
                return Some("tag cut short".into());
            }
            let n = number(b, pos, 2);
            pos += 2;
            if n > end - pos {
                return Some("tag runs past its record".into());
            }
            let (slot, required) = match tag {
                b"HASH" => (&mut hash, 32),
                b"OFFT" => (&mut offt, 24),
                b"MDSZ" => (&mut mdsz, 8),
                b"VERS" => (&mut vers, 8),
                _ => {
                    pos += n;
                    continue;
                }
            };
            if slot.is_some() || n != required {
                return Some(format!("{} repeated or of the wrong size", String::from_utf8_lossy(tag)));
            }
            *slot = Some(bytes(b, pos, n));
            pos += n;
        }
        // pocket/patches/0003: AIR 1.x in container 2 names no module size (LegacyMetal.h).
        let air1 = air1_libraries && container == 2 && vers.is_some_and(|v| number(v, 0, 2) == 1);
        let (Some(hash), Some(offt), Some(version)) = (hash, offt, vers) else {
            return Some("function record incomplete".into());
        };
        if !terminated || pos != end || (mdsz.is_none() && !air1) {
            return Some("function record incomplete".into());
        }
        if !air1 && (number(version, 0, 2) != 2 || number(version, 2, 2) != minor) {
            return Some("AIR version does not match the container".into());
        }
        let offset = number(offt, 16, 8);
        let n = match mdsz {
            Some(size) => number(size, 0, 8),
            None => module_end(b, table, public, offset, code_size) - offset,
        };
        if offset > code_size || n > code_size - offset || n < 24 {
            return Some("module outside the code section".into());
        }
        let module = bytes(b, code + offset, n);
        let (start, bitcode) = (number(module, 8, 4), number(module, 12, 4));
        if number(module, 0, 4) != 0x0B17_C0DE
            || number(module, 4, 4) != 0
            || start < 20
            || start > n
            || bitcode < 4
            || bitcode > n - start
            || bytes(module, start, 4) != b"BC\xc0\xde"
        {
            return Some("module is not wrapped LLVM bitcode".into());
        }
        if Sha256::digest(module).as_slice() != hash {
            return Some("module hash does not match".into());
        }
    }
    None
}

/// A LEB128 number at `at`, and where the next one starts.
fn varint(b: &[u8], mut at: usize) -> Result<(u64, usize), String> {
    let (mut value, mut shift) = (0u64, 0u32);
    loop {
        let byte = *b.get(at).ok_or("a varint runs past the header")?;
        at += 1;
        if shift < 64 {
            value |= ((byte & 0x7F) as u64) << shift;
        }
        shift += 7;
        if byte & 0x80 == 0 {
            return Ok((value, at));
        }
    }
}

/// One zstd frame's contents.
fn decompress(frame: &[u8]) -> Result<Vec<u8>, String> {
    let mut decoder = ruzstd::decoding::StreamingDecoder::new(frame).map_err(|e| e.to_string())?;
    let mut out = Vec::new();
    decoder.read_to_end(&mut out).map_err(|e| e.to_string())?;
    Ok(out)
}

/// Every Metal library in a shader bundle, in order.
pub fn libraries(bundle: &Path) -> Result<Vec<Vec<u8>>, String> {
    let name = bundle.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let data = std::fs::read(bundle).map_err(|e| format!("{}: {e}", bundle.display()))?;
    let header_size = u32::from_be_bytes(data.get(..4).ok_or(format!("{name}: no header"))?.try_into().unwrap()) as usize;
    let header = decompress(data.get(4..4 + header_size).ok_or(format!("{name}: the header runs past the file"))?)
        .map_err(|e| format!("{name}: header: {e}"))?;
    let (count, mut at) = varint(&header, 0)?;
    let mut start = 4 + header_size;
    let mut found = Vec::new();
    for index in 0..count {
        let length;
        (length, at) = varint(&header, at)?;
        let frame = data.get(start..start + length as usize).ok_or(format!("{name} object {index}: runs past the file"))?;
        let object = decompress(frame).map_err(|e| format!("{name} object {index}: {e}"))?;
        start += length as usize;
        let mut pos = 0;
        while pos < object.len() {
            let size = number(&object, pos as u64, 4) as usize;
            if pos + 4 + size > object.len() {
                return Err(format!("{name} object {index}: a library runs past the object"));
            }
            found.push(object[pos + 4..pos + 4 + size].to_vec());
            pos += 4 + size;
        }
    }
    if start != data.len() {
        return Err(format!("{name}: the object table does not cover the file"));
    }
    Ok(found)
}

/// key (SHA-256 of the bytes) -> library, for every library in the two shader bundles.
pub fn distinct_libraries(app: &Path) -> Result<BTreeMap<String, Vec<u8>>, String> {
    let mut found = BTreeMap::new();
    for number in SHADER_BUNDLES {
        for library in libraries(&app.join(format!("Contents/Resources/assetBundle{number}")))? {
            found.insert(sha256_hex(&library), library);
        }
    }
    Ok(found)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A library of one function: container `container`, AIR `major.minor`, with or without MDSZ.
    fn library(container: u8, major: u16, minor: u16, with_size: bool) -> Vec<u8> {
        let mut module = Vec::new();
        module.extend(0x0B17_C0DEu32.to_le_bytes());
        module.extend(0u32.to_le_bytes());
        module.extend(20u32.to_le_bytes()); // bitcode start
        module.extend(8u32.to_le_bytes()); // bitcode size
        module.extend(0u32.to_le_bytes());
        module.extend(b"BC\xc0\xde\0\0\0\0");
        let mut record = Vec::new();
        let mut tag = |name: &[u8], value: &[u8]| {
            record.extend(name);
            record.extend((value.len() as u16).to_le_bytes());
            record.extend(value);
        };
        tag(b"NAME", b"f\0");
        tag(b"HASH", &Sha256::digest(&module));
        tag(b"OFFT", &[0u8; 24]);
        if with_size {
            tag(b"MDSZ", &(module.len() as u64).to_le_bytes());
        }
        let mut version = major.to_le_bytes().to_vec();
        version.extend(minor.to_le_bytes());
        version.extend([0u8; 4]);
        tag(b"VERS", &version);
        record.extend(b"ENDT");
        let mut table = 1u32.to_le_bytes().to_vec();
        table.extend((record.len() as u32 + 4).to_le_bytes());
        table.extend(record);
        let table_at = 88u64;
        let public = table_at + table.len() as u64;
        let code = public;
        let length = code + module.len() as u64;
        let mut b = b"MTLB\x01\x80\x02\x00".to_vec();
        b.push(container);
        if container >= 7 {
            b.extend([0, 0, 0x81, 1, 0, 0, 0]);
        } else {
            b.extend([0u8; 7]);
        }
        for value in [length, table_at, table.len() as u64, public, 0, public, 0, code, module.len() as u64] {
            b.extend(value.to_le_bytes());
        }
        b.extend(table);
        b.extend(module);
        assert_eq!(b.len() as u64, length);
        b
    }

    #[test]
    fn accepts_what_the_rewrap_reads() {
        assert_eq!(accepts(&library(7, 2, 6, true), true), None);
        assert_eq!(accepts(&library(2, 2, 0, true), true), None);
        // AIR 1.x in container 2 names no module size: its end is the code section's.
        assert_eq!(accepts(&library(2, 1, 8, false), true), None);
        assert_eq!(accepts(&library(2, 1, 8, false), false).as_deref(), Some("function record incomplete"));
        assert_eq!(accepts(&library(2, 1, 8, true), false).as_deref(), Some("AIR version does not match the container"));
        assert_eq!(accepts(&library(7, 2, 7, true), true).as_deref(), Some("AIR version does not match the container"));
        assert_eq!(accepts(&library(7, 2, 6, false), true).as_deref(), Some("function record incomplete"));
    }

    #[test]
    fn refuses_what_it_cannot() {
        let good = library(7, 2, 6, true);
        let refused = |change: &dyn Fn(&mut Vec<u8>)| {
            let mut b = good.clone();
            change(&mut b);
            accepts(&b, true)
        };
        assert_eq!(refused(&|b| b[0] = b'X').as_deref(), Some("not a macOS Metal library of a known platform header"));
        assert_eq!(refused(&|b| b[8] = 4).as_deref(), Some("container version 4 unknown"));
        assert_eq!(refused(&|b| b[16] ^= 1).as_deref(), Some("size field does not match"));
        assert_eq!(refused(&|b| b[11] = 0).as_deref(), Some("current header does not name macOS"));
        assert_eq!(refused(&|b| b[24] = 80).as_deref(), Some("sections out of order or outside the file"));
        assert_eq!(refused(&|b| b[88] = 0).as_deref(), Some("function count out of range"));
        let last = good.len() - 1;
        assert_eq!(refused(&|b| b[last] ^= 1).as_deref(), Some("module hash does not match"));
        let code = number(&good, 24 + 8 * 6, 8) as usize;
        assert_eq!(refused(&|b| b[code] = 0).as_deref(), Some("module is not wrapped LLVM bitcode"));
        let mdsz = good.windows(4).position(|w| w == b"MDSZ").unwrap();
        assert_eq!(refused(&|b| b[mdsz + 4] = 4).as_deref(), Some("MDSZ repeated or of the wrong size"));
    }

    #[test]
    fn module_end_is_the_next_function_or_the_code_end() {
        // Two records whose OFFT names 0 and 40: the first module ends at 40.
        let mut table = 2u32.to_le_bytes().to_vec();
        for offset in [0u64, 40] {
            let mut offt = [0u8; 24];
            offt[16..].copy_from_slice(&offset.to_le_bytes());
            let mut record = b"OFFT".to_vec();
            record.extend(24u16.to_le_bytes());
            record.extend(offt);
            record.extend(b"ENDT");
            table.extend((record.len() as u32 + 4).to_le_bytes());
            table.extend(record);
        }
        let public = table.len() as u64;
        assert_eq!(module_end(&table, 0, public, 0, 100), 40);
        assert_eq!(module_end(&table, 0, public, 40, 100), 100);
    }

    #[test]
    fn reads_varints() {
        assert_eq!(varint(&[0x05], 0), Ok((5, 1)));
        assert_eq!(varint(&[0xE5, 0x8E, 0x26], 0), Ok((624485, 3)));
        assert!(varint(&[0x80], 0).is_err());
    }

    #[test]
    fn hashes_as_sha256() {
        assert_eq!(sha256_hex(b"abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    }

    /// The real client's bundles, as tools/check_shaders.py and tools/translate_shaders.py read
    /// them (skipped without a downloaded client).
    #[test]
    fn the_clients_libraries() {
        let Ok(app) = crate::settings::client_app(None) else {
            eprintln!("no downloaded client: skipped");
            return;
        };
        let mut total = 0;
        for number in SHADER_BUNDLES {
            let found = libraries(&app.join(format!("Contents/Resources/assetBundle{number}"))).unwrap();
            total += found.len();
            for library in &found {
                assert_eq!(accepts(library, true), None);
                // As the pinned Tolkara has them: every one refused (AIR 1.8 names no module size).
                assert_eq!(accepts(library, false).as_deref(), Some("function record incomplete"));
            }
        }
        assert_eq!(total, 536);
        // tools/translate_shaders.py --keys: 500 keys; the SHA-256 of them sorted, one a line.
        let keys: Vec<String> = distinct_libraries(&app).unwrap().into_keys().collect();
        assert_eq!(keys.len(), 500);
        assert_eq!(sha256_hex(keys.join("\n").as_bytes()), "921999a84c76fb6da495040448157b687417e4151e9773888fba724b3b585bdc");
    }
}
