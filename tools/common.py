"""Paths and settings every tool shares.

Settings come from the environment, then from the repository's ignored local.env
(KEY=value lines, as local.env.example lists them). Nothing personal is committed.
"""
from __future__ import annotations

import os
import shlex
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CLIENTS = ROOT / "client"
BUILD = ROOT / "build"
OUT = ROOT / "out"
# Where the client sits inside a downloaded depot, and inside the app bundle.
DEPOT_APP = Path("x64arm64/Brighter Shores.app")
BUNDLE_EXECUTABLE = Path("Contents/MacOS/Brighter Shores")
STEAM_LIBRARY = Path("Contents/MacOS/libsteam_api.dylib")
COMPLETE = ".complete"


def settings() -> dict[str, str]:
    values: dict[str, str] = {}
    env_file = ROOT / "local.env"
    if env_file.is_file():
        for line in env_file.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            parts = shlex.split(value) if value.strip() else [""]
            values[key.strip()] = parts[0] if parts else ""
    for key, value in os.environ.items():
        values[key] = value
    return values


def setting(key: str, default: str | None = None) -> str | None:
    value = settings().get(key)
    return value if value else default


def downloaded_clients() -> list[Path]:
    """Finished downloads, oldest first (folder names start with the manifest's date)."""
    if not CLIENTS.is_dir():
        return []
    return sorted(p for p in CLIENTS.iterdir() if p.is_dir() and (p / COMPLETE).is_file())


def client_app(client: Path | None = None) -> Path:
    """The Brighter Shores.app of a download: the one named, else the newest."""
    if client is None:
        found = downloaded_clients()
        if not found:
            raise SystemExit("no downloaded client: run tools/fetch_client.py first")
        client = found[-1]
    app = client / DEPOT_APP if (client / DEPOT_APP).is_dir() else client
    if not (app / BUNDLE_EXECUTABLE).is_file():
        raise SystemExit(f"{app} holds no {BUNDLE_EXECUTABLE}")
    return app
