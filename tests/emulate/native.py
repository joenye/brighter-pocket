"""The boot harness's own arm64 code: tests/emulate/native/*.c, built for iOS with the repo's
toolchain (tools/build_ios.py's) into build/emulate/native/libpocketnative.dylib when a source
is newer than the build, and loaded beside the client (boot.py) so its exports answer the
client's busiest imports as emulated instructions (native/heap.c says which and why).
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1] / "tools"))
import common  # noqa: E402

SOURCES = sorted((HERE / "native").glob("*.c"))
LIBRARY = common.BUILD / "emulate/native/libpocketnative.dylib"


def build() -> Path:
    if LIBRARY.is_file() and all(s.stat().st_mtime <= LIBRARY.stat().st_mtime for s in SOURCES):
        return LIBRARY
    import build_ios
    tools = build_ios.toolchain()
    LIBRARY.parent.mkdir(parents=True, exist_ok=True)
    command = [str(tools["llvm"] / "bin/clang"), "-target", build_ios.TARGET, "-isysroot", str(tools["sdk"]),
               "-O2", "-ffreestanding", "-fno-builtin", "-fno-stack-protector", "-Wall", "-Wextra", "-Werror",
               "-nostdlib", "-dynamiclib", "-fuse-ld=lld", "-Wl,-undefined,dynamic_lookup",
               "-install_name", "@rpath/libpocketnative.dylib", *map(str, SOURCES), "-o", str(LIBRARY)]
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode:
        raise SystemExit(f"building {LIBRARY.name} failed:\n{result.stderr}")
    return LIBRARY
