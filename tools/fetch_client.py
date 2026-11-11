#!/usr/bin/env python3
"""Download the macOS Brighter Shores client from Steam, unchanged, into client/.

usage: tools/fetch_client.py [--manifest ID] [--qr] [--executable-only]
       tools/fetch_client.py --list           # the public manifest, nothing downloaded

The macOS depot (2791442 of app 2791440) holds one universal Brighter Shores.app
(x86_64 and arm64). It lands in client/<YYYY-MM-DD>_<manifest>/ exactly as
DepotDownloader writes it, with a .complete marker naming the executable's SHA-256.
This talks to Steam's content servers only, never to the game's servers, and needs a
Steam account that owns the game: STEAM_USER in local.env (DepotDownloader keeps the
login token beside its binary after the first login; --qr logs in with the Steam app).
DEPOT_DOWNLOADER names the DepotDownloader binary (default: Brighter Atlas's, beside
this repository, so its remembered login is reused).
"""
from __future__ import annotations

import argparse
import hashlib
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import common  # noqa: E402

APP_ID = 2791440
MAC_DEPOT = 2791442
MANIFEST_LINE = re.compile(r"Manifest (\d+) \((\d\d)/(\d\d)/(\d{4}) (\d\d):(\d\d):(\d\d)\)")


def downloader() -> Path:
    named = common.setting("DEPOT_DOWNLOADER")
    path = Path(named) if named else common.ROOT.parent / "brighter-atlas/releases/tools/depotdownloader/DepotDownloader"
    if not path.is_file():
        raise SystemExit(f"DepotDownloader not found at {path}: set DEPOT_DOWNLOADER in local.env")
    return path


def run(args: list[str]) -> str:
    env = dict(os.environ, DOTNET_SYSTEM_GLOBALIZATION_INVARIANT="1")
    proc = subprocess.run(args, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    sys.stdout.write(proc.stdout)
    if proc.returncode:
        raise SystemExit(f"DepotDownloader failed (exit {proc.returncode})")
    return proc.stdout


def login(args: argparse.Namespace) -> list[str]:
    if args.qr:
        return ["-qr", "-remember-password"]
    user = common.setting("STEAM_USER")
    if not user:
        raise SystemExit("set STEAM_USER in local.env (or log in once with --qr)")
    return ["-username", user, "-remember-password"]


def manifest_of(output: str) -> tuple[str, str]:
    """(manifest id, YYYY-MM-DD) from DepotDownloader's 'Manifest <id> (MM/DD/YYYY ...)' line."""
    found = MANIFEST_LINE.search(output)
    if not found:
        raise SystemExit("DepotDownloader printed no 'Manifest <id> (<date>)' line")
    manifest, month, day, year = found.group(1), found.group(2), found.group(3), found.group(4)
    if int(month) > 12:
        raise SystemExit("DepotDownloader's date is not month first; refusing to name the folder from it")
    return manifest, f"{year}-{month}-{day}"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--manifest", help="a specific manifest of the macOS depot (default: the public one)")
    parser.add_argument("--qr", action="store_true", help="log in by scanning a QR code with the Steam app")
    parser.add_argument("--list", action="store_true", help="print the public manifest and its files only")
    parser.add_argument("--executable-only", action="store_true",
                        help="only the executable and Info.plist (enough for tools/analyze_client.py)")
    args = parser.parse_args()
    binary = downloader()
    common.CLIENTS.mkdir(exist_ok=True)
    base = [str(binary), "-app", str(APP_ID), "-depot", str(MAC_DEPOT), *login(args), "-loginid", "48151"]
    if args.manifest:
        base += ["-manifest", args.manifest]
    if args.list:
        listing = common.CLIENTS / ".listing"
        shutil.rmtree(listing, ignore_errors=True)
        run(base + ["-dir", str(listing), "-manifest-only"])
        for text in listing.glob("manifest_*.txt"):
            print(text.read_text())
        shutil.rmtree(listing, ignore_errors=True)
        return
    tmp = common.CLIENTS / ".download"
    shutil.rmtree(tmp, ignore_errors=True)
    extra: list[str] = []
    if args.executable_only:
        tmp.mkdir()
        files = tmp.parent / ".filelist"
        files.write_text(f"{common.DEPOT_APP / common.BUNDLE_EXECUTABLE}\n{common.DEPOT_APP / 'Contents/Info.plist'}\n")
        extra = ["-filelist", str(files)]
    output = run(base + ["-dir", str(tmp), *extra])
    manifest, date = manifest_of(output)
    executable = tmp / common.DEPOT_APP / common.BUNDLE_EXECUTABLE
    if not executable.is_file():
        raise SystemExit(f"the download holds no {common.DEPOT_APP / common.BUNDLE_EXECUTABLE}")
    dest = common.CLIENTS / f"{date}_{manifest}"
    if dest.exists():
        shutil.rmtree(dest)
    shutil.rmtree(tmp / ".DepotDownloader", ignore_errors=True)
    tmp.rename(dest)
    marker = (f"manifest={manifest}\ndepot={MAC_DEPOT}\nexecutable_sha256={sha256(dest / common.DEPOT_APP / common.BUNDLE_EXECUTABLE)}\n"
              f"executable_only={int(args.executable_only)}\ndownloaded_at={datetime.now(timezone.utc).isoformat(timespec='seconds')}\n")
    (dest / common.COMPLETE).write_text(marker)
    print(f"client: {dest}")


if __name__ == "__main__":
    main()
