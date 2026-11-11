#!/usr/bin/env python3
"""Copy your own Brighter Shores (macOS, Steam) into the app's Documents on the device.

usage: install.py --source FOLDER --device UDID [--via devicectl|pymobiledevice3] [--stage-only DIR]

FOLDER holds Brighter Shores.app: Steam's install folder on a Mac
(~/Library/Application Support/Steam/steamapps/common/Brighter Shores), or a download
made by tools/fetch_client.py (its x64arm64 folder). The bundle is staged unchanged as
Documents/Brighter Shores/Brighter Shores.app, without Valve's libsteam_api.dylib: the
app's own offline Steam library answers for it, and a copy beside the executable would
be loaded instead. The executable's SHA-256 is checked before and after staging.

The copy goes over USB with devicectl on a Mac (Xcode), or with pymobiledevice3 on
Linux or Windows (pip install pymobiledevice3; the app shares its Documents folder).
The Files app works too: copy the staged "Brighter Shores" folder into the app's folder.
The bundle ID is TOLKARA_BUNDLE_ID from local.env, as for the platform's own helpers.
"""
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

FOLDER = 'Brighter Shores'
APP = 'Brighter Shores.app'
EXECUTABLE = Path('Contents/MacOS/Brighter Shores')
# Valve's library: needs a Steam client, which the device has none of.
LEFT_OUT = {Path('Contents/MacOS/libsteam_api.dylib')}
ASSET_BUNDLES = [Path(f'Contents/Resources/assetBundle{i}') for i in range(9)]


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            digest.update(chunk)
    return digest.hexdigest()


def stage(app, out):
    """<out>/Brighter Shores/Brighter Shores.app: the bundle unchanged, Valve's library left out.
    Returns the record also written to <out>/Brighter Shores/stage.json."""
    app, out = Path(app), Path(out)
    executable = app / EXECUTABLE
    if not executable.is_file():
        raise SystemExit(f'no {APP} executable at {executable}')
    missing = [str(p) for p in ASSET_BUNDLES if not (app / p).is_file()]
    if missing:
        raise SystemExit('the client is incomplete: ' + ', '.join(missing))
    before = sha256(executable)
    dest = out / FOLDER / APP
    if dest.exists():
        shutil.rmtree(dest)
    files = []
    for source in sorted(p for p in app.rglob('*') if p.is_file()):
        relative = source.relative_to(app)
        if relative in LEFT_OUT:
            continue
        target = dest / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        files.append({'path': str(relative), 'size': target.stat().st_size})
    if not before == sha256(executable) == sha256(dest / EXECUTABLE):
        raise SystemExit('the executable changed while it was staged')
    record = {'executable': str(EXECUTABLE), 'executable_sha256': before,
              'left_out': sorted(str(p) for p in LEFT_OUT), 'files': files}
    (out / FOLDER / 'stage.json').write_text(json.dumps(record, indent=1) + '\n')
    return record


def bundle_id():
    """TOLKARA_BUNDLE_ID from the environment or the repository's local.env, as tools/localenv.py reads it."""
    if os.environ.get('TOLKARA_BUNDLE_ID'):
        return os.environ['TOLKARA_BUNDLE_ID']
    for parent in Path(__file__).resolve().parents:
        env = parent / 'local.env'
        if env.is_file():
            for line in env.read_text().splitlines():
                key, _, value = line.strip().removeprefix('export ').partition('=')
                if key.strip() == 'TOLKARA_BUNDLE_ID' and value.strip():
                    return value.strip().strip('"\'')
    return 'local.tolkara.app'


def transfer(folder, device, via):
    """Copy the staged folder to Documents/Brighter Shores in the app's data container."""
    if via == 'devicectl':
        subprocess.run(['xcrun', 'devicectl', 'device', 'copy', 'to', '--device', device,
                        '--domain-type', 'appDataContainer', '--domain-identifier', bundle_id(),
                        '--source', str(folder), '--destination', f'Documents/{FOLDER}'], check=True)
    else:
        # The app shares its Documents folder (UIFileSharingEnabled): pymobiledevice3's
        # house-arrest client writes into it as the Files app would.
        subprocess.run([sys.executable, '-m', 'pymobiledevice3', 'apps', 'push', '--udid', device,
                        '--documents', bundle_id(), str(folder), FOLDER], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--source', type=Path, required=True, help=f'the folder holding {APP}')
    parser.add_argument('--device', help='the device UDID (default: DEVICE in local.env)')
    parser.add_argument('--via', choices=['devicectl', 'pymobiledevice3'],
                        default='devicectl' if sys.platform == 'darwin' else 'pymobiledevice3')
    parser.add_argument('--stage-only', type=Path, metavar='DIR', help='stage into DIR and copy nothing')
    args = parser.parse_args()
    if args.stage_only:
        record = stage(args.source / APP, args.stage_only)
        print(f"staged in {args.stage_only / FOLDER}; executable sha256 {record['executable_sha256']}")
        return
    device = args.device or os.environ.get('DEVICE')
    if not device:
        parser.error('pass --device or set DEVICE')
    with tempfile.TemporaryDirectory() as tmp:
        record = stage(args.source / APP, tmp)
        transfer(Path(tmp) / FOLDER, device, args.via)
    print(f"copied Brighter Shores to the device; executable sha256 {record['executable_sha256']}")


if __name__ == '__main__':
    main()
