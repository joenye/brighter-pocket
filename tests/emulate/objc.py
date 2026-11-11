"""A small Objective-C runtime for the boot harness.

The client's own three classes are read from its metadata (after fix-ups, so every pointer
is absolute) and their methods run as the client's code: a message to one of them jumps to
its implementation. System classes are opaque: each imported class is a 256-byte object in
the harness's data area, an instance is a small block whose first word points at it, and
the messages startup sends to them are answered from SELECTORS below (anything else is
recorded and answers nil, as a message to nil would). Strings the client builds through
Foundation are kept as Python strings beside their fake objects.
"""
from __future__ import annotations

import struct

from unicorn.arm64_const import UC_ARM64_REG_SP

HEAP_LOW, HEAP_HIGH = 0x4_0000_0000, 0x4_4000_0000   # boot.py's HEAP_BASE and its size


def register(emu, f, fn, arg, stack, Stop):
    # Read once the images are fixed up: the first message comes after that.
    classes: dict = {}
    imported: dict = {}   # data address -> class name, for classes the client imports
    loaded = []

    def ensure():
        if loaded:
            return
        loaded.append(True)
        classes.update(read_client_classes(emu))
        for name, address in emu.data.items():
            if name.startswith("_OBJC_CLASS_$_"):
                imported[address] = name[len("_OBJC_CLASS_$_"):]

    emu.strings = {}

    def imported_class(name):
        address = emu.data_symbol("_OBJC_CLASS_$_" + name)
        imported[address] = name
        return address

    def new_object(class_address, size=64):
        obj = emu.malloc(size)
        emu.write(obj, struct.pack("<Q", class_address))
        return obj

    def new_string(text):
        obj = new_object(imported_class("NSString"))
        emu.strings[obj] = text
        return obj

    emu.new_string = new_string

    def class_of(obj):
        # (class address, is the receiver a class, client class info or None, system class name or None)
        ensure()
        if obj in classes:
            return obj, True, classes[obj], None
        if obj in imported:
            return obj, True, None, imported[obj]
        isa = emu.u64(obj) & 0x0000_000F_FFFF_FFF8 if obj else 0
        if isa in classes:
            return isa, False, classes[isa], None
        if isa in imported:
            return isa, False, None, imported[isa]
        if isa == emu.data.get("___CFConstantStringClassReference"):
            return isa, False, None, "NSString"
        return isa, False, None, None

    def nsstring(obj):
        if obj in emu.strings:
            return emu.strings[obj]
        isa = emu.u64(obj)
        if isa == emu.data.get("___CFConstantStringClassReference"):
            pointer, length = emu.u64(obj + 16), emu.u64(obj + 24)
            return emu.read(pointer, length).decode("utf-8", "replace")
        return f"<object {obj:#x}>"

    emu.nsstring = nsstring

    def describe(obj):
        if not obj:
            return "(null)"
        _, is_class, client, system = class_of(obj)
        if obj in emu.strings or system == "NSString":
            return nsstring(obj)
        name = client["name"] if client else system or "?"
        return name if is_class else f"<{name} {obj:#x}>"

    emu.describe = describe

    def describe_arg(value):
        """An argument for the log: an object we know, else the number."""
        if value in emu.strings or value in emu.arrays or value in classes or value in imported:
            return describe(value)
        if HEAP_LOW <= value < HEAP_HIGH and emu.u64(value) in imported:
            return describe(value)
        return hex(value)

    emu.recent = []

    def lookup(class_address, selector, class_side):
        # A client implementation along the client's own superclass chain.
        ensure()
        while class_address in classes:
            info = classes[class_address]
            methods = info["class_methods"] if class_side else info["methods"]
            if selector in methods:
                return methods[selector]
            class_address = info["superclass"]
        return None

    def system_class_of(class_address):
        while class_address in classes:
            class_address = classes[class_address]["superclass"]
        return imported.get(class_address)

    # --- the messages startup sends to system classes ---------------------------------------
    def returns_self(e, recv, sel):
        return recv

    def alloc(e, recv, sel):
        ensure()
        if recv in classes:
            return new_object(recv, max(64, classes[recv]["instance_size"]))
        return new_object(recv)

    def is_main_thread(e, recv, sel):
        return 1

    def string_with_utf8(e, recv, sel):
        return new_string(emu.cstring(arg(2)))

    def utf8(e, recv, sel):
        text = nsstring(recv).encode() + b"\0"
        buf = emu.malloc(len(text))
        emu.write(buf, text)
        return buf

    def append_path(e, recv, sel):
        base, part = nsstring(recv), nsstring(arg(2))
        return new_string(base.rstrip("/") + "/" + part.lstrip("/"))

    # NSStringEncoding: NSUTF8StringEncoding (4), NSASCIIStringEncoding (1), NSUTF16LittleEndianStringEncoding
    # (0x94000100), the one the client's own strings (UTF-16 code units) travel in.
    codecs = {1: "ascii", 4: "utf-8", 5: "latin-1", 0x94000100: "utf-16-le", 0x90000100: "utf-16-be", 10: "utf-16-le"}

    def encode(text, encoding):
        return text.encode(codecs.get(encoding & 0xFFFFFFFF, "utf-8"), "replace")

    def terminator(encoding):
        return b"\0\0" if "16" in codecs.get(encoding & 0xFFFFFFFF, "") else b"\0"

    def get_c_string(e, recv, sel):
        encoding = arg(4)
        text, buffer, capacity = encode(nsstring(recv), encoding), arg(2), arg(3)
        end = terminator(encoding)
        if len(text) + len(end) > capacity:
            return 0
        emu.write(buffer, text + end)
        return 1

    def init_with_bytes(e, recv, sel):
        data, encoding = emu.read(arg(2), arg(3)), arg(4)
        emu.strings[recv] = data.decode(codecs.get(encoding & 0xFFFFFFFF, "utf-8"), "replace")
        return recv

    def bundle_path(e, recv, sel):
        return new_string(str(emu.app))

    def main_bundle(e, recv, sel):
        return new_object(imported_class("NSBundle"))

    def no(e, recv, sel):
        return 0

    emu.dicts, emu.numbers = {}, {}

    def number(value):
        obj = new_object(imported_class("NSNumber"))
        emu.numbers[obj] = value
        return obj

    def dictionary(entries):
        obj = new_object(imported_class("NSDictionary"))
        emu.dicts[obj] = entries
        return obj

    def factory(e, recv, sel):
        return new_object(recv)

    singletons = {}

    def singleton(class_name, global_symbol=None):
        def answer(e, recv, sel):
            if class_name not in singletons:
                singletons[class_name] = new_object(imported_class(class_name))
                if global_symbol:
                    emu.write(emu.data_symbol(global_symbol), struct.pack("<Q", singletons[class_name]))
            return singletons[class_name]
        return answer

    def rect(x, y, w, h):
        def answer(e, recv, sel):
            emu.set_doubles(x, y, w, h)
            return None
        return answer

    def double(value):
        def answer(e, recv, sel):
            emu.set_doubles(value)
            return None
        return answer

    def yes(e, recv, sel):
        return 1

    def array_of(class_name):
        def answer(e, recv, sel):
            array = new_object(imported_class("NSArray"))
            emu.arrays[array] = [singleton(class_name)(e, recv, sel)]
            return array
        return answer

    # NSData keeps its bytes; an image made from one records what format the bytes are in,
    # since on the device PocketCompat.m decodes them with UIImage.
    emu.ns_data, emu.image_formats = {}, []
    signatures = {b"\x89PNG": "PNG", b"\xff\xd8\xff": "JPEG", b"II*\x00": "TIFF", b"MM\x00*": "TIFF", b"GIF8": "GIF"}

    def ns_data(e, recv, sel):
        data = new_object(recv)
        emu.ns_data[data] = (arg(2), arg(3))
        return data

    def image_rep(e, recv, sel):
        pointer, size = emu.ns_data.get(arg(2), (0, 0))
        head = emu.read(pointer, 8) if pointer and size >= 8 else b""
        emu.image_formats.append(next((name for magic, name in signatures.items() if head.startswith(magic)), head.hex()))
        return new_object(recv)

    emu.arrays = {}
    emu.content_views = {}

    def new_array(items):
        array = new_object(imported_class("NSArray"))
        emu.arrays[array] = list(items)
        return array

    emu.new_array = new_array

    def count(e, recv, sel):
        return len(emu.arrays.get(recv, []))

    def object_at(e, recv, sel):
        if recv not in emu.arrays:   # a Metal descriptor array: an element for each index
            return new_object(imported_class("MTLArrayElement"))
        items = emu.arrays[recv]
        return items[arg(2)] if arg(2) < len(items) else 0

    mutations = emu.malloc(8)

    def fast_enumeration(e, recv, sel):
        # NSFastEnumerationState: state, itemsPtr, mutationsPtr, extra[5]; all items in one pass.
        state, buffer, capacity = arg(2), arg(3), arg(4)
        items = emu.arrays.get(recv, [])
        if emu.u64(state) or not items:
            return 0
        items = items[:capacity]
        emu.write(buffer, b"".join(struct.pack("<Q", i) for i in items))
        emu.write(state, struct.pack("<QQQ", 1, buffer, mutations))
        return len(items)

    # What the device answers, as far as startup asks. Tolkara's AppKit classes answer only the
    # selectors its adapter (and this layer's PocketCompat.m) implement; see emu.appkit.
    selectors = {
        "alloc": alloc, "new": alloc, "init": returns_self, "retain": returns_self, "autorelease": returns_self,
        "self": returns_self, "copy": returns_self, "release": no, "isMainThread": is_main_thread,
        "stringWithUTF8String:": string_with_utf8, "UTF8String": utf8, "stringByAppendingPathComponent:": append_path,
        "mainBundle": main_bundle, "bundlePath": bundle_path,
        "sharedApplication": singleton("NSApplication", "_NSApp"), "mainScreen": singleton("NSScreen"),
        # Tolkara's NSWindow: on the main screen, visible, holding the content view it was given.
        "screen": singleton("NSScreen"), "occlusionState": lambda e, r, s: 2,
        "setContentView:": lambda e, r, s: emu.content_views.__setitem__(r, arg(2)),
        "contentView": lambda e, r, s: emu.content_views.get(r, 0),
        "screens": array_of("NSScreen"), "count": count, "objectAtIndex:": object_at, "objectAtIndexedSubscript:": object_at,
        "defaultManager": singleton("NSFileManager"), "processInfo": singleton("NSProcessInfo"),
        "mainRunLoop": singleton("NSRunLoop"), "sharedWorkspace": singleton("NSWorkspace"),
        "generalPasteboard": singleton("NSPasteboard"),
        "dataWithBytesNoCopy:length:freeWhenDone:": ns_data, "imageRepWithData:": image_rep,
        "arrowCursor": singleton("NSCursor"), "IBeamCursor": singleton("NSCursor"), "crosshairCursor": singleton("NSCursor"),
        "pointingHandCursor": singleton("NSCursor"), "operationNotAllowedCursor": singleton("NSCursor"),
        "frame": rect(0, 0, 1366, 1024), "bounds": rect(0, 0, 1366, 1024), "visibleFrame": rect(0, 0, 1366, 1024),
        "frameRectForContentRect:": rect(0, 0, 1366, 1024), "convertRectToBacking:": rect(0, 0, 2732, 2048),
        "backingScaleFactor": double(2.0), "maximumFramesPerSecond": lambda e, r, s: 120,
        "isKeyWindow": yes,
        "fileExistsAtPath:": lambda e, r, s: int(emu.vfs_kind(nsstring(arg(2))) is not None),
        "createDirectoryAtPath:withIntermediateDirectories:attributes:error:":
            lambda e, r, s: int(emu.vfs_make_directories(nsstring(arg(2)))),
        "lengthOfBytesUsingEncoding:": lambda e, r, s: len(encode(nsstring(r), arg(2))),
        "initWithBytes:length:encoding:": init_with_bytes,
        # Variadic: the format in x2, its arguments on the stack (Apple arm64).
        "stringWithFormat:": lambda e, r, s: new_string(
            emu.format_string(nsstring(arg(2)).encode(), emu.uc.reg_read(UC_ARM64_REG_SP)).decode("utf-8", "replace")),
        "getCString:maxLength:encoding:": get_c_string,
        "physicalMemory": lambda e, r, s: 8 << 30, "countByEnumeratingWithState:objects:count:": fast_enumeration,
        "deviceDescription": lambda e, r, s: dictionary({"NSScreenNumber": number(1)}),
        "objectForKey:": lambda e, r, s: emu.dicts.get(r, {}).get(nsstring(arg(2)), 0),
        "unsignedIntValue": lambda e, r, s: emu.numbers.get(r, 0), "intValue": lambda e, r, s: emu.numbers.get(r, 0),
        "integerValue": lambda e, r, s: emu.numbers.get(r, 0), "unsignedIntegerValue": lambda e, r, s: emu.numbers.get(r, 0),
    }

    import metal
    f.update(metal.register(emu, selectors, new_object, imported_class, new_string, new_array, arg, Stop))

    @fn("_objc_msgSend")
    def objc_msg_send(e):
        recv, sel = arg(0), arg(1)
        if not recv:
            return 0
        selector = emu.cstring(sel)
        class_address, is_class, client, system = class_of(recv)
        implementation = lookup(class_address, selector, is_class) if client else None
        if implementation:
            emu.jump_to = implementation
            return None
        name = system or (system_class_of(class_address) if client else None) or "?"
        side = "+" if is_class else "-"
        if name in emu.appkit and not emu.appkit.implements(name, selector, is_class):
            # Tolkara's AppKit classes answer an unimplemented selector with nil (AKStubObject).
            emu.objc_sends[(side + name, selector + "  [unimplemented: nil]")] += 1
            return 0
        emu.objc_sends[(side + name, selector)] += 1
        emu.recent.append(f"[{describe(recv)} {selector}] " + " ".join(describe_arg(arg(2 + i)) for i in range(selector.count(":"))))
        del emu.recent[:-40]
        answer = selectors.get(selector)
        if answer:
            return answer(e, recv, selector)
        if selector.startswith("init"):
            return recv
        return 0

    @fn("_objc_alloc")
    def objc_alloc(e):
        return alloc(e, arg(0), "alloc")

    @fn("_objc_alloc_init")
    def objc_alloc_init(e):
        ensure()
        obj = alloc(e, arg(0), "alloc")
        implementation = lookup(arg(0), "init", False) if arg(0) in classes else None
        if implementation:
            emu.set_reg(0, obj)
            emu.set_reg(1, emu.selector("init"))
            emu.jump_to = implementation
            return None
        return obj

    @fn("_objc_retain", "_objc_autorelease")
    def objc_retain(e):
        return arg(0)

    @fn("_objc_release")
    def objc_release(e):
        return None

    @fn("_objc_autoreleasePoolPush")
    def pool_push(e):
        return emu.malloc(16)

    @fn("_objc_autoreleasePoolPop")
    def pool_pop(e):
        return None

    @fn("_objc_opt_class")
    def opt_class(e):
        obj = arg(0)
        if not obj:
            return 0
        class_address, is_class, _, _ = class_of(obj)
        return obj if is_class else class_address

    @fn("_objc_enumerationMutation")
    def mutation(e):
        raise Stop("objc_enumerationMutation")


def read_client_classes(emu):
    """The client's classes from __objc_classlist: name, superclass, instance size, methods by selector."""
    image = emu.client.image
    section = image.section("__DATA_CONST", "__objc_classlist") or image.section("__DATA", "__objc_classlist")
    out = {}
    if not section:
        return out
    for i in range(section.size // 8):
        cls = emu.u64(section.addr + 8 * i)
        meta = emu.u64(cls)
        info = read_class(emu, cls)
        info["class_methods"] = read_class(emu, meta)["methods"]
        info["superclass"] = emu.u64(cls + 8)
        out[cls] = info
    return out


def read_class(emu, cls):
    ro = emu.u64(cls + 32) & ~7
    instance_size = struct.unpack("<I", emu.read(ro + 8, 4))[0]
    name = emu.cstring(emu.u64(ro + 24))
    methods = {}
    mlist = emu.u64(ro + 32)
    if mlist:
        entsize_flags, count = struct.unpack("<2I", emu.read(mlist, 8))
        entsize, relative = entsize_flags & 0xFFFC, entsize_flags & 0x80000000
        for k in range(count):
            entry = mlist + 8 + k * entsize
            if relative:
                name_off, _, imp_off = struct.unpack("<3i", emu.read(entry, 12))
                selector = emu.cstring(emu.u64(entry + name_off))
                methods[selector] = entry + 8 + imp_off
            else:
                selector = emu.cstring(emu.u64(entry))
                methods[selector] = emu.u64(entry + 16)
    return {"name": name, "instance_size": instance_size, "methods": methods}
