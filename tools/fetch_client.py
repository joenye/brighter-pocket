#!/usr/bin/env python3
"""Copy the macOS Brighter Shores client, unchanged, into client/.

usage: tools/fetch_client.py                  # from this Mac's Steam install (the default)
       tools/fetch_client.py --depot [--manifest ID] [--qr] [--executable-only]
       tools/fetch_client.py --depot --list   # the public manifest, nothing downloaded

The macOS depot (2791442 of app 2791440) holds one universal Brighter Shores.app
(x86_64 and arm64). It lands in client/<YYYY-MM-DD>_<manifest>/ laid out as the depot
is, with a .complete marker naming the executable's SHA-256.

By default the copy comes from the Steam app's own install of the game on this Mac
(steamapps/common/Brighter Shores; STEAM_LIBRARY in local.env names another steamapps
folder): its manifest and date are read from Steam's appmanifest_2791440.acf. Install
or update the game in Steam first.

--depot downloads it from Steam's content servers with DepotDownloader instead (never
the game's servers), for a build Steam has not installed (--manifest). It needs a Steam
account that owns the game, STEAM_USER in local.env (DepotDownloader keeps the login
token after the first login; --qr logs in with the Steam app), and DEPOT_DOWNLOADER
naming the DepotDownloader binary.
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
STEAMAPPS = Path.home() / "Library/Application Support/Steam/steamapps"


# --- from the Steam app's install -------------------------------------------------------------
def acf_value(text: str, key: str) -> str:
    found = re.search(rf'"{re.escape(key)}"\s+"([^"]*)"', text)
    if not found:
        raise SystemExit(f"Steam's appmanifest_{APP_ID}.acf has no {key}")
    return found.group(1)


def installed_depot_manifest(text: str) -> str:
    """The manifest of the macOS depot under InstalledDepots (not the private branches' ones)."""
    installed = text[text.find('"InstalledDepots"'):]
    found = re.search(rf'"{MAC_DEPOT}"\s*\{{\s*"manifest"\s+"(\d+)"', installed)
    if '"InstalledDepots"' not in text or not found:
        raise SystemExit(f"Steam has not installed depot {MAC_DEPOT}: install Brighter Shores in Steam")
    return found.group(1)


def from_steam() -> tuple[Path, str, str]:
    """(the installed game's folder, its manifest, the date Steam last updated it)."""
    steamapps = Path(common.setting("STEAM_LIBRARY", str(STEAMAPPS)))
    acf = steamapps / f"appmanifest_{APP_ID}.acf"
    if not acf.is_file():
        raise SystemExit(f"no {acf}: install Brighter Shores in Steam (or set STEAM_LIBRARY, or use --depot)")
    text = acf.read_text()
    if acf_value(text, "StateFlags") != "4":
        raise SystemExit("Steam's install of Brighter Shores is not fully installed or is updating; let Steam finish")
    folder = steamapps / "common" / acf_value(text, "installdir")
    updated = datetime.fromtimestamp(int(acf_value(text, "LastUpdated")), timezone.utc)
    return folder, installed_depot_manifest(text), updated.strftime("%Y-%m-%d")


# --- with DepotDownloader ---------------------------------------------------------------------
def downloader() -> Path:
    named = common.setting("DEPOT_DOWNLOADER")
    if not named or not Path(named).is_file():
        raise SystemExit("--depot needs DEPOT_DOWNLOADER in local.env naming the DepotDownloader binary")
    return Path(named)


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


def download(args: argparse.Namespace, tmp: Path) -> tuple[str, str] | None:
    """DepotDownloader into tmp; (manifest, date), or None when only listing."""
    base = [str(downloader()), "-app", str(APP_ID), "-depot", str(MAC_DEPOT), *login(args), "-loginid", "48151"]
    if args.manifest:
        base += ["-manifest", args.manifest]
    if args.list:
        listing = common.CLIENTS / ".listing"
        shutil.rmtree(listing, ignore_errors=True)
        run(base + ["-dir", str(listing), "-manifest-only"])
        for text in listing.glob("manifest_*.txt"):
            print(text.read_text())
        shutil.rmtree(listing, ignore_errors=True)
        return None
    extra: list[str] = []
    if args.executable_only:
        tmp.mkdir()
        files = tmp.parent / ".filelist"
        files.write_text(f"{common.DEPOT_APP / common.BUNDLE_EXECUTABLE}\n{common.DEPOT_APP / 'Contents/Info.plist'}\n")
        extra = ["-filelist", str(files)]
    manifest, date = manifest_of(run(base + ["-dir", str(tmp), *extra]))
    shutil.rmtree(tmp / ".DepotDownloader", ignore_errors=True)
    return manifest, date


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--depot", action="store_true", help="download with DepotDownloader instead of copying Steam's install")
    parser.add_argument("--manifest", help="with --depot: a specific manifest of the macOS depot (default: the public one)")
    parser.add_argument("--qr", action="store_true", help="with --depot: log in by scanning a QR code with the Steam app")
    parser.add_argument("--list", action="store_true", help="with --depot: print the public manifest and its files only")
    parser.add_argument("--executable-only", action="store_true",
                        help="with --depot: only the executable and Info.plist (enough for tools/analyze_client.py)")
    args = parser.parse_args()
    if not args.depot and (args.manifest or args.qr or args.list or args.executable_only):
        parser.error("--manifest, --qr, --list and --executable-only go with --depot")
    common.CLIENTS.mkdir(exist_ok=True)
    tmp = common.CLIENTS / ".download"
    shutil.rmtree(tmp, ignore_errors=True)
    if args.depot:
        found = download(args, tmp)
        if found is None:
            return
        manifest, date = found
        source = "depotdownloader"
    else:
        folder, manifest, date = from_steam()
        print(f"copying {folder} (manifest {manifest}, updated {date})")
        shutil.copytree(folder, tmp, symlinks=True)
        source = "steam"
    executable = tmp / common.DEPOT_APP / common.BUNDLE_EXECUTABLE
    if not executable.is_file():
        raise SystemExit(f"the copy holds no {common.DEPOT_APP / common.BUNDLE_EXECUTABLE}")
    dest = common.CLIENTS / f"{date}_{manifest}"
    if dest.exists():
        shutil.rmtree(dest)
    tmp.rename(dest)
    marker = (f"manifest={manifest}\ndepot={MAC_DEPOT}\nsource={source}\n"
              f"executable_sha256={sha256(dest / common.DEPOT_APP / common.BUNDLE_EXECUTABLE)}\n"
              f"executable_only={int(args.executable_only)}\ndownloaded_at={datetime.now(timezone.utc).isoformat(timespec='seconds')}\n")
    (dest / common.COMPLETE).write_text(marker)
    print(f"client: {dest}")


if __name__ == "__main__":
    main()
