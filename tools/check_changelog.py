#!/usr/bin/env python3
"""Checks CHANGELOG.md is in the form Brighter Pocket's release notes are read in everywhere.

CHANGELOG.md is the one source of Brighter Pocket's release notes (Joe, 2026-11-14: the site's
What's New and this repository stay in step, structurally): the companion's What's New shows it,
each GitHub release's notes and its appcast entry are its section, and brighteratlas.com's What's
New is generated from it (brighter-atlas: scripts/pocket/notes.ts, whose deploy refuses notes out
of step). So each released section must read as the site's notes do (brighter-atlas
webapp/src/whats-new/notes.ts, "HOW TO WRITE THEM"):

  ## [0.9.0] - 2026-11-14

  Play Brighter Shores natively on iOS        <- the headline: a few words, at most 48 characters

  ### Added

  - One line a change, at most 200 characters (wrapped lines are joined first).

No em or en dashes, no emoji, no exclamation marks, no filler words. Used by tests/run.sh and
tools/release/release.sh.

  python3 tools/check_changelog.py [CHANGELOG.md]
"""
import re
import sys
from pathlib import Path

TITLE, LINE = 48, 200
# (as brighter-atlas webapp/src/whats-new/notes.ts FLUFF)
FLUFF = re.compile(r"\b(finally|exciting|excited|awesome|amazing|brand[- ]new|beautiful|stunning|incredible|lots of"
                   r"|we're|we've|we have|enjoy)\b", re.I)
EMOJI = re.compile("[\U0001F300-\U0001FAFF☀-➿]")
SECTION = re.compile(r"^## \[(?P<version>[^\]]+)\](?: - (?P<date>\d{4}-\d{2}-\d{2}))?\s*$")


def sections(text: str):
    """(version, date, lines) for each "## [..]" section, in order."""
    out, current = [], None
    for line in text.splitlines():
        m = SECTION.match(line)
        if m:
            current = (m["version"], m["date"], [])
            out.append(current)
        elif line.startswith("## ") or re.match(r"^\[[^\]]+\]: ", line):
            current = None
        elif current:
            current[2].append(line)
    return out


def parse(lines):
    """A section's headline (its first paragraph) and its bullets, each joined onto one line."""
    headline, bullets, item = None, [], None
    for line in lines:
        if line.startswith("- "):
            item = [line[2:].strip()]
            bullets.append(item)
        elif item is not None and line.startswith("  ") and line.strip():
            item.append(line.strip())
        else:
            item = None
            if headline is None and line.strip() and not line.startswith("#"):
                headline = line.strip()
    return headline, [" ".join(b) for b in bullets]


def problems(text: str):
    out = []
    for version, date, lines in sections(text):
        if version == "Unreleased":
            continue
        where = f"[{version}]"
        if not date:
            out.append(f"{where}: no date (## [{version}] - YYYY-MM-DD)")
        headline, bullets = parse(lines)
        if not headline:
            out.append(f"{where}: no headline (a line of a few words under the heading)")
        elif len(headline) > TITLE:
            out.append(f"{where}: headline over {TITLE} characters: {headline!r}")
        if not bullets:
            out.append(f"{where}: no bullets")
        for t in ([headline] if headline else []) + bullets:
            if len(t) > LINE and t is not headline:
                out.append(f"{where}: a bullet over {LINE} characters: {t[:70]!r}...")
            if "—" in t or "–" in t:
                out.append(f"{where}: an em or en dash: {t[:70]!r}")
            if "!" in t:
                out.append(f"{where}: an exclamation mark: {t[:70]!r}")
            if EMOJI.search(t):
                out.append(f"{where}: an emoji: {t[:70]!r}")
            if FLUFF.search(t):
                out.append(f"{where}: filler ({FLUFF.search(t)[0]}): {t[:70]!r}")
    return out


def main() -> None:
    path = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).resolve().parents[1] / "CHANGELOG.md")
    found = problems(path.read_text())
    if found:
        sys.exit(f"{path.name} is not in the release notes' form:\n  " + "\n  ".join(found))
    print(f"{path.name}: every release reads as the notes should")


if __name__ == "__main__":
    main()
