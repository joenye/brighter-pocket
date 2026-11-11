"""Metal and CAMetalLayer for the boot harness: objects that stand for the device's, and every
shader library put through the on-device rewrap's checks (tools/check_shaders.py, as
pocket/patches/0003 makes them) exactly when the client asks for it.

Objects are fake (no GPU here); buffers are real memory, since the client writes into them.
Each presented drawable counts a frame, and the run stops after --frames of them: a client
that presents frames has come through its whole startup.
"""
from __future__ import annotations

import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools"))
import check_shaders  # noqa: E402


def register(emu, selectors, new_object, imported_class, new_string, new_array, arg, Stop):
    emu.libraries = {"accepted": 0, "refused": 0}
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
        reason = check_shaders.accepts(emu.read(pointer, size))
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

    def present(e, recv, sel):
        emu.frames += 1
        if emu.frames >= emu.frame_limit:
            raise Stop(f"presented {emu.frames} frames")
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
