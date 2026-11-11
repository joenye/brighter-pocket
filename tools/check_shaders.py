#!/usr/bin/env python3
"""Check that the iPad's own Metal compiler path accepts every shader the client ships.

usage: tools/check_shaders.py [--client DIR]       (needs: pip install zstandard)

The macOS client keeps its shaders as Metal libraries (MTLB) in assetBundle4 (fragment)
and assetBundle7 (vertex): each bundle is a big-endian u32 header size, a zstd frame
holding the object count and one varint length per object, then one zstd frame per
object; an object is one or more (u32 little-endian size, MTLB) pairs. The client hands
each library to -[MTLDevice newLibraryWithData:error:], where Tolkara's Metal adapter
rewraps it for iOS (platform/translation/Metal/LibraryContainer.m,
AKLocalMetalLibraryData). A library that adapter refuses would need a translation made
on a Mac at run time, or pause the game. This applies the adapter's checks, rule for
rule (accepts() below), to every library and fails if any is refused: as this layer
patches them (pocket/patches/0003, AIR 1.x libraries), or with --pinned as the pinned
Tolkara has them.
"""
from __future__ import annotations

import argparse
import hashlib
import struct
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import common  # noqa: E402

SHADER_BUNDLES = {4: "fragment", 7: "vertex"}


def number(b: bytes, at: int, count: int) -> int:
    return int.from_bytes(b[at:at + count], "little")


def air_minor(container: int) -> int:
    """LibraryContainer.m airMinor(): legacy containers 2, 3, 5 hold AIR 2.0, 2.1, 2.3; current 7, 8 hold 2.6, 2.7."""
    return {2: 0, 3: 1, 5: 3, 7: 6, 8: 7}.get(container, -1)


def module_end(b: bytes, table: int, public_start: int, offset: int, code_size: int) -> int:
    """LegacyMetal.h AKMetalModuleEnd(): the next function's module offset after this one, else the code section's end."""
    end = max(code_size, offset)
    if public_start < table or public_start - table < 4:
        return end
    count, pos = number(b, table, 4), table + 4
    for _ in range(count):
        if public_start - pos < 4:
            break
        size = number(b, pos, 4)
        if size < 8 or size > public_start - pos:
            break
        record_end, pos = pos + size, pos + 4
        while record_end - pos >= 6:
            tag = b[pos:pos + 4]
            if tag == b"ENDT":
                break
            n = number(b, pos + 4, 2)
            pos += 6
            if n > record_end - pos:
                break
            if tag == b"OFFT" and n == 24:
                other = number(b, pos + 16, 8)
                if offset < other < end:
                    end = other
            pos += n
        pos = record_end
    return end


def air_version(b: bytes) -> str:
    """The AIR version the first function record names (VERS), for the summary."""
    at = b.find(b"VERS", 88)
    return f"{number(b, at + 6, 2)}.{number(b, at + 8, 2)}" if at > 0 else "?"


def accepts(b: bytes, air1_libraries: bool = True) -> str | None:
    """None when AKLocalMetalLibraryData would rewrap this library for iOS, else why not."""
    length = len(b)
    if length < 88 or length > 64 * 1024 * 1024 or b[:8] != b"MTLB\x01\x80\x02\x00":
        return "not a macOS Metal library of a known platform header"
    minor, legacy = air_minor(b[8]), b[8] < 7
    if minor < 0:
        return f"container version {b[8]} unknown"
    if number(b, 16, 8) != length:
        return "size field does not match"
    if legacy and number(b, 9, 7):
        return "legacy header bytes not zero"
    if not legacy and (b[9] or b[10] or b[11] != 0x81 or not b[12] or number(b, 13, 3)):
        return "current header does not name macOS"
    table, table_size, pub, pub_size, priv, priv_size, code, code_size = (number(b, 24 + 8 * i, 8) for i in range(8))

    def section(offset: int, size: int) -> bool:
        return 88 <= offset <= length and size <= length - offset

    if not (section(table, table_size) and section(pub, pub_size) and section(priv, priv_size) and section(code, code_size)
            and table <= pub and pub - table >= 4 and table_size <= pub - table and priv >= pub and pub_size <= priv - pub
            and code >= priv and priv_size <= code - priv):
        return "sections out of order or outside the file"
    count, pos = number(b, table, 4), table + 4
    if not count or count > 65536:
        return "function count out of range"
    for _ in range(count):
        if pos > pub or pub - pos < 4:
            return "function table cut short"
        size = number(b, pos, 4)
        if size < 8 or size > pub - pos:
            return "function record size out of range"
        end, pos = pos + size, pos + 4
        fields: dict[bytes, bytes] = {}
        terminated = False
        while end - pos >= 4:
            tag = b[pos:pos + 4]
            pos += 4
            if tag == b"ENDT":
                terminated = True
                break
            if end - pos < 2:
                return "tag cut short"
            n = number(b, pos, 2)
            pos += 2
            if n > end - pos:
                return "tag runs past its record"
            required = {b"HASH": 32, b"OFFT": 24, b"MDSZ": 8, b"VERS": 8}.get(tag)
            if required is not None:
                if tag in fields or n != required:
                    return f"{tag.decode()} repeated or of the wrong size"
                fields[tag] = b[pos:pos + n]
            pos += n
        # pocket/patches/0003: AIR 1.x in container 2 names no module size (LegacyMetal.h).
        version = fields.get(b"VERS")
        air1 = air1_libraries and b[8] == 2 and version is not None and number(version, 0, 2) == 1
        if not terminated or pos != end or b"HASH" not in fields or b"OFFT" not in fields or not version \
                or (b"MDSZ" not in fields and not air1):
            return "function record incomplete"
        if not air1 and (number(version, 0, 2) != 2 or number(version, 2, 2) != minor):
            return "AIR version does not match the container"
        offset = number(fields[b"OFFT"], 16, 8)
        n = number(fields[b"MDSZ"], 0, 8) if b"MDSZ" in fields else module_end(b, table, pub, offset, code_size) - offset
        if offset > code_size or n > code_size - offset or n < 24:
            return "module outside the code section"
        module = b[code + offset:code + offset + n]
        start, bitcode = number(module, 8, 4), number(module, 12, 4)
        if (number(module, 0, 4) != 0x0B17C0DE or number(module, 4, 4) or start < 20 or start > n
                or bitcode < 4 or bitcode > n - start or module[start:start + 4] != b"BC\xc0\xde"):
            return "module is not wrapped LLVM bitcode"
        if hashlib.sha256(module).digest() != fields[b"HASH"]:
            return "module hash does not match"
    return None


def varint(b: bytes, at: int) -> tuple[int, int]:
    value = shift = 0
    while True:
        byte = b[at]
        at += 1
        value |= (byte & 0x7F) << shift
        shift += 7
        if not byte & 0x80:
            return value, at


def libraries(bundle: Path):
    """(object index, library bytes) for every Metal library in a shader bundle."""
    import zstandard
    data = bundle.read_bytes()
    header_size = struct.unpack(">I", data[:4])[0]
    header = zstandard.ZstdDecompressor().decompressobj().decompress(data[4:4 + header_size])
    count, at = varint(header, 0)
    start = 4 + header_size
    for index in range(count):
        length, at = varint(header, at)
        obj = zstandard.ZstdDecompressor().decompressobj().decompress(data[start:start + length])
        start += length
        pos = 0
        while pos < len(obj):
            size = struct.unpack("<I", obj[pos:pos + 4])[0]
            if pos + 4 + size > len(obj):
                raise SystemExit(f"{bundle.name} object {index}: a library runs past the object")
            yield index, obj[pos + 4:pos + 4 + size]
            pos += 4 + size
    if start != len(data):
        raise SystemExit(f"{bundle.name}: the object table does not cover the file")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--client", type=Path, help="a client/ folder or a Brighter Shores.app (default: newest download)")
    parser.add_argument("--pinned", action="store_true", help="the pinned Tolkara's rules, without pocket/patches/0003")
    args = parser.parse_args()
    try:
        import zstandard  # noqa: F401
    except ImportError:
        raise SystemExit("needs the zstandard module: pip install zstandard")
    app = common.client_app(args.client)
    refused = 0
    for number_, role in SHADER_BUNDLES.items():
        bundle = app / f"Contents/Resources/assetBundle{number_}"
        kinds, reasons, total = Counter(), Counter(), 0
        for _, library in libraries(bundle):
            total += 1
            kinds[f"container {library[8]}, AIR {air_version(library)}"] += 1
            reason = accepts(library, air1_libraries=not args.pinned)
            if reason:
                reasons[reason] += 1
        refused += sum(reasons.values())
        print(f"assetBundle{number_} ({role}): {total} libraries, {total - sum(reasons.values())} accepted; "
              + ", ".join(f"{kind}: {n}" for kind, n in sorted(kinds.items())))
        for reason, n in reasons.most_common():
            print(f"  refused {n}: {reason}")
    if refused:
        raise SystemExit(f"{refused} libraries would not load through the on-device path")
    print("every shader library is accepted by the on-device rewrap")


if __name__ == "__main__":
    main()
