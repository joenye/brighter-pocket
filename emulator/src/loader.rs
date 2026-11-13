//! Loading: the client's arm64 slice at its own addresses, this layer's adapters (the app's
//! arm64 iOS builds) beside it, every chained fixup applied. A bind goes to an adapter's export
//! when the client imports it from that adapter's library and the adapter defines it (the
//! client's Steam calls, and its opendir: the container's paths), to an imported
//! data symbol when it is data, and to an answered import's slot otherwise.
use std::collections::HashMap;
use std::path::Path;

use crate::machine::{ADAPTER_BASE, LoadedImage, Machine};
use crate::macho::{Fixup, Image, Import};
use crate::memory::{PAGE, align};

pub struct Loaded {
    pub client: Image,
    pub client_fixups: (usize, usize),
    pub adapter_fixups: (usize, usize),
}

struct Mapped {
    image: Image,
    slide: u64,
    name: String,
    exports: HashMap<String, u64>,
}

fn map(m: &Machine, image: Image, slide: u64, name: &str) -> Mapped {
    for segment in &image.segments {
        if segment.name == "__PAGEZERO" || segment.vmsize == 0 {
            continue;
        }
        let start = slide + segment.vmaddr;
        m.memory.map(start & !(PAGE - 1), align(segment.vmsize + (start & (PAGE - 1)), PAGE));
        let file = &image.data[segment.fileoff as usize..(segment.fileoff + segment.filesize) as usize];
        m.memory.write(start, file);
    }
    let base = image.base();
    let exports = image.exports().iter().map(|(name, &offset)| (name.clone(), slide + base + offset)).collect();
    Mapped { image, slide, name: name.to_string(), exports }
}

/// Apply `image`'s chained fixups; (rebases, binds).
fn fix_up(m: &Machine, mapped: &Mapped, adapters: &HashMap<String, HashMap<String, u64>>, client: bool) -> Result<(usize, usize), String> {
    let imports = mapped.image.imports();
    let (mut rebases, mut binds) = (0, 0);
    for (vmaddr, fixup) in mapped.image.fixups()? {
        let slot = mapped.slide + vmaddr;
        match fixup {
            Fixup::Rebase { target, high8 } => {
                m.memory.set_u64(slot, (target + mapped.slide) | (high8 as u64) << 56);
                rebases += 1;
            }
            Fixup::Bind { import, addend } => {
                let import = &imports[import as usize];
                let address = resolve(m, &mapped.image, import, adapters, client)?;
                m.memory.set_u64(slot, address.wrapping_add((import.addend + addend) as u64));
                binds += 1;
            }
        }
    }
    Ok((rebases, binds))
}

fn resolve(m: &Machine, image: &Image, import: &Import, adapters: &HashMap<String, HashMap<String, u64>>, client: bool) -> Result<u64, String> {
    let library = image.library(import.ordinal);
    let leaf = library.rsplit('/').next().unwrap_or(&library);
    if client {
        if let Some(exports) = adapters.get(leaf) {
            if let Some(&address) = exports.get(&import.name) {
                return Ok(address);
            }
            if leaf == "libsteam_api.dylib" {
                return Err(format!("the Steam adapter does not export {}", import.name));
            }
        }
    }
    if m.hle.has_data(&import.name) || import.name.starts_with("_OBJC_CLASS_$_") || import.name.starts_with("_OBJC_METACLASS_$_") {
        return Ok(m.data_symbol(&import.name));
    }
    Ok(m.slot_address(&import.name))
}

/// Load the client from `app` and the adapters from `frameworks` (the app's Frameworks folder).
pub fn load(m: &Machine, app: &Path, frameworks: &Path) -> Result<Loaded, String> {
    let read = |path: &Path| std::fs::read(path).map_err(|e| format!("{}: {e}", path.display()));
    let executable = read(&app.join(crate::settings::BUNDLE_EXECUTABLE))?;
    let client = map(m, Image::parse(Image::thin(&executable)?)?, 0, "client");
    let adapters = [
        ("libsteam_api.dylib", "aklibsteam_api.dylib", ADAPTER_BASE),
        ("libSystem.B.dylib", "aklibSystem.B.dylib", ADAPTER_BASE + 0x1000_0000),
    ]
    .into_iter()
    .map(|(library, file, slide)| {
        let image = Image::parse(read(&frameworks.join(file))?)?;
        Ok((library.to_string(), map(m, image, slide, file.trim_end_matches(".dylib"))))
    })
    .collect::<Result<Vec<_>, String>>()?;
    let exports: HashMap<String, HashMap<String, u64>> = adapters.iter().map(|(library, a)| (library.clone(), a.exports.clone())).collect();
    let client_fixups = fix_up(m, &client, &exports, true)?;
    let mut adapter_fixups = (0, 0);
    for (_, adapter) in &adapters {
        let (r, b) = fix_up(m, adapter, &exports, false)?;
        adapter_fixups = (adapter_fixups.0 + r, adapter_fixups.1 + b);
    }
    native_thread_vars(m, &client.image);
    let mut images: Vec<LoadedImage> = adapters
        .iter()
        .map(|(_, a)| LoadedImage { name: a.name.clone(), slide: a.slide, start: a.slide, end: a.slide + 0x1000_0000 })
        .collect();
    images.push(LoadedImage { name: "client".into(), slide: 0, start: crate::machine::CLIENT_BASE, end: ADAPTER_BASE });
    m.images.set(images).ok();
    m.tls_template.set(tls_template(&client.image)).ok();
    Ok(Loaded { client: client.image, client_fixups, adapter_fixups })
}

/// The client's thread-local variables as dyld's tlv_get_addr finds them, in arm64: each
/// descriptor's thunk becomes four instructions that add the variable's offset to the thread's
/// block, which is TPIDR_EL0 (each thread's, src/runtime.rs).
fn native_thread_vars(m: &Machine, client: &Image) {
    let Some(section) = client.section("__DATA", "__thread_vars") else { return };
    let stub = m.alloc(16);
    for (i, word) in [0xD53B_D050u32, 0xF940_0811, 0x8B11_0200, 0xD65F_03C0].iter().enumerate() {
        // mrs x16, tpidr_el0; ldr x17, [x0, #16]; add x0, x16, x17; ret
        m.memory.set_u32(stub + 4 * i as u64, *word);
    }
    for descriptor in (section.addr..section.addr + section.size).step_by(24) {
        m.memory.set_u64(descriptor, stub);
    }
}

/// The thread-local template: (__thread_data's bytes, the block's size).
pub struct TlsTemplate {
    data: Vec<u8>,
    size: u64,
}

fn tls_template(client: &Image) -> TlsTemplate {
    let data = client.section("__DATA", "__thread_data");
    let bss = client.section("__DATA", "__thread_bss");
    let start = data.or(bss).map_or(0, |s| s.addr);
    let end = [data, bss].iter().flatten().map(|s| s.addr + s.size).max().unwrap_or(start);
    let bytes = data.map_or_else(Vec::new, |s| client.data[s.offset as usize..(s.offset as u64 + s.size) as usize].to_vec());
    TlsTemplate { data: bytes, size: (end - start).max(16) }
}

/// A thread's copy of the client's thread-local template (__thread_data, then zeroed __thread_bss).
pub fn tls_block(m: &Machine) -> u64 {
    let size = m.tls_template.get().map_or(16, |t| t.size);
    let block = m.alloc(size);
    if let Some(template) = m.tls_template.get() {
        m.memory.write(block, &template.data);
    }
    block
}
