#!/usr/bin/env python3
"""By hand: build tests/steam_sessions_live.m for the Mac and run it against Steam as STEAM_USER, with the
refresh token DepotDownloader remembers (passed in the environment, never printed). One run is one of the
account's sessions; run two at once to see what Steam does when both play.

usage: .venv/bin/python tests/steam_sessions_live.py [--play] [--take-over] [--ticket ID] [--seconds N] [--name NAME]
"""
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import common  # noqa: E402
from run_simulator import saved_refresh_token  # noqa: E402

POCKET = ROOT / "pocket/launcher/Pocket"


def main() -> int:
    account = common.setting("STEAM_USER")
    if not account:
        raise SystemExit("set STEAM_USER in local.env")
    out = ROOT / "build/tests/steam_sessions_live"
    out.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["xcrun", "clang", "-fobjc-arc", "-O1", "-g", "-Wall", "-Wextra", "-Werror", f"-I{POCKET}",
                    str(ROOT / "tests/steam_sessions_live.m"), str(POCKET / "PocketSteamClient.m"), str(POCKET / "PocketSteam.c"),
                    "-framework", "Foundation", "-lz", "-o", str(out)],
                   check=True, env=common.xcode_env())
    environment = dict(os.environ, POCKET_STEAM_ACCOUNT=account, POCKET_STEAM_REFRESH_TOKEN=saved_refresh_token(account))
    return subprocess.run([str(out), *sys.argv[1:]], env=environment).returncode


if __name__ == "__main__":
    sys.exit(main())
