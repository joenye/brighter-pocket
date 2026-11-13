"""A small Mach-O reader for the macOS client: enough to thin it, list what it links and
imports, walk its chained fixups and read its Objective-C metadata. Pure Python, no
dependencies, so the tools here need nothing beyond the Python macOS ships.

Only what the Brighter Shores client uses is read: 64-bit little-endian arm64 and
x86_64 images, fat (universal) wrappers, LC_DYLD_CHAINED_FIXUPS with the plain 64-bit
pointer formats, the exports trie and the Objective-C class, selector and stub
sections. Anything else is refused with a reason rather than guessed at.
"""
from __future__ import annotations

import hashlib
import struct
from dataclasses import dataclass, field
from pathlib import Path

FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF
MH_MAGIC_64 = 0xFEEDFACF
CPU_ARM64 = 0x0100000C
CPU_X86_64 = 0x01000007
CPU_NAMES = {CPU_ARM64: "arm64", CPU_X86_64: "x86_64"}
MH_EXECUTE = 2
MH_DYLIB = 6

LC_REQ_DYLD = 0x80000000
LC_SYMTAB = 0x2
LC_LOAD_DYLIB = 0xC
LC_ID_DYLIB = 0xD
LC_LOAD_WEAK_DYLIB = 0x18 | LC_REQ_DYLD
LC_SEGMENT_64 = 0x19
LC_UUID = 0x1B
LC_RPATH = 0x1C | LC_REQ_DYLD
LC_REEXPORT_DYLIB = 0x1F | LC_REQ_DYLD
LC_ENCRYPTION_INFO_64 = 0x2C
LC_MAIN = 0x28 | LC_REQ_DYLD
LC_BUILD_VERSION = 0x32
LC_DYLD_EXPORTS_TRIE = 0x33 | LC_REQ_DYLD
LC_DYLD_CHAINED_FIXUPS = 0x34 | LC_REQ_DYLD
LC_DYLD_INFO = 0x22
LC_DYLD_INFO_ONLY = 0x22 | LC_REQ_DYLD
DYLIB_COMMANDS = {LC_LOAD_DYLIB: "load", LC_LOAD_WEAK_DYLIB: "weak", LC_REEXPORT_DYLIB: "reexport"}
PLATFORMS = {1: "macos", 2: "ios", 6: "maccatalyst", 7: "iossimulator", 11: "visionos"}

# dyld_chained_ptr formats this reader walks (mach-o/fixup-chains.h).
DYLD_CHAINED_PTR_64 = 2
DYLD_CHAINED_PTR_64_OFFSET = 6
CHAINED_POINTER_FORMATS = {DYLD_CHAINED_PTR_64: "PTR_64", DYLD_CHAINED_PTR_64_OFFSET: "PTR_64_OFFSET"}
DYLD_CHAINED_PTR_START_NONE = 0xFFFF
DYLD_CHAINED_PTR_START_MULTI = 0x8000
# Special library ordinals of a bind (mach-o/loader.h BIND_SPECIAL_DYLIB_*).
ORDINAL_SELF, ORDINAL_MAIN, ORDINAL_FLAT, ORDINAL_WEAK = 0, -1, -2, -3
SPECIAL_ORDINALS = {ORDINAL_SELF: "<self>", ORDINAL_MAIN: "<main-executable>",
                    ORDINAL_FLAT: "<flat-namespace>", ORDINAL_WEAK: "<weak-def-coalesce>"}


class MachOError(ValueError):
    pass


@dataclass
class Slice:
    cpu: int
    offset: int
    size: int

    @property
    def arch(self) -> str:
        return CPU_NAMES.get(self.cpu, hex(self.cpu))


@dataclass
class Section:
    segment: str
    name: str
    addr: int
    size: int
    offset: int


@dataclass
class Segment:
    name: str
    vmaddr: int
    vmsize: int
    fileoff: int
    filesize: int
    maxprot: int
    initprot: int
    sections: list[Section] = field(default_factory=list)


@dataclass
class Dylib:
    path: str
    kind: str          # load, weak, reexport


@dataclass
class Import:
    ordinal: int       # 1-based index into dylibs, or one of the special ordinals
    name: str
    weak: bool
    addend: int = 0


@dataclass
class Fixups:
    pointer_formats: set[int]
    rebases: int
    binds: int
    bound: list[int]   # how many times each import is bound, by import index


def slices(data: bytes) -> list[Slice]:
    """The images in a file: each slice of a fat file, or the file itself."""
    if len(data) < 8:
        raise MachOError("too short for a Mach-O file")
    magic = struct.unpack(">I", data[:4])[0]
    if magic in (FAT_MAGIC, FAT_MAGIC_64):
        count = struct.unpack(">I", data[4:8])[0]
        out = []
        for i in range(count):
            if magic == FAT_MAGIC:
                cpu, _, offset, size, _ = struct.unpack(">5I", data[8 + 20 * i:28 + 20 * i])
            else:
                cpu, _, offset, size, _, _ = struct.unpack(">2I2Q2I", data[8 + 32 * i:40 + 32 * i])
            if offset + size > len(data):
                raise MachOError(f"slice {i} runs past the end of the file")
            out.append(Slice(cpu, offset, size))
        return out
    if struct.unpack("<I", data[:4])[0] == MH_MAGIC_64:
        return [Slice(struct.unpack("<I", data[4:8])[0], 0, len(data))]
    raise MachOError(f"not a 64-bit Mach-O or fat file (magic {magic:#x})")


def thin(data: bytes, cpu: int = CPU_ARM64) -> bytes:
    """One architecture's image, byte for byte as the fat file holds it (lipo -thin)."""
    for s in slices(data):
        if s.cpu == cpu:
            return data[s.offset:s.offset + s.size]
    raise MachOError(f"no {CPU_NAMES.get(cpu, hex(cpu))} slice")


def uleb(data: bytes, at: int) -> tuple[int, int]:
    value = shift = 0
    while True:
        if at >= len(data):
            raise MachOError("ULEB128 runs past its data")
        byte = data[at]
        at += 1
        value |= (byte & 0x7F) << shift
        shift += 7
        if not byte & 0x80:
            return value, at


def cstring(data: bytes, at: int, limit: int = 4096) -> str:
    end = data.find(b"\0", at, at + limit)
    if end < 0:
        raise MachOError(f"unterminated string at {at:#x}")
    return data[at:end].decode("utf-8", "replace")


class Image:
    """One thin 64-bit little-endian image."""

    def __init__(self, data: bytes):
        self.data = data
        if len(data) < 32 or struct.unpack("<I", data[:4])[0] != MH_MAGIC_64:
            raise MachOError("not a thin 64-bit little-endian Mach-O image")
        (_, self.cpu, _, self.filetype, ncmds, sizeofcmds,
         self.flags, _) = struct.unpack("<8I", data[:32])
        if 32 + sizeofcmds > len(data):
            raise MachOError("load commands run past the end of the image")
        self.segments: list[Segment] = []
        self.dylibs: list[Dylib] = []
        self.rpaths: list[str] = []
        self.uuid: str | None = None
        self.platform: str | None = None
        self.minos: str | None = None
        self.sdk: str | None = None
        self.entry: int | None = None
        self.encrypted = False
        self.install_name: str | None = None
        self.chained: tuple[int, int] | None = None
        self.exports_trie: tuple[int, int] | None = None
        self.dyld_info = False
        self.commands: list[int] = []
        at = 32
        for _ in range(ncmds):
            cmd, size = struct.unpack("<2I", data[at:at + 8])
            if size < 8 or at + size > 32 + sizeofcmds:
                raise MachOError(f"load command {cmd:#x} has a bad size")
            self.commands.append(cmd)
            body = data[at:at + size]
            if cmd == LC_SEGMENT_64:
                name = body[8:24].split(b"\0")[0].decode()
                vmaddr, vmsize, fileoff, filesize = struct.unpack("<4Q", body[24:56])
                maxprot, initprot, nsects, _ = struct.unpack("<2i2I", body[56:72])
                seg = Segment(name, vmaddr, vmsize, fileoff, filesize, maxprot, initprot)
                for i in range(nsects):
                    s = body[72 + 80 * i:152 + 80 * i]
                    sname = s[:16].split(b"\0")[0].decode()
                    addr, ssize = struct.unpack("<2Q", s[32:48])
                    offset = struct.unpack("<I", s[48:52])[0]
                    seg.sections.append(Section(name, sname, addr, ssize, offset))
                self.segments.append(seg)
            elif cmd in DYLIB_COMMANDS:
                self.dylibs.append(Dylib(cstring(body, struct.unpack("<I", body[8:12])[0]), DYLIB_COMMANDS[cmd]))
            elif cmd == LC_ID_DYLIB:
                self.install_name = cstring(body, struct.unpack("<I", body[8:12])[0])
            elif cmd == LC_RPATH:
                self.rpaths.append(cstring(body, struct.unpack("<I", body[8:12])[0]))
            elif cmd == LC_UUID:
                self.uuid = body[8:24].hex().upper()
            elif cmd == LC_BUILD_VERSION:
                platform, minos, sdk = struct.unpack("<3I", body[8:20])
                self.platform = PLATFORMS.get(platform, str(platform))
                self.minos, self.sdk = _version(minos), _version(sdk)
            elif cmd == LC_MAIN:
                self.entry = struct.unpack("<Q", body[8:16])[0]
            elif cmd == LC_ENCRYPTION_INFO_64:
                self.encrypted = struct.unpack("<I", body[16:20])[0] != 0
            elif cmd == LC_DYLD_CHAINED_FIXUPS:
                self.chained = struct.unpack("<2I", body[8:16])
            elif cmd == LC_DYLD_EXPORTS_TRIE:
                self.exports_trie = struct.unpack("<2I", body[8:16])
            elif cmd in (LC_DYLD_INFO, LC_DYLD_INFO_ONLY):
                self.dyld_info = True
                ex_off, ex_size = struct.unpack("<2I", body[40:48])
                if ex_size:
                    self.exports_trie = (ex_off, ex_size)
            at += size
        text = self.segment("__TEXT")
        self.base = text.vmaddr if text else 0
        self._imports: list[Import] | None = None

    @property
    def arch(self) -> str:
        return CPU_NAMES.get(self.cpu, hex(self.cpu))

    def segment(self, name: str) -> Segment | None:
        return next((s for s in self.segments if s.name == name), None)

    def section(self, segment: str, name: str) -> Section | None:
        seg = self.segment(segment)
        return next((s for s in seg.sections if s.name == name), None) if seg else None

    def sections(self) -> list[Section]:
        return [s for seg in self.segments for s in seg.sections]

    def offset_of(self, vmaddr: int) -> int | None:
        for seg in self.segments:
            if seg.filesize and seg.vmaddr <= vmaddr < seg.vmaddr + seg.filesize:
                return vmaddr - seg.vmaddr + seg.fileoff
        return None

    def u64(self, vmaddr: int) -> int:
        at = self.offset_of(vmaddr)
        if at is None:
            raise MachOError(f"{vmaddr:#x} has no bytes in the file")
        return struct.unpack("<Q", self.data[at:at + 8])[0]

    def string_at(self, vmaddr: int) -> str:
        at = self.offset_of(vmaddr)
        if at is None:
            raise MachOError(f"{vmaddr:#x} has no bytes in the file")
        return cstring(self.data, at)

    def library(self, ordinal: int) -> str:
        if ordinal in SPECIAL_ORDINALS:
            return SPECIAL_ORDINALS[ordinal]
        if 1 <= ordinal <= len(self.dylibs):
            return self.dylibs[ordinal - 1].path
        raise MachOError(f"library ordinal {ordinal} out of range")

    # --- chained fixups -------------------------------------------------------------------
    def _header(self):
        if not self.chained:
            raise MachOError("no LC_DYLD_CHAINED_FIXUPS (opcode fixups are not read here)")
        off, size = self.chained
        blob = self.data[off:off + size]
        if len(blob) < 28:
            raise MachOError("chained fixups header is cut short")
        return blob, struct.unpack("<7I", blob[:28])

    def imports(self) -> list[Import]:
        if self._imports is not None:
            return self._imports
        blob, (version, _, imports_off, symbols_off, count, fmt, symbols_fmt) = self._header()
        if version != 0 or symbols_fmt != 0:
            raise MachOError(f"chained fixups version {version}, symbol format {symbols_fmt} not read here")
        out = []
        for i in range(count):
            if fmt == 1:      # DYLD_CHAINED_IMPORT
                raw = struct.unpack("<I", blob[imports_off + 4 * i:imports_off + 4 * i + 4])[0]
                ordinal, weak, name_off, addend = raw & 0xFF, (raw >> 8) & 1, raw >> 9, 0
                if ordinal >= 0xF0:
                    ordinal -= 0x100
            elif fmt == 2:    # DYLD_CHAINED_IMPORT_ADDEND
                raw, addend = struct.unpack("<Ii", blob[imports_off + 8 * i:imports_off + 8 * i + 8])
                ordinal, weak, name_off = raw & 0xFF, (raw >> 8) & 1, raw >> 9
                if ordinal >= 0xF0:
                    ordinal -= 0x100
            elif fmt == 3:    # DYLD_CHAINED_IMPORT_ADDEND64
                raw, addend = struct.unpack("<Qq", blob[imports_off + 16 * i:imports_off + 16 * i + 16])
                ordinal, weak, name_off = raw & 0xFFFF, (raw >> 16) & 1, raw >> 32
                if ordinal >= 0xFFF0:
                    ordinal -= 0x10000
            else:
                raise MachOError(f"chained import format {fmt} not read here")
            out.append(Import(ordinal, cstring(blob, symbols_off + name_off), bool(weak), addend))
        self._imports = out
        return out

    def chain(self):
        """Every fixup location in chain order: (vmaddr, the raw 64-bit value, pointer format)."""
        blob, (_, starts_off, *_rest) = self._header()
        seg_count = struct.unpack("<I", blob[starts_off:starts_off + 4])[0]
        for i in range(seg_count):
            info = struct.unpack("<I", blob[starts_off + 4 + 4 * i:starts_off + 8 + 4 * i])[0]
            if not info:
                continue
            at = starts_off + info
            _, page_size, fmt, _seg_offset, _, page_count = struct.unpack("<IHHQIH", blob[at:at + 22])
            if fmt not in CHAINED_POINTER_FORMATS:
                raise MachOError(f"chained pointer format {fmt} not read here")
            pages = struct.unpack(f"<{page_count}H", blob[at + 22:at + 22 + 2 * page_count])
            seg = self.segments[i]
            for p, start in enumerate(pages):
                if start == DYLD_CHAINED_PTR_START_NONE:
                    continue
                if start & DYLD_CHAINED_PTR_START_MULTI:
                    raise MachOError("multiple chain starts in a page are not read here")
                where = p * page_size + start
                while True:
                    if where + 8 > seg.filesize:
                        raise MachOError("a chain runs past its segment")
                    raw = struct.unpack("<Q", self.data[seg.fileoff + where:seg.fileoff + where + 8])[0]
                    yield seg.vmaddr + where, raw, fmt
                    step = (raw >> 51) & 0xFFF
                    if not step:
                        break
                    where += step * 4

    def decode(self, raw: int, fmt: int) -> tuple:
        """('bind', import index, addend) or ('rebase', unslid target, high byte) for one chain entry."""
        if raw >> 63:
            return "bind", raw & 0xFFFFFF, (raw >> 24) & 0xFF
        target, high8 = raw & ((1 << 36) - 1), (raw >> 36) & 0xFF
        return "rebase", (self.base + target if fmt == DYLD_CHAINED_PTR_64_OFFSET else target), high8

    def fixups(self) -> Fixups:
        """Walk every chain once: counts, and how often each import is bound."""
        imports = self.imports()
        bound = [0] * len(imports)
        formats, rebases, binds = set(), 0, 0
        for _, raw, fmt in self.chain():
            formats.add(fmt)
            kind, value, _ = self.decode(raw, fmt)
            if kind == "bind":
                if value >= len(imports):
                    raise MachOError(f"a bind names import {value} of {len(imports)}")
                bound[value] += 1
                binds += 1
            else:
                rebases += 1
        return Fixups(formats, rebases, binds, bound)

    def pointer(self, vmaddr: int) -> int | None:
        """A rebased pointer's target, unslid; None for a bind or a null."""
        raw = self.u64(vmaddr)
        if not raw or raw >> 63:
            return None
        if self.chained:
            target = raw & ((1 << 36) - 1)
            fmts = self.fixups_formats()
            return self.base + target if DYLD_CHAINED_PTR_64_OFFSET in fmts else target
        return raw

    def fixups_formats(self) -> set[int]:
        if not hasattr(self, "_formats"):
            self._formats = self.fixups().pointer_formats
        return self._formats

    def bound_import(self, vmaddr: int) -> Import | None:
        raw = self.u64(vmaddr)
        if not raw >> 63 or not self.chained:
            return None
        return self.imports()[raw & 0xFFFFFF]

    # --- exports ----------------------------------------------------------------------------
    def exports(self) -> dict[str, int]:
        if not self.exports_trie:
            return {}
        off, size = self.exports_trie
        trie = self.data[off:off + size]
        out: dict[str, int] = {}
        stack = [(0, "")]
        seen = set()
        while stack:
            node, prefix = stack.pop()
            if node in seen or node >= len(trie):
                raise MachOError("exports trie loops or runs past its data")
            seen.add(node)
            info_size, at = uleb(trie, node)
            if info_size:
                flags, p = uleb(trie, at)
                if not flags & 0x8:       # not a re-export
                    address, _ = uleb(trie, p)
                    out[prefix] = address
            at += info_size
            children = trie[at]
            at += 1
            for _ in range(children):
                end = trie.index(b"\0", at)
                label = trie[at:end].decode()
                child, at = uleb(trie, end + 1)
                stack.append((child, prefix + label))
        return out

    # --- Objective-C ------------------------------------------------------------------------
    def selectors(self) -> list[str]:
        refs = self.section("__DATA", "__objc_selrefs") or self.section("__DATA_CONST", "__objc_selrefs")
        if not refs:
            return []
        return [self.string_at(self.pointer(refs.addr + 8 * i)) for i in range(refs.size // 8)]

    def objc_stub_selectors(self) -> dict[int, str]:
        """__objc_stubs: stub address to the selector it sends (adrp/ldr x1 from a selref)."""
        stubs = self.section("__TEXT", "__objc_stubs")
        out = {}
        if not stubs:
            return out
        at = self.offset_of(stubs.addr)
        for k in range(stubs.size // 32):
            w0, w1 = struct.unpack("<2I", self.data[at + 32 * k:at + 32 * k + 8])
            page = adrp_target(stubs.addr + 32 * k, w0)
            ref = page + ((w1 >> 10) & 0xFFF) * 8
            out[stubs.addr + 32 * k] = self.string_at(self.pointer(ref))
        return out

    def objc_classes(self) -> list[dict]:
        """Classes the image defines: name, superclass (an import or one of its own), methods."""
        classlist = self.section("__DATA_CONST", "__objc_classlist") or self.section("__DATA", "__objc_classlist")
        if not classlist:
            return []
        out = []
        for i in range(classlist.size // 8):
            cls = self.pointer(classlist.addr + 8 * i)
            name, methods = self._class_ro(cls)
            meta = self.pointer(cls)
            _, class_methods = self._class_ro(meta) if meta else (None, [])
            sup_import = self.bound_import(cls + 8)
            if sup_import:
                superclass = sup_import.name.replace("_OBJC_CLASS_$_", "")
            else:
                sup = self.pointer(cls + 8)
                superclass = self._class_ro(sup)[0] if sup else None
            out.append({"name": name, "superclass": superclass, "methods": methods,
                        "class_methods": class_methods})
        return out

    def _class_ro(self, cls: int) -> tuple[str, list[str]]:
        ro = self.pointer(cls + 32) & ~7
        name = self.string_at(self.pointer(ro + 24))
        methods = []
        mlist = self.pointer(ro + 32)
        if mlist:
            at = self.offset_of(mlist)
            entsize_flags, count = struct.unpack("<2I", self.data[at:at + 8])
            entsize, relative = entsize_flags & 0xFFFC, entsize_flags & 0x80000000
            for k in range(count):
                entry = mlist + 8 + k * entsize
                if relative:
                    e = self.offset_of(entry)
                    delta = struct.unpack("<i", self.data[e:e + 4])[0]
                    methods.append(self.string_at(self.pointer(entry + delta)))
                else:
                    methods.append(self.string_at(self.pointer(entry)))
        return name, methods


def adrp_target(pc: int, word: int) -> int:
    immlo, immhi = (word >> 29) & 3, (word >> 5) & 0x7FFFF
    imm = (immhi << 2) | immlo
    if imm & (1 << 20):
        imm -= 1 << 21
    return (pc & ~0xFFF) + (imm << 12)


def _version(v: int) -> str:
    return f"{v >> 16}.{(v >> 8) & 0xFF}.{v & 0xFF}"


def load(path: str | Path, cpu: int = CPU_ARM64) -> tuple[bytes, Image]:
    """A file's whole bytes and its image for one architecture."""
    data = Path(path).read_bytes()
    return data, Image(thin(data, cpu))


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()
