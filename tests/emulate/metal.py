"""Metal and CAMetalLayer for the boot harness: objects that stand for the device's, and every
shader library put through the on-device rewrap's checks (tools/check_shaders.py, as
pocket/patches/0003 makes them) exactly when the client asks for it.

Objects are fake (no GPU here); buffers are real memory, since the client writes into them.
Each presented drawable counts a frame, and the run stops after --frames of them: a client
that presents frames has come through its whole startup.
"""
from __future__ import annotations

import hashlib
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools"))
import check_shaders  # noqa: E402


def register(emu, selectors, new_object, imported_class, new_string, new_array, arg, Stop):
    emu.libraries = {"accepted": 0, "refused": 0}
    emu.library_keys = set()
    emu.frames = 0
    emu.buffers = {}            # buffer object -> its contents
    emu.dispatch_data = {}      # dispatch_data_t -> (pointer, size)
    singletons = {}

    def obj(class_name):
        return new_object(imported_class(class_name))

    def device():
        if "device" not in singletons:
            singletons["device"] = obj("MTLDevice")
        return singletons["device"]

    emu.metal_device = device

    def returns(class_name):
        return lambda e, recv, sel: obj(class_name)

    def library_with_data(e, recv, sel):
        source = arg(2)
        pointer, size = emu.dispatch_data.get(source, (None, None))
        if pointer is None:
            raise Stop("newLibraryWithData: got data the harness did not make")
        library = emu.read(pointer, size)
        # Tolkara's Metal adapter names a library by the SHA-256 of these bytes (its
        # Documents/TranslatedShaders cache and ShaderRequests use the name).
        emu.library_keys.add(hashlib.sha256(library).hexdigest())
        reason = check_shaders.accepts(library)
        if reason:
            emu.libraries["refused"] += 1
            emu.library_refusals.append(reason)
            if arg(3):
                emu.write(arg(3), struct.pack("<Q", obj("NSError")))
            return 0
        emu.libraries["accepted"] += 1
        return obj("MTLLibrary")

    def buffer(length, data=None):
        contents = emu.malloc(max(length, 16))
        if data:
            emu.write(contents, data)
        b = obj("MTLBuffer")
        emu.buffers[b] = (contents, length)
        return b

    # A command buffer's completion handlers run once the GPU is done with it, and a drawable's
    # presented handlers once it is on screen, each on a thread of Metal's. With --threads they
    # run so when the buffer is committed, each on a thread of its own (the client paces its
    # frames by them); without it they never run. Metal copies the blocks it is given; a block
    # here is copied byte for byte (its size from its descriptor).
    handlers = {}        # command buffer -> [(block, argument)]
    presented = {}       # drawable -> [block]

    def copy_block(block):
        size = struct.unpack("<Q", emu.read(emu.u64(block + 24) + 8, 8))[0]
        copy = emu.malloc(size)
        emu.write(copy, emu.read(block, size))
        return copy

    def add_completed_handler(e, recv, sel):
        handlers.setdefault(recv, []).append((copy_block(arg(2)), recv))
        return 0

    def add_presented_handler(e, recv, sel):
        presented.setdefault(recv, []).append(copy_block(arg(2)))
        return 0

    def commit(e, recv, sel):
        for block, argument in handlers.pop(recv, []):
            if emu.scheduler:
                emu.scheduler.spawn(emu.u64(block + 16), block, argument)
                emu.gpu_completions += 1
        return 0

    emu.gpu_completions = 0
    # The display takes a frame at most every 1/60 s: a presented frame moves the emulated clock
    # (hle.py, "time") to at least a sixtieth of a second after the one before, as the
    # device's vertical sync paces the client's frame loop. On the host's clock (--vpn, once
    # live), frames take as long as they take.
    FRAME_NS = 1_000_000_000 // 60
    last_present = [0]

    def present(e, recv, sel):
        drawable = arg(2)
        handlers.setdefault(recv, []).extend((block, drawable) for block in presented.pop(drawable, []))
        if emu.live_clock:
            emu.pass_time(0)
        else:
            emu.clock_ns = max(emu.clock_ns, last_present[0] + FRAME_NS)
        last_present[0] = emu.clock_ns
        emu.frames += 1
        if emu.frames >= emu.frame_limit:
            raise Stop(f"presented {emu.frames} frames")
        if emu.interrupted:
            raise Stop(f"interrupted after {emu.frames} frames")
        if emu.progress and emu.frames % 100 == 0:
            draws = sum(n for (cls, sel), n in emu.objc_sends.items() if sel.startswith("drawIndexedPrimitives"))
            print(f"[progress] frame {emu.frames}: {draws} meshes drawn so far, heap "
                  f"{(emu.heap - emu.heap_base) >> 20} MB, {len(emu.handled_events)} input events",
                  file=sys.stderr, flush=True)
        if emu.on_frame:
            emu.on_frame(emu.frames)
        return 0

    def next_drawable(e, recv, sel):
        drawable = obj("CAMetalDrawable")
        return drawable

    selectors.update({
        "newCommandQueue": returns("MTLCommandQueue"),
        "newLibraryWithData:error:": library_with_data,
        "newFunctionWithName:": returns("MTLFunction"),
        "newRenderPipelineStateWithDescriptor:error:": returns("MTLRenderPipelineState"),
        "newDepthStencilStateWithDescriptor:": returns("MTLDepthStencilState"),
        "newSamplerStateWithDescriptor:": returns("MTLSamplerState"),
        "newTextureWithDescriptor:": returns("MTLTexture"),
        "newBufferWithLength:options:": lambda e, r, s: buffer(arg(2)),
        "newBufferWithBytes:length:options:": lambda e, r, s: buffer(arg(3), emu.read(arg(2), arg(3))),
        "contents": lambda e, r, s: emu.buffers.get(r, (0, 0))[0],
        "name": lambda e, r, s: new_string("Apple M2 GPU"),
        "isLowPower": lambda e, r, s: 0, "isHeadless": lambda e, r, s: 0,
        "recommendedMaxWorkingSetSize": lambda e, r, s: 6 << 30,
        "supportsTextureSampleCount:": lambda e, r, s: int(arg(2) in (1, 2, 4)),
        "commandBuffer": returns("MTLCommandBuffer"),
        "renderCommandEncoderWithDescriptor:": returns("MTLRenderCommandEncoder"),
        "blitCommandEncoder": returns("MTLBlitCommandEncoder"),
        "colorAttachments": returns("MTLAttachmentArray"),
        "depthAttachment": returns("MTLRenderPassDepthAttachmentDescriptor"),
        "stencilAttachment": returns("MTLRenderPassStencilAttachmentDescriptor"),
        "attributes": returns("MTLAttributeArray"), "layouts": returns("MTLLayoutArray"),
        "vertexBuffers": returns("MTLPipelineBufferArray"), "fragmentBuffers": returns("MTLPipelineBufferArray"),
        "frontFaceStencil": returns("MTLStencilDescriptor"), "backFaceStencil": returns("MTLStencilDescriptor"),
        "nextDrawable": next_drawable,
        "texture": returns("MTLTexture"),
        "presentDrawable:": present, "presentDrawable:afterMinimumDuration:": present,
        "addCompletedHandler:": add_completed_handler, "addPresentedHandler:": add_presented_handler,
        "commit": commit,
    })

    def make_device(e):
        return device()

    def copy_all_devices(e):
        return new_array([device()])

    def dispatch_data_create(e):
        data = emu.malloc(32)
        emu.dispatch_data[data] = (arg(0), arg(1))
        return data

    return {"_MTLCreateSystemDefaultDevice": make_device, "_MTLCopyAllDevices": copy_all_devices,
            "_dispatch_data_create": dispatch_data_create}
