//! Metal and CAMetalLayer: objects that stand for the device's, and every shader library put
//! through the on-device rewrap's checks (shaders.rs, as pocket/patches/0003 makes them)
//! exactly when the client asks for it.
//!
//! Objects are fake (no GPU here); buffers are real memory, since the client writes into them.
//! Each presented drawable counts a frame, and the run stops after --frames of them: a client
//! that presents frames has come through its whole startup. No frame pacing: clocks are the
//! host's.
use std::collections::{BTreeSet, HashMap, HashSet};
use std::path::PathBuf;
use std::sync::atomic::Ordering;

use super::objc::{self, SelectorAnswer};
use super::{Ctx, Registry, Stop};
use crate::machine::Machine;

#[path = "shaders.rs"]
pub mod shaders;

#[derive(Default)]
struct Metal {
    app: Option<PathBuf>,
    device: u64,
    accepted: u64,
    refused: u64,
    refusals: Vec<String>,
    /// Tolkara's Metal adapter names a library by the SHA-256 of its bytes (its
    /// Documents/TranslatedShaders cache and ShaderRequests use the name).
    keys: HashSet<String>,
    buffers: HashMap<u64, u64>,            // buffer object -> its contents
    dispatch_data: HashMap<u64, (u64, u64)>, // dispatch_data_t -> (pointer, size)
    handlers: HashMap<u64, Vec<(u64, u64)>>, // command buffer -> [(block, argument)]
    presented: HashMap<u64, Vec<u64>>,     // drawable -> [block]
    draws: u64,
    /// When the last frame went on screen: the display takes one at most every 1/60 s.
    last_present: Option<std::time::Instant>,
}

const FRAME: std::time::Duration = std::time::Duration::from_nanos(1_000_000_000 / 60);

pub fn register(r: &mut Registry) {
    r.answer(&["_MTLCreateSystemDefaultDevice"], |c| Ok(Some(device(c.m))));
    r.answer(&["_MTLCopyAllDevices"], |c| {
        let device = device(c.m);
        Ok(Some(objc::new_array(c.m, vec![device])))
    });
    r.answer(&["_dispatch_data_create"], |c| {
        let data = c.alloc(32);
        c.state::<Metal>().lock().unwrap().dispatch_data.insert(data, (c.arg(0), c.arg(1)));
        Ok(Some(data))
    });
}

pub fn prepare(m: &Machine, app: &std::path::Path) -> Result<(), String> {
    m.state::<Metal>().lock().unwrap().app = Some(app.to_path_buf());
    Ok(())
}

pub fn finish(_m: &Machine) {}

pub fn problems(m: &Machine) -> Vec<String> {
    let (refused, keys, app) = {
        let state = m.state::<Metal>();
        let state = state.lock().unwrap();
        (state.refused, state.keys.iter().cloned().collect::<BTreeSet<_>>(), state.app.clone())
    };
    let mut problems = Vec::new();
    if refused > 0 {
        problems.push(format!("{refused} shader libraries refused"));
    }
    // tools/translate_shaders.py names its translations by the libraries as it reads them from
    // the bundles; the adapter looks them up by the bytes the client hands to Metal.
    if let Some(app) = app {
        match shaders::distinct_libraries(&app) {
            Ok(libraries) if libraries.keys().eq(keys.iter()) => {}
            Ok(_) => problems.push("the client's shader libraries are not the ones tools/translate_shaders.py translates".into()),
            Err(error) => problems.push(format!("the client's shader bundles could not be read: {error}")),
        }
    }
    problems
}

pub fn sections(m: &Machine) -> Vec<(String, Vec<String>)> {
    let state = m.state::<Metal>();
    let state = state.lock().unwrap();
    let mut libraries = format!("{} accepted, {} refused", state.accepted, state.refused);
    if let Some(reason) = state.refusals.first() {
        libraries += &format!(" ({reason})");
    }
    let frames = format!("{} frames presented, {} meshes drawn", m.frames.load(Ordering::Relaxed), state.draws);
    vec![("shader libraries".into(), vec![libraries]), ("frames and meshes".into(), vec![frames])]
}

/// "N shader libraries accepted", for the verdict line.
pub fn summary(m: &Machine) -> String {
    format!("{} shader libraries accepted", m.state::<Metal>().lock().unwrap().accepted)
}

/// The selectors Metal's and CAMetalLayer's stand-ins answer (objc dispatches them).
pub fn selectors() -> Vec<(&'static str, SelectorAnswer)> {
    let mut answers: Vec<(&'static str, SelectorAnswer)> = MAKES.iter().map(|&(selector, _)| (selector, makes as SelectorAnswer)).collect();
    let more: &[(&'static str, SelectorAnswer)] = &[
        ("newLibraryWithData:error:", library_with_data),
        ("newBufferWithLength:options:", |c, _, _| Ok(Some(buffer(c, c.arg(2), None)))),
        ("newBufferWithBytes:length:options:", |c, _, _| Ok(Some(buffer(c, c.arg(3), Some(c.arg(2)))))),
        ("contents", |c, receiver, _| Ok(Some(c.state::<Metal>().lock().unwrap().buffers.get(&receiver).copied().unwrap_or(0)))),
        ("name", |c, _, _| Ok(Some(objc::new_string(c.m, "Apple M2 GPU")))),
        ("isLowPower", |_, _, _| Ok(Some(0))),
        ("isHeadless", |_, _, _| Ok(Some(0))),
        ("recommendedMaxWorkingSetSize", |_, _, _| Ok(Some(6 << 30))),
        ("supportsTextureSampleCount:", |c, _, _| Ok(Some([1, 2, 4].contains(&c.arg(2)) as u64))),
        ("presentDrawable:", present),
        ("presentDrawable:afterMinimumDuration:", present),
        ("addCompletedHandler:", |c, receiver, _| {
            let block = copy_block(c, c.arg(2));
            c.state::<Metal>().lock().unwrap().handlers.entry(receiver).or_default().push((block, receiver));
            Ok(Some(0))
        }),
        ("addPresentedHandler:", |c, receiver, _| {
            let block = copy_block(c, c.arg(2));
            c.state::<Metal>().lock().unwrap().presented.entry(receiver).or_default().push(block);
            Ok(Some(0))
        }),
        ("commit", commit),
    ];
    answers.extend_from_slice(more);
    // Drawn meshes are counted; the encoder answers nothing.
    answers.extend(DRAWS.iter().map(|&selector| (selector, draw as SelectorAnswer)));
    answers
}

/// Selectors that hand out a new object of a class, and the class.
const MAKES: &[(&str, &str)] = &[
    ("newCommandQueue", "MTLCommandQueue"),
    ("newFunctionWithName:", "MTLFunction"),
    ("newRenderPipelineStateWithDescriptor:error:", "MTLRenderPipelineState"),
    ("newDepthStencilStateWithDescriptor:", "MTLDepthStencilState"),
    ("newSamplerStateWithDescriptor:", "MTLSamplerState"),
    ("newTextureWithDescriptor:", "MTLTexture"),
    ("commandBuffer", "MTLCommandBuffer"),
    ("renderCommandEncoderWithDescriptor:", "MTLRenderCommandEncoder"),
    ("blitCommandEncoder", "MTLBlitCommandEncoder"),
    ("colorAttachments", "MTLAttachmentArray"),
    ("depthAttachment", "MTLRenderPassDepthAttachmentDescriptor"),
    ("stencilAttachment", "MTLRenderPassStencilAttachmentDescriptor"),
    ("attributes", "MTLAttributeArray"),
    ("layouts", "MTLLayoutArray"),
    ("vertexBuffers", "MTLPipelineBufferArray"),
    ("fragmentBuffers", "MTLPipelineBufferArray"),
    ("frontFaceStencil", "MTLStencilDescriptor"),
    ("backFaceStencil", "MTLStencilDescriptor"),
    ("nextDrawable", "CAMetalDrawable"),
    ("texture", "MTLTexture"),
];

/// MTLRenderCommandEncoder's indexed draws (the report's meshes drawn).
const DRAWS: &[&str] = &[
    "drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:",
    "drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:",
    "drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:baseVertex:baseInstance:",
    "drawIndexedPrimitives:indexType:indexBuffer:indexBufferOffset:indirectBuffer:indirectBufferOffset:",
];

fn makes(c: &mut Ctx, _receiver: u64, selector: &str) -> Result<Option<u64>, Stop> {
    let class = MAKES.iter().find(|&&(s, _)| s == selector).map(|&(_, class)| class).ok_or_else(|| format!("{selector}: no class"))?;
    Ok(Some(objc::new_object(c.m, class)))
}

fn draw(c: &mut Ctx, _receiver: u64, _selector: &str) -> Result<Option<u64>, Stop> {
    c.state::<Metal>().lock().unwrap().draws += 1;
    Ok(Some(0))
}

/// The one MTLDevice.
fn device(m: &Machine) -> u64 {
    let state = m.state::<Metal>();
    let made = state.lock().unwrap().device;
    if made != 0 {
        return made;
    }
    let device = objc::new_object(m, "MTLDevice");
    let mut state = state.lock().unwrap();
    if state.device == 0 {
        state.device = device;
    }
    state.device
}

fn library_with_data(c: &mut Ctx, _receiver: u64, _selector: &str) -> Result<Option<u64>, Stop> {
    let source = c.arg(2);
    let state = c.state::<Metal>();
    let Some((pointer, size)) = state.lock().unwrap().dispatch_data.get(&source).copied() else {
        return Err("newLibraryWithData: got data the harness did not make".into());
    };
    let library = c.mem().slice(pointer, size as usize);
    let key = shaders::sha256_hex(library);
    let reason = shaders::accepts(library, true);
    let mut metal = state.lock().unwrap();
    metal.keys.insert(key);
    if let Some(reason) = reason {
        metal.refused += 1;
        metal.refusals.push(reason);
        drop(metal);
        if c.arg(3) != 0 {
            let error = objc::new_object(c.m, "NSError");
            c.mem().set_u64(c.arg(3), error);
        }
        return Ok(Some(0));
    }
    metal.accepted += 1;
    drop(metal);
    Ok(Some(objc::new_object(c.m, "MTLLibrary")))
}

fn buffer(c: &Ctx, length: u64, data: Option<u64>) -> u64 {
    let contents = c.alloc(length.max(16));
    if let Some(data) = data {
        c.mem().copy(contents, data, length as usize);
    }
    let buffer = objc::new_object(c.m, "MTLBuffer");
    c.state::<Metal>().lock().unwrap().buffers.insert(buffer, contents);
    buffer
}

/// Metal copies the blocks it is given; a block here is copied byte for byte (its size from its
/// descriptor).
fn copy_block(c: &Ctx, block: u64) -> u64 {
    let size = c.mem().u64(c.mem().u64(block + 24) + 8);
    let copy = c.alloc(size);
    c.mem().copy(copy, block, size as usize);
    copy
}

/// A command buffer's completion handlers run once the GPU is done with it, and a drawable's
/// presented handlers once it is on screen, each on a thread of Metal's: here when the buffer
/// is committed, each on a guest thread of its own (the client paces its frames by them).
fn commit(c: &mut Ctx, receiver: u64, _selector: &str) -> Result<Option<u64>, Stop> {
    let handlers = c.state::<Metal>().lock().unwrap().handlers.remove(&receiver).unwrap_or_default();
    for (block, argument) in handlers {
        let invoke = c.mem().u64(block + 16);
        crate::runtime::spawn(&c.m.arc(), invoke, block, argument);
    }
    Ok(Some(0))
}

fn present(c: &mut Ctx, receiver: u64, _selector: &str) -> Result<Option<u64>, Stop> {
    let drawable = c.arg(2);
    // The device's vertical sync paces the client's frame loop: a present waits for the next
    // sixtieth of a second, so the frame loop leaves the loading threads their share.
    let (draws, wait) = {
        let state = c.state::<Metal>();
        let mut state = state.lock().unwrap();
        let blocks = state.presented.remove(&drawable).unwrap_or_default();
        state.handlers.entry(receiver).or_default().extend(blocks.into_iter().map(|block| (block, drawable)));
        let now = std::time::Instant::now();
        let due = state.last_present.map_or(now, |last| (last + FRAME).max(now));
        state.last_present = Some(due);
        (state.draws, due - now)
    };
    std::thread::sleep(wait);
    let frames = c.m.frames.fetch_add(1, Ordering::SeqCst) + 1;
    if frames >= c.m.options.frames {
        let reason = format!("presented {frames} frames");
        c.m.stop(reason.clone());
        return Err(Stop(reason));
    }
    if c.m.report.progress() && frames % 100 == 0 {
        eprintln!(
            "[progress] frame {frames}: {draws} meshes drawn so far, heap {} MB, {:.1} s",
            c.m.heap.used() >> 20,
            crate::runtime::uptime().as_secs_f64()
        );
    }
    objc::on_frame(c.m, frames);
    Ok(Some(0))
}

#[cfg(test)]
mod tests {
    #[test]
    fn answers_each_selector_once() {
        let selectors = super::selectors();
        let names: std::collections::HashSet<&str> = selectors.iter().map(|&(name, _)| name).collect();
        assert_eq!(names.len(), selectors.len());
        for name in ["newLibraryWithData:error:", "presentDrawable:", "commit", "nextDrawable", "contents"] {
            assert!(names.contains(name), "{name}");
        }
        assert!(super::DRAWS.iter().all(|s| s.starts_with("drawIndexedPrimitives")));
    }
}
