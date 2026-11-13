#!/usr/bin/env python3
"""Translate every shader library of the client on a Mac at once, for a device that refuses them.

usage: tools/translate_shaders.py [--client DIR] [--out DIR] [--simulator] [--keys]
       tools/translate_shaders.py [--client DIR] [--out DIR] --push [--device UDID] [--via devicectl|pymobiledevice3]

Only needed if the device's own Metal compiler refuses the client's AIR 1.8 libraries (the
Diagnostics log says "On-device Metal library <key>: rejected"). Tolkara's fallback then
asks a Mac for each library over USB while the game waits (serve_shader_translation.py,
one library at a time). This does the same translation for all of them before the first
run: each distinct library in assetBundle4 and assetBundle7 (500 of the 536 are distinct)
goes through the prepared tree's tools/translate_metallib.py (build/platform, with
pocket/patches/0004) and is written to DIR as <key>.metallib with <key>.metallib.json
({"length", "sha256"} of the result), the key being the SHA-256 of the library's bytes as
the client hands them to Metal. That is the cache Tolkara's Metal adapter reads from
Documents/TranslatedShaders before it asks for anything (translation/Metal/Devices.m,
translatedLibraryData), so with these copied there the game never waits. --push copies
DIR there over USB, as the profile's install.py copies the game. Libraries already
translated in DIR are kept. --keys lists the keys and translates nothing (any OS).

--simulator translates for the iOS Simulator instead (pocket/patches/0007), into
build/translated-shaders-simulator by default: its Metal runs no desktop AIR, so there the
translations are the only route (pocket/patches/0008), and tools/run_simulator.py makes
and copies them itself.

Needs Xcode's Metal toolchain (xcodebuild -downloadComponent MetalToolchain), or
METAL_COMPILER naming its metal binary, and pip install zstandard.
"""
from __future__ import annotations

import argparse
import hashlib
import concurrent.futures
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import check_shaders  # noqa: E402
import common  # noqa: E402

DESTINATION = "Documents/TranslatedShaders"


def distinct_libraries(app: Path) -> dict[str, bytes]:
    """key (SHA-256 of the bytes) -> library, for every library in the two shader bundles."""
    found = {}
    for number in check_shaders.SHADER_BUNDLES:
        for _, library in check_shaders.libraries(app / f"Contents/Resources/assetBundle{number}"):
            found[hashlib.sha256(library).hexdigest()] = library
    return found


def translated(out: Path, key: str) -> bool:
    """True if <key>.metallib is there and matches its manifest, as the adapter checks it."""
    library, manifest = out / f"{key}.metallib", out / f"{key}.metallib.json"
    if not (library.is_file() and manifest.is_file()):
        return False
    ready = json.loads(manifest.read_text())
    data = library.read_bytes()
    return len(data) == ready.get("length") and hashlib.sha256(data).hexdigest() == ready.get("sha256")


def translator(platform: Path):
    path = platform / "tools/translate_metallib.py"
    if not path.is_file():
        raise SystemExit(f"no {path}: run tools/prepare.py first")
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location("translate_metallib", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def translate_all(libraries: dict[str, bytes], out: Path, platform: Path, simulator: bool = False) -> list[str]:
    """Translate what DIR lacks, one library per core; returns the keys that failed (each with
    <key>.error in DIR)."""
    os.environ.update(common.xcode_env())   # translate_metallib.py finds the compiler through xcodebuild
    module = translator(platform)
    out.mkdir(parents=True, exist_ok=True)
    compiler = module.compiler_path()
    todo = [key for key in sorted(libraries) if not translated(out, key)]
    print(f"{len(libraries)} distinct libraries, {len(libraries) - len(todo)} already translated in {out}")

    def one(key: str, tmp: str) -> str | None:
        source = Path(tmp) / f"{key}.input.metallib"
        source.write_bytes(libraries[key])
        result = out / f"{key}.metallib"
        try:
            module.translate(source, result, compiler, simulator=simulator)
        except (ValueError, OSError, subprocess.CalledProcessError) as error:
            detail = getattr(error, "stderr", None) or str(error)
            detail = detail.decode(errors="replace") if isinstance(detail, bytes) else detail
            (out / f"{key}.error").write_text(detail)
            return detail.strip().splitlines()[-1] if detail.strip() else str(error)
        data = result.read_bytes()
        (out / f"{key}.metallib.json").write_text(json.dumps({"length": len(data), "sha256": hashlib.sha256(data).hexdigest()}))
        (out / f"{key}.error").unlink(missing_ok=True)
        return None

    failed = []
    with tempfile.TemporaryDirectory(prefix="pocket-shaders-") as tmp, \
            concurrent.futures.ThreadPoolExecutor(max_workers=os.cpu_count() or 4) as pool:
        futures = {pool.submit(one, key, tmp): key for key in todo}
        for i, future in enumerate(concurrent.futures.as_completed(futures), 1):
            key, problem = futures[future], future.result()
            if problem:
                failed.append(key)
            print(f"[{i}/{len(todo)}] {key}: " + (f"failed: {problem}" if problem else "translated"))
    return failed


def push(out: Path, device: str, via: str) -> None:
    sys.path.insert(0, str(common.ROOT / "pocket/profiles/brighter-shores"))
    from install import bundle_id
    if via == "devicectl":
        subprocess.run(["xcrun", "devicectl", "device", "copy", "to", "--device", device,
                        "--domain-type", "appDataContainer", "--domain-identifier", bundle_id(),
                        "--source", str(out), "--destination", DESTINATION], check=True)
    else:
        subprocess.run([sys.executable, "-m", "pymobiledevice3", "apps", "push", "--udid", device,
                        "--documents", bundle_id(), str(out), DESTINATION.removeprefix("Documents/")], check=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--client", type=Path, help="a client/ folder or a Brighter Shores.app (default: newest download)")
    parser.add_argument("--out", type=Path, help="default: build/translated-shaders (-simulator with --simulator)")
    parser.add_argument("--simulator", action="store_true", help="translate for the iOS Simulator instead of a device")
    parser.add_argument("--platform", type=Path, default=common.BUILD / "platform", help="the prepared tree")
    parser.add_argument("--keys", action="store_true", help="list the libraries' keys and stop")
    parser.add_argument("--push", action="store_true", help=f"then copy DIR to {DESTINATION} on the device")
    parser.add_argument("--device", help="the device UDID (default: DEVICE in local.env)")
    parser.add_argument("--via", choices=["devicectl", "pymobiledevice3"], default="devicectl")
    args = parser.parse_args()
    if args.simulator and args.push:
        parser.error("--push copies to a device; tools/run_simulator.py copies the simulator's")
    args.out = args.out or common.BUILD / ("translated-shaders-simulator" if args.simulator else "translated-shaders")
    libraries = distinct_libraries(common.client_app(args.client))
    if args.keys:
        print("\n".join(sorted(libraries)))
        return 0
    failed = translate_all(libraries, args.out, args.platform, args.simulator)
    if failed:
        print(f"{len(failed)} of {len(libraries)} failed; their reasons are in {args.out}/<key>.error")
        return 1
    print(f"all {len(libraries)} translated into {args.out}")
    if args.push:
        device = args.device or common.setting("DEVICE") or os.environ.get("DEVICE")
        if not device:
            parser.error("pass --device or set DEVICE")
        push(args.out, device, args.via)
        print(f"copied to {DESTINATION} on {device}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
