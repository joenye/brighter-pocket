#!/usr/bin/env python3
"""What the macOS client needs from the operating system, and who provides it on iOS.

usage: tools/analyze_client.py [--client DIR] [--sdk IPHONEOS_SDK | --no-sdk] [--out out/client-surface.md]

Reads the arm64 slice of Brighter Shores.app's executable (tools/macho.py, no Mac tools)
and writes a report: the build's identity, the libraries it links, every import sorted
by library and by who answers it on the device (the iOS SDK's own library, a Tolkara
adapter in platform/translation, or one of this layer's in pocket/translation), the
Objective-C classes it defines, the Steam interfaces it asks for, its network calls and
whether it ever makes its own code writable (which decides how Local signing must be set
up). Symbols are checked against the iPhoneOS SDK's .tbd files: Xcode's (xcrun), or --sdk;
--no-sdk skips that check. The report holds Apple and Steam API names and facts about the
file only.
Exits non-zero when an import has no provider at all.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import common  # noqa: E402
import macho  # noqa: E402

# Imports that would mean the client writes or generates code at run time.
CODE_WRITING = {"_mprotect", "_vm_protect", "_mach_vm_protect", "_pthread_jit_write_protect_np",
                "_sys_icache_invalidate", "___clear_cache", "_vm_remap", "_mach_vm_remap"}
NETWORK = {"_socket", "_connect", "_getaddrinfo", "_gethostbyname", "_bind", "_listen", "_accept",
           "_sendto", "_recvfrom", "_send", "_recv", "_poll", "_select", "_getsockopt", "_setsockopt"}
STEAM_INTERFACE = re.compile(rb"\b(Steam[A-Za-z]+0\d\d|STEAM[A-Z_]+(?:VERSION|_V)0\d\d)\b")
TBD_KEYS = ("symbols", "weak-symbols", "thread-local-symbols")


def tbd_documents(path: Path) -> list[tuple[str, set[str], list[str]]]:
    """Each document of a text-based stub: (install name, symbols it exports, libraries it re-exports)."""
    text = path.read_text(errors="replace")
    out = []
    for doc in text.split("--- !tapi-tbd")[1:] or [text]:
        name = re.search(r"install-name:\s*'?([^'\n]+)'?", doc)
        if not name:
            continue
        symbols: set[str] = set()
        for key in TBD_KEYS:
            for body in re.findall(rf"\b{key}:\s*\[(.*?)\]", doc, re.S):
                symbols |= {s.strip().strip("'\"") for s in body.split(",") if s.strip()}
        for body in re.findall(r"objc-classes:\s*\[(.*?)\]", doc, re.S):
            for cls in (s.strip().strip("'\"") for s in body.split(",") if s.strip()):
                symbols |= {"_OBJC_CLASS_$_" + cls, "_OBJC_METACLASS_$_" + cls}
        reexports = [s.strip().strip("'\"") for body in re.findall(r"reexported-libraries:.*?libraries:\s*\[(.*?)\]", doc, re.S)
                     for s in body.split(",") if s.strip()]
        reexports += [s.strip().strip("'\"") for body in re.findall(r"\bre-exports:\s*\[(.*?)\]", doc, re.S)
                      for s in body.split(",") if s.strip()]
        out.append((name.group(1).strip(), symbols, reexports))
    return out


def sdk_symbols(sdk: Path) -> set[str]:
    """Every symbol a public library or framework of the SDK exports, with what it re-exports
    (private frameworks count only through a public one that re-exports them)."""
    exports: dict[str, set[str]] = defaultdict(set)
    reexports: dict[str, list[str]] = defaultdict(list)
    public: set[str] = set()
    for root in ("usr/lib", "System/Library/Frameworks", "System/Library/PrivateFrameworks"):
        for tbd in (sdk / root).rglob("*.tbd"):
            for name, symbols, again in tbd_documents(tbd):
                exports[name] |= symbols
                reexports[name] += again
                if "PrivateFrameworks" not in root:
                    public.add(name)
    out: set[str] = set()
    seen: set[str] = set()
    stack = list(public)
    while stack:
        name = stack.pop()
        if name in seen:
            continue
        seen.add(name)
        out |= exports.get(name, set())
        stack += reexports.get(name, [])
    return out


def leaf(install_name: str) -> str:
    name = install_name.rsplit("/", 1)[-1]
    return name[:-len(".dylib")] if name.endswith(".dylib") else name


def adapters() -> dict[str, list[Path]]:
    """Hand-written adapters by leaf: Tolkara's, then this layer's (which the overlay adds)."""
    found: dict[str, list[Path]] = defaultdict(list)
    for root in (common.ROOT / "platform/translation", common.ROOT / "pocket/translation"):
        if not root.is_dir():
            continue
        for d in sorted(p for p in root.iterdir() if p.is_dir()):
            if (d / "experimental").exists() or (d / "absent").exists():
                continue
            sources = [p for p in d.iterdir() if p.suffix in (".c", ".m") or p.name == "ldflags"]
            if sources:
                found[d.name].extend(sources)
    return found


def defined_in(sources: list[Path], symbol: str) -> bool:
    """Whether a hand-written adapter defines a C function, an Objective-C class or a variable of this name."""
    name = symbol[1:]
    cls = name.split("$_", 1)[1] if name.startswith(("OBJC_CLASS_$_", "OBJC_METACLASS_$_")) else None
    for src in sources:
        if src.name == "ldflags":
            continue
        text = src.read_text(errors="replace")
        if cls and re.search(rf"@implementation\s+{re.escape(cls)}\b", text):
            return True
        if not cls and re.search(rf"[\w\*\)]\s+\(?\*?\s*{re.escape(name)}\s*\)?\s*\((?![^)]*\)\s*;)", text):
            return True
        if not cls and re.search(rf"^\s*(?:const\s+)?[\w\s\*]+\b{re.escape(name)}\s*(=|;|\[)", text, re.M):
            return True
    return False


def analyze(app: Path, sdk: Path | None) -> dict:
    data, image = macho.load(app / common.BUNDLE_EXECUTABLE)
    fat = macho.slices(data)
    fixups = image.fixups()
    imports = image.imports()
    by_library: dict[str, list[macho.Import]] = defaultdict(list)
    for imp in imports:
        by_library[image.library(imp.ordinal)].append(imp)
    available = sdk_symbols(sdk) if sdk else None
    written = adapters()
    exports = image.exports()
    libraries = []
    unprovided = []
    for dylib in image.dylibs:
        lib_imports = by_library.get(dylib.path, [])
        name = leaf(dylib.path)
        rows = []
        for imp in sorted(lib_imports, key=lambda i: i.name):
            sources = written.get(name, [])
            if sources and defined_in(sources, imp.name):
                provider = "adapter"
            elif available is not None and imp.name in available:
                provider = "ios"
            elif available is None and not dylib.path.startswith("@") and name not in written:
                provider = "ios?"
            elif sources:
                provider = "adapter-stub"
            else:
                provider = "none"
                unprovided.append(f"{name}: {imp.name}")
            rows.append({"symbol": imp.name, "weak": imp.weak, "provider": provider})
        origin = ("pocket" if (common.ROOT / "pocket/translation" / name).is_dir()
                  else "tolkara" if (common.ROOT / "platform/translation" / name).is_dir() else None)
        libraries.append({"path": dylib.path, "kind": dylib.kind, "adapter": origin, "imports": rows})
    special = {lib: [i.name for i in imps] for lib, imps in by_library.items() if lib.startswith("<")}
    for lib, names in special.items():
        for n in names:
            if n not in exports and available is not None and n not in available:
                unprovided.append(f"{lib}: {n}")
    names = {i.name for i in imports}
    text = image.section("__TEXT", "__text")
    steam = sorted({m.decode() for m in STEAM_INTERFACE.findall(image.data)})
    init = image.section("__TEXT", "__init_offsets")
    return {
        "executable": str(common.BUNDLE_EXECUTABLE),
        "sha256": macho.sha256(data),
        "arm64_sha256": macho.sha256(image.data),
        "slices": [{"arch": s.arch, "size": s.size} for s in fat],
        "uuid": image.uuid, "platform": image.platform, "minos": image.minos, "built_sdk": image.sdk,
        "encrypted": image.encrypted,
        "segments": [{"name": s.name, "vmsize": s.vmsize, "maxprot": s.maxprot, "initprot": s.initprot}
                     for s in image.segments],
        "text_size": text.size if text else 0,
        "fixups": {"formats": sorted(macho.CHAINED_POINTER_FORMATS[f] for f in fixups.pointer_formats),
                   "rebases": fixups.rebases, "binds": fixups.binds,
                   "unbound_imports": sum(1 for n in fixups.bound if not n)},
        "initializers": init.size // 4 if init else 0,
        "thread_locals": bool(image.flags & 0x800000),
        "libraries": libraries,
        "coalesced": special,
        "objc_classes": image.objc_classes(),
        "selectors": len(image.selectors()),
        "steam_interfaces": steam,
        "network_imports": sorted(n for n in names if n in NETWORK),
        "code_writing_imports": sorted(n for n in names if n in CODE_WRITING),
        "unprovided": unprovided,
        "sdk": str(sdk) if sdk else None,
    }


def markdown(r: dict) -> str:
    out = ["# Client surface", "", "Generated by tools/analyze_client.py; do not edit. API names and file facts only.", ""]
    out += ["## Identity", "", "|field|value|", "|---|---|",
            f"|executable|`{r['executable']}`|", f"|SHA-256 (universal)|`{r['sha256']}`|",
            f"|SHA-256 (arm64 slice)|`{r['arm64_sha256']}`|",
            "|slices|" + ", ".join("{} ({:,} bytes)".format(s["arch"], s["size"]) for s in r["slices"]) + "|",
            f"|UUID (arm64)|`{r['uuid']}`|", f"|built for|{r['platform']} {r['minos']} (SDK {r['built_sdk']})|",
            f"|encrypted|{r['encrypted']}|", f"|`__text`|{r['text_size']:,} bytes|",
            f"|fixups|chained, {', '.join(r['fixups']['formats'])}: {r['fixups']['rebases']:,} rebases, "
            f"{r['fixups']['binds']:,} binds|",
            f"|initializers|{r['initializers']}|", f"|thread-local variables|{r['thread_locals']}|", ""]
    out += ["## Code memory", ""]
    if r["code_writing_imports"]:
        out.append("The client imports " + ", ".join(f"`{n}`" for n in r["code_writing_imports"]) +
                   ": it may write its own code, so a Local-signing page container needs a capture of its final pages.")
    else:
        out.append("No import that could make code writable (" + ", ".join(f"`{n}`" for n in sorted(CODE_WRITING)) +
                   "): the client runs the code in its file as it is, so a Local-signing page container can be "
                   "built from the file's own `__TEXT` pages.")
    out += ["", "## Libraries", "", "|library|linked as|adapter|imports|on iOS|adapter|adapter stub|none|", "|---|---|---|---:|---:|---:|---:|---:|"]
    for lib in r["libraries"]:
        counts = defaultdict(int)
        for row in lib["imports"]:
            counts[row["provider"].rstrip("?")] += 1
        out.append(f"|`{lib['path']}`|{lib['kind']}|{lib['adapter'] or ''}|{len(lib['imports'])}|{counts['ios']}|"
                   f"{counts['adapter']}|{counts['adapter-stub']}|{counts['none']}|")
    if not r["sdk"]:
        out += ["", "No iOS SDK given: imports of libraries without an adapter are assumed present on iOS (`ios?`)."]
    for lib in r["libraries"]:
        if not lib["imports"]:
            continue
        out += ["", f"### {lib['path'].rsplit('/', 1)[-1]}", ""]
        out.append(", ".join(f"`{row['symbol']}`" + ("" if row["provider"] in ("ios", "ios?") else f" ({row['provider']})")
                             for row in lib["imports"]))
    if r["coalesced"]:
        out += ["", "### Bound by name", ""]
        for lib, names in r["coalesced"].items():
            out.append(f"{lib}: " + ", ".join(f"`{n}`" for n in names))
    out += ["", "## Objective-C classes the client defines", ""]
    for c in r["objc_classes"]:
        out.append(f"- `{c['name']}` : `{c['superclass']}`: " + ", ".join(f"`{m}`" for m in c["methods"] + c["class_methods"]))
    out += ["", f"{r['selectors']} selectors referenced.", "", "## Steam", ""]
    out.append("Interface versions named in the file: " + ", ".join(f"`{s}`" for s in r["steam_interfaces"]) + ".")
    out += ["", "## Network", "", "Network imports: " + ", ".join(f"`{n}`" for n in r["network_imports"]) + "."]
    out += ["", "## Unprovided", ""]
    out.append("None." if not r["unprovided"] else "\n".join(f"- `{u}`" for u in r["unprovided"]))
    return "\n".join(out) + "\n"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--client", type=Path, help="a client/ folder or a Brighter Shores.app (default: newest download)")
    parser.add_argument("--sdk", type=Path, help="an iPhoneOS SDK folder (default: Xcode's)")
    parser.add_argument("--no-sdk", action="store_true", help="do not check imports against an SDK")
    parser.add_argument("--out", type=Path, default=common.OUT / "client-surface.md")
    parser.add_argument("--json", type=Path, help="also write the analysis as JSON")
    args = parser.parse_args()
    sdk = None if args.no_sdk else Path(args.sdk) if args.sdk else common.sdk_path("iphoneos")
    if sdk and not (sdk / "SDKSettings.json").is_file():
        raise SystemExit(f"{sdk} is not an SDK folder (no SDKSettings.json)")
    report = analyze(common.client_app(args.client), sdk)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(markdown(report))
    if args.json:
        args.json.write_text(json.dumps(report, indent=1))
    print(f"{args.out}: {sum(len(lib['imports']) for lib in report['libraries'])} imports, "
          f"{len(report['unprovided'])} unprovided")
    if report["unprovided"]:
        print("\n".join("  unprovided: " + u for u in report["unprovided"]))
        sys.exit(1)


if __name__ == "__main__":
    main()
