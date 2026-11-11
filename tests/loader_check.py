#!/usr/bin/env python3
"""Compare what Tolkara's loader wrote (tests/loader_test.c) with tools/macho.py's own
reading of the same chained fixups: every location, every rebased value, every bound
symbol. Two independent decoders agreeing on all of the client's ~65,000 pointers is
the evidence that the device's loader places this executable as dyld would.

usage: loader_check.py <executable> <observed file> <slide hex>
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import macho  # noqa: E402


def main() -> int:
    executable, observed_path, slide = sys.argv[1], Path(sys.argv[2]), int(sys.argv[3], 16)
    _, image = macho.load(executable)
    imports = image.imports()
    observed = {}
    for line in observed_path.read_text().splitlines():
        address, value, symbol = line.split(" ", 2)
        observed[int(address, 16)] = (int(value, 16), None if symbol == "-" else symbol)
    expected = 0
    problems = []
    for vmaddr, raw, fmt in image.chain():
        expected += 1
        kind, value, extra = image.decode(raw, fmt)
        got = observed.pop(vmaddr, None)   # the image's memory is at its preferred addresses
        if got is None:
            problems.append(f"{vmaddr:#x}: not written")
            continue
        if kind == "rebase":
            want = (value + slide) | (extra << 56)
            if got != (want, None):
                problems.append(f"{vmaddr:#x}: rebase wrote {got[0]:#x}, expected {want:#x}")
        elif got[1] != imports[value].name:
            problems.append(f"{vmaddr:#x}: bound {got[1]}, expected {imports[value].name}")
    problems += [f"{address:#x}: written but no fixup is there" for address in observed]
    for problem in problems[:20]:
        print("  " + problem)
    print(f"loader check: {expected} fixups, {len(problems)} differences")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
