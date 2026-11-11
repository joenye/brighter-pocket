#!/usr/bin/env python3
"""Stage the client as the device's Documents folder holds it, without a device.

usage: tools/stage_client.py [--client DIR | --source STEAM_FOLDER] [--out build/stage]

The staging is the profile helper's (pocket/profiles/brighter-shores/install.py, the one
implementation): Brighter Shores.app unchanged in <out>/Brighter Shores/, Valve's
libsteam_api.dylib left out, the executable's SHA-256 checked and written to stage.json.
This adds the loader's first checks on the executable (an unencrypted arm64 executable
with chained fixups, tools/macho.py) and takes a download from tools/fetch_client.py
(--client, default the newest) or a Steam install folder (--source). Copy the result
with the profile helper, the Files app, or devicectl.
"""
from __future__ import annotations

import argparse
import importlib.util
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import common  # noqa: E402
import macho  # noqa: E402

INSTALLER = common.ROOT / "pocket/profiles/brighter-shores/install.py"


def installer():
    spec = importlib.util.spec_from_file_location("brighter_shores_install", INSTALLER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def check_executable(path: Path) -> None:
    """The loader's own first questions: an arm64 executable it can read."""
    _, image = macho.load(path)
    if image.filetype != macho.MH_EXECUTE:
        raise SystemExit(f"{path} is not an executable")
    if image.encrypted:
        raise SystemExit(f"{path} is encrypted")
    if not image.chained:
        raise SystemExit(f"{path} has no chained fixups; this client build is not one the tools know")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    where = parser.add_mutually_exclusive_group()
    where.add_argument("--client", type=Path, help="a download from tools/fetch_client.py")
    where.add_argument("--source", type=Path, help="a folder holding Brighter Shores.app (a Steam install)")
    parser.add_argument("--out", type=Path, default=common.BUILD / "stage")
    args = parser.parse_args()
    install = installer()
    app = (args.source / install.APP) if args.source else common.client_app(args.client)
    check_executable(app / common.BUNDLE_EXECUTABLE)
    record = install.stage(app, args.out)
    total = sum(f["size"] for f in record["files"])
    print(f"staged {len(record['files'])} files, {total / 1e9:.2f} GB, in {args.out / install.FOLDER}")
    print(f"executable sha256 {record['executable_sha256']}")


if __name__ == "__main__":
    main()
