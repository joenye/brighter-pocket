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

- Play Brighter Shores on your iPhone or iPad: the game's own macOS version, unmodified, signed
  in to Steam on the phone.
- Tap to click, or move a cursor like a trackpad; pinch to zoom; up to 120 fps on ProMotion
  screens.
- Game updates download on the phone itself, straight from Steam.
- Brighter Pocket Companion, a free macOS app, checks what you need, builds Pocket with your
  Apple Account, installs it on your phone and copies your game over.
- With a free Apple Account, Renew Pocket in the companion once a week; a paid Apple Developer
  Program membership makes it once a year.
- The companion updates itself: Check for Updates is in its app menu, and What's New in its
  Help menu.
- Free and open source: github.com/joenye/brighter-pocket
