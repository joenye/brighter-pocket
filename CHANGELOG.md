# Changelog

What changed in each release of Brighter Pocket: the app on your iPhone or iPad and Brighter
Pocket Companion, the macOS app that sets it up and renews it (one version for both, `VERSION`).
This is the one source of the release notes: the companion shows its version's section after it
updates itself, each GitHub release's notes and appcast entry are its section, and
[brighteratlas.com's What's New](https://brighteratlas.com/whats-new?for=pocket) is generated
from it (brighter-atlas `scripts/pocket/notes.ts`). So each section is written as those notes are:
a headline of a few words (at most 48 characters) under the heading, then one line a change (at
most 200 characters), for players, with no dashes, emoji or exclamation marks.
`tools/check_changelog.py` checks it. The format is
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.9.0] - 2026-11-14

Play Brighter Shores natively on iOS

### Added

- The game's own macOS version on your iPhone or iPad, unmodified, signed in to Steam.
- Tap or cursor, pinch to zoom, up to 120 fps on ProMotion screens.
- Game updates download on the phone.
- Set up and renewed from a macOS device with the free Brighter Pocket Companion.
