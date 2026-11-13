# Releasing Brighter Pocket Companion

The companion is the Mac app players download (README.md, "Set up"). A release is built on
GitHub, from the tagged commit, by `.github/workflows/release.yml`: nothing is built or signed
on a personal Mac. The approach follows Slashplayed's companion, made simpler: no Pages site
(the appcast is a release asset) and one download.

## What a release is

On a `v*` tag, with no one to approve it (Joe, 2026-11-13: it runs by itself):

1. `tools/release/release.sh` builds the companion from the tag (`tools/make_companion.sh`),
   signs Sparkle's parts and the app with the project's Developer ID and the hardened runtime,
   notarizes and staples the app, puts it in `Brighter-Pocket-Companion.dmg`, signs, notarizes
   and staples that, and signs it for Sparkle with the EdDSA key.
2. It writes `appcast.xml` (the one item, this version's CHANGELOG.md section as its notes),
   `notes.md` and `SHA256SUMS`.
3. The workflow attests the DMG's build provenance (`actions/attest-build-provenance`): a
   signed statement, kept by GitHub, that this file was built by this workflow from this
   commit.
4. It creates the GitHub release with the DMG, `appcast.xml` and `SHA256SUMS`.

The DMG's name never changes, so `releases/latest/download/Brighter-Pocket-Companion.dmg` is
always the newest (the site links there), and every installed companion reads
`releases/latest/download/appcast.xml`: publishing the release is what offers the update.

## Making one

1. Set the version in `VERSION` (x.y.z).
2. In `CHANGELOG.md`, move what is under `## [Unreleased]` into `## [x.y.z] - YYYY-MM-DD`
   with today's date. Write it for players: what changed and where. The companion shows this
   section after it updates, and Sparkle shows it in the update prompt.
3. Try it: `tools/release/release.sh --unsigned` (the same steps, ad hoc, no notarization or
   Sparkle signature) writes `build/release/`.
4. Commit, then tag and push the tag: `git tag -s vx.y.z -m "Brighter Pocket Companion x.y.z"`,
   `git push origin vx.y.z`.
5. Nothing else: the run starts by itself. It checks the tag is `v` + `VERSION`, that the
   CHANGELOG section is dated, and that no release of that tag exists yet; to run again, delete
   the release first.

## Setting it up once

### The `release` environment

Settings > Environments > New environment, `release`, with deployment limited to tags matching
`v*` (no required reviewer: a tag releases at once, and only Joe pushes to this repository).
Its secrets:

|Secret|What|
|---|---|
|`DEVELOPER_ID_P12_BASE64`|The Developer ID Application certificate and its key, exported from Keychain Access as .p12, then `base64 -i cert.p12 \| pbcopy`|
|`DEVELOPER_ID_P12_PASSWORD`|The .p12's password|
|`ASC_API_KEY_P8_BASE64`|An App Store Connect API key for notarization (Users and Access > Integrations > Team Keys, role Developer), `base64 -i AuthKey_XXXX.p8`|
|`ASC_API_KEY_ID`|That key's ID|
|`ASC_API_ISSUER_ID`|The issuer ID shown above the keys|
|`SPARKLE_ED_PRIVATE_KEY`|Sparkle's EdDSA private key (below)|

The Developer ID certificate needs the paid Apple Developer Program (Certificates, IDs &
Profiles > Certificates > Developer ID Application). Players' own builds of Brighter Pocket
never use it: the companion builds the iOS app with each player's own Apple Account.

### Keys

Sparkle's tools come with the package: after one `tools/make_companion.sh`, they are in
`build/companion/derived/SourcePackages/artifacts/sparkle/Sparkle/bin/`.

1. `generate_keys --account brighter-pocket` creates a key pair in your login keychain, under
   its own name (so it never meets another project's key), and prints the public key. Done
   once, 2026-11-13: the key is in Joe's login keychain, its public half committed, its private
   half the `release` environment's secret.
2. Put the public key in `tools/release/sparkle-public-key.txt` (under its comments) and
   commit it: every build from then on checks updates against it.
3. `generate_keys --account brighter-pocket -x private-key.txt` exports the private key; paste its contents into the
   `SPARKLE_ED_PRIVATE_KEY` secret and delete the file. Keep the keychain copy as the backup:
   a lost key means installed companions can never be updated again, only replaced by hand.

The release script refuses to run when the private key is not the public key's other half.

## How a player can check a download

- **Built here, from this source.** `gh attestation verify Brighter-Pocket-Companion.dmg -R
  joenye/brighter-pocket` checks GitHub's provenance statement: it names the workflow, the
  tag and the commit the DMG was built from.
- **Unchanged since.** `shasum -a 256 Brighter-Pocket-Companion.dmg` matches the release's
  `SHA256SUMS`; macOS checks the Developer ID signature and Apple's notarization on opening.
- **Or no download at all.** Build the companion from a checkout (`tools/make_companion.sh`),
  after reading or having anything review the code.

Whichever companion they use, it builds Brighter Pocket itself from the source it carries
(the prepared tree, in the app's Resources as `Tolkara-source.tar.gz`), on their own Mac,
with their own Apple Account: the app on their phone is always their own build. Settings >
Advanced can point it at a checkout instead.

## Updates in the companion

Sparkle 2 (pinned in pocket/patches/0034) checks the appcast on its schedule and asks before
installing; Settings turns the automatic checks off, and the app menu has Check for Updates.
A build without a public key (any local build until the key is committed, and forks) has
updates off and says so in the menu and Settings. After an update, the companion shows the
new version's CHANGELOG section once; Help > What's New shows it again.
