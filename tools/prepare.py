#!/usr/bin/env python3
"""Prepare the tree the app is built from: Tolkara as pinned, with the layer applied.

usage: tools/prepare.py [--out build/platform]

1. platform/ must be byte-identical to the Tolkara commit pocket/platform.lock names
   (git's tree hash of the folder, uncommitted changes included).
2. It is copied to <out>, and each pocket/patches/*.patch is applied in order; one that
   no longer applies stops the run.
3. pocket/overlay.map's files are copied in: an 'add' must not collide with a path the
   platform has, a 'replace' must find one. Every file in pocket/ but the map, the pin
   and the patches must be in the map.
4. The repository's local.env, if any, is copied in, where the platform's tools read it.

The platform's own scripts then build from <out> (tools/install.sh, tools/package_ipa.sh)
without knowing the layer exists; tools/build_ios.py builds the same tree as Brighter
Pocket, for a device or the simulator. Runs with the Python 3.9 macOS ships.
"""
from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import common  # noqa: E402

PLATFORM = common.ROOT / "platform"
LAYER = common.ROOT / "pocket"
# What pocket/ holds besides the files it maps into the tree: the map, the pin and the patches.
UNMAPPED = ("overlay.map", "platform.lock", "patches")


def lock() -> dict:
    values = {}
    for line in (LAYER / "platform.lock").read_text().splitlines():
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip()
    return values


def platform_tree() -> str:
    """git's tree hash of platform/ as it is on disk, through a scratch index."""
    with tempfile.TemporaryDirectory() as tmp:
        env = dict(os.environ, GIT_INDEX_FILE=str(Path(tmp) / "index"))
        subprocess.run(["git", "add", "-f", "platform"], cwd=common.ROOT, env=env, check=True)
        out = subprocess.run(["git", "write-tree", "--prefix=platform/"], cwd=common.ROOT, env=env,
                             check=True, capture_output=True, text=True)
        return out.stdout.strip()


def overlay_entries() -> list[tuple[Path, str, str]]:
    entries = []
    for number, line in enumerate((LAYER / "overlay.map").read_text().splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) != 3 or parts[2] not in ("add", "replace"):
            raise SystemExit(f"overlay.map:{number}: expected '<layer file> <tree path> add|replace'")
        source, target, kind = parts
        if not (common.ROOT / source).is_file():
            raise SystemExit(f"overlay.map:{number}: {source} does not exist")
        if Path(target).is_absolute() or ".." in Path(target).parts:
            raise SystemExit(f"overlay.map:{number}: {target} must stay inside the tree")
        entries.append((common.ROOT / source, target, kind))
    mapped = {source.resolve() for source, _, _ in entries}
    for path in sorted(LAYER.rglob("*")):
        relative = path.relative_to(LAYER)
        if (path.is_file() and relative.parts[0] not in UNMAPPED and "__pycache__" not in path.parts
                and path.name != ".DS_Store" and path.resolve() not in mapped):
            raise SystemExit(f"{path.relative_to(common.ROOT)} is not in pocket/overlay.map")
    return entries


def apply_patch(patch: Path, tree: Path) -> None:
    relative = os.path.relpath(tree, common.ROOT)
    for check in (["--check"], []):
        result = subprocess.run(["git", "apply", *check, f"--directory={relative}", "-p1", str(patch)],
                                cwd=common.ROOT, capture_output=True, text=True)
        if result.returncode:
            raise SystemExit(f"{patch.name} does not apply:\n{result.stderr}")


def prepare(out: Path) -> None:
    pinned = lock()
    actual = platform_tree()
    if actual != pinned["tree"]:
        raise SystemExit(f"platform/ is not Tolkara {pinned['commit'][:12]} as pinned "
                         f"(tree {actual[:12]}, expected {pinned['tree'][:12]}); change it only through pocket/patches")
    entries = overlay_entries()
    if out.exists():
        shutil.rmtree(out)
    shutil.copytree(PLATFORM, out, symlinks=True)
    patches = sorted((LAYER / "patches").glob("*.patch"))
    for patch in patches:
        apply_patch(patch, out)
    for source, target, kind in entries:
        dest = out / target
        if kind == "add" and dest.exists():
            raise SystemExit(f"overlay: {target} now exists upstream; decide whether ours still belongs ('add' collides)")
        if kind == "replace" and not dest.is_file():
            raise SystemExit(f"overlay: {target} no longer exists upstream ('replace' finds nothing)")
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, dest)
    env = common.ROOT / "local.env"
    if env.is_file():
        shutil.copy2(env, out / "local.env")
    print(f"prepared {out}: Tolkara {pinned['commit'][:12]}, {len(patches)} patch(es), {len(entries)} layer file(s)")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", type=Path, default=common.BUILD / "platform")
    args = parser.parse_args()
    prepare(args.out.resolve())


if __name__ == "__main__":
    main()
