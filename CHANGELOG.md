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

## [0.9.5] - 2026-11-19

Smoother first install

- A first install now starts the game by itself, and settings get Check for Updates for the game and Pocket and an exact cursor speed.

## [0.9.4] - 2026-11-19

Another device closing the game

- The "running on another device" warning clears as soon as that game closes.

## [0.9.3] - 2026-11-19

New version alerts

- Pocket tells you when a new version is out.

## [0.9.2] - 2026-11-19

Playing on more than one device

- Better Steam session handling when you're signed in on more than one device.

## [0.9.1] - 2026-11-15

A fix for free Apple Developer Accounts

### Fixed

- Fixed the game stopping while it starts with a free Apple Developer Account.

## [0.9.0] - 2026-11-14

Play Brighter Shores natively on iOS

### Added

- The game's own macOS version on your iPhone or iPad, unmodified, signed in to Steam.
- Game updates download on the phone.
- Easy setup from Brighter Pocket Companion.
