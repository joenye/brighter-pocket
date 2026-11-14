#!/bin/bash
# Build a Brighter Pocket Companion release: the app, signed and notarized, in a disk image,
# with its Sparkle signature, the appcast that offers it, its notes and checksums
# (docs/releasing.md). .github/workflows/release.yml runs it on a v* tag; it also runs on a
# Mac with --unsigned (ad hoc, no notarization, no Sparkle signature) to try the steps.
#
# usage: tools/release/release.sh [--unsigned]
#
# Writes build/release/:
#   Brighter-Pocket-Companion.dmg   the app; its name stays the same in every release, so
#                                   releases/latest/download/Brighter-Pocket-Companion.dmg is
#                                   always the newest
#   appcast.xml                     Sparkle's feed: this release, its notes as HTML, the DMG's
#                                   EdDSA signature (the app reads releases/latest/download/appcast.xml)
#   notes.md                        this version's CHANGELOG.md section (the GitHub release notes)
#   SHA256SUMS                      the DMG's checksum
#
# The version is VERSION; RELEASE_TAG, when set (the workflow's tag), must be v<VERSION>, and
# CHANGELOG.md must have a dated "## [<VERSION>]" section. Signed, it needs:
#   COMPANION_SIGN_IDENTITY   optional: the "Developer ID Application: ..." identity (else the
#                             one such identity in the keychain search list)
#   ASC_API_KEY_PATH, ASC_API_KEY_ID, ASC_API_ISSUER_ID
#                             an App Store Connect API key (.p8 path, key ID, issuer ID), for
#                             notarytool
#   SPARKLE_ED_PRIVATE_KEY    Sparkle's EdDSA private key (generate_keys -x writes it), whose
#                             public half must be tools/release/sparkle-public-key.txt
set -euo pipefail
cd "$(dirname "$0")/../.."
SIGNED=yes
case "${1:-}" in --unsigned) SIGNED=no ;; "") ;; *) echo "usage: tools/release/release.sh [--unsigned]" >&2; exit 2 ;; esac
VERSION=$(tr -d '[:space:]' < VERSION)
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: VERSION '$VERSION' is not x.y.z" >&2; exit 1; }
if [[ -n "${RELEASE_TAG:-}" && "$RELEASE_TAG" != "v$VERSION" ]]; then
    echo "error: the tag $RELEASE_TAG is not v$VERSION (VERSION)" >&2; exit 1
fi
OUT=build/release
DMG_NAME=Brighter-Pocket-Companion.dmg
APP_NAME="Brighter Pocket Companion.app"
REPO=https://github.com/joenye/brighter-pocket
MIN_OS=14.0
rm -rf "$OUT"; mkdir -p "$OUT"

# --- Notes: this version's section of CHANGELOG.md ------------------------------------------
# (in the form every reader of it takes: the companion, GitHub, brighteratlas.com's What's New)
python3 tools/check_changelog.py CHANGELOG.md
HEADING=$(grep -m1 -F "## [$VERSION]" CHANGELOG.md || true)
[[ -n "$HEADING" ]] || { echo "error: CHANGELOG.md has no \"## [$VERSION]\" section" >&2; exit 1; }
if [[ ! "$HEADING" =~ ^"## [$VERSION] - "[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    if [[ "$SIGNED" == yes ]]; then echo "error: '$HEADING' has no release date (YYYY-MM-DD)" >&2; exit 1; fi
    echo "warning: '$HEADING' has no release date yet" >&2
fi
awk -v h="$HEADING" '$0 == h { on = 1; next } on && /^## \[/ { exit } on && /^\[[^]]+\]: / { next } on { print }' CHANGELOG.md \
    | sed -e '/./,$!d' | sed -e ':a' -e '/^\n*$/{$d;N;ba' -e '}' > "$OUT/notes.md"
[[ -s "$OUT/notes.md" ]] || { echo "error: the \"## [$VERSION]\" section of CHANGELOG.md is empty" >&2; exit 1; }

# --- Credentials, checked before an hour of building ----------------------------------------
PUBLIC_KEY=$(grep -v '^#' tools/release/sparkle-public-key.txt 2>/dev/null | tr -d '[:space:]' || true)
if [[ "$SIGNED" == yes ]]; then
    SIGN_ID=${COMPANION_SIGN_IDENTITY:-}
    if [[ -z "$SIGN_ID" ]]; then
        IDS=$(security find-identity -v -p codesigning | sed -nE 's/^ *[0-9]+\) [0-9A-F]{40} "(Developer ID Application: .*)"$/\1/p' | sort -u)
        case "$(grep -c . <<< "$IDS" || true)" in
            1) SIGN_ID=$IDS ;;
            0) echo "error: no \"Developer ID Application\" identity in the keychain (or pass --unsigned)" >&2; exit 1 ;;
            *) echo "error: several Developer ID identities; set COMPANION_SIGN_IDENTITY to one" >&2; exit 1 ;;
        esac
    fi
    for name in ASC_API_KEY_PATH ASC_API_KEY_ID ASC_API_ISSUER_ID SPARKLE_ED_PRIVATE_KEY; do
        [[ -n "${!name:-}" ]] || { echo "error: $name is not set (docs/releasing.md)" >&2; exit 1; }
    done
    [[ -f "$ASC_API_KEY_PATH" ]] || { echo "error: ASC_API_KEY_PATH names no file" >&2; exit 1; }
    NOTARY=(--key "$ASC_API_KEY_PATH" --key-id "$ASC_API_KEY_ID" --issuer "$ASC_API_ISSUER_ID")
    xcrun notarytool history "${NOTARY[@]}" --output-format json > /dev/null \
        || { echo "error: notarytool cannot sign in with this App Store Connect key" >&2; exit 1; }
    [[ -n "$PUBLIC_KEY" ]] || { echo "error: tools/release/sparkle-public-key.txt has no key (docs/releasing.md)" >&2; exit 1; }
    # The private key must be the public key's other half, or every installed copy refuses the
    # update. Sparkle's private key is the base64 of a 32-byte Ed25519 seed; the key goes in on
    # standard input, never on a command line.
    DERIVE=$(mktemp -d "${TMPDIR:-/tmp}/pocket-derive.XXXXXX")
    cat > "$DERIVE/derive.swift" <<'SWIFT'
import CryptoKit
import Foundation
let text = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
guard let seed = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else { exit(1) }
print(key.publicKey.rawRepresentation.base64EncodedString())
SWIFT
    DERIVED=$(printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | xcrun swift "$DERIVE/derive.swift" 2> /dev/null || true)
    rm -rf "$DERIVE"
    [[ "$DERIVED" == "$PUBLIC_KEY" ]] \
        || { echo "error: SPARKLE_ED_PRIVATE_KEY is not the private half of tools/release/sparkle-public-key.txt" >&2; exit 1; }
    echo "Signing as: $SIGN_ID"
fi

# --- Build -----------------------------------------------------------------------------------
# The build number is the time: Sparkle compares it, so each release is newer than the last.
BUILD=$(date +%s)
COMPANION_BUILD=$BUILD POCKET_SPARKLE_PUBLIC_KEY=$PUBLIC_KEY COMPANION_SIGN_IDENTITY=${SIGN_ID:-} tools/make_companion.sh
APP="build/$APP_NAME"
SPARKLE_BIN=build/companion/derived/SourcePackages/artifacts/sparkle/Sparkle/bin
[[ -x "$SPARKLE_BIN/sign_update" ]] || { echo "error: no sign_update in $SPARKLE_BIN (Sparkle's layout changed?)" >&2; exit 1; }

notarize() {
    local file=$1 result id status
    echo "Notarizing $(basename "$file")..."
    result=$(xcrun notarytool submit "$file" "${NOTARY[@]}" --wait --output-format json) || true
    id=$(plutil -extract id raw -o - - <<< "$result" 2> /dev/null || true)
    status=$(plutil -extract status raw -o - - <<< "$result" 2> /dev/null || true)
    if [[ "$status" != Accepted ]]; then
        echo "error: notarization of $(basename "$file") ended '${status:-unknown}'" >&2
        echo "$result" >&2
        [[ -z "$id" ]] || xcrun notarytool log "$id" "${NOTARY[@]}" >&2 || true
        return 1
    fi
}
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/pocket-release.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/$APP_NAME"
if [[ "$SIGNED" == yes ]]; then
    # The app first, so the copy a user drags to Applications carries its ticket and opens offline.
    ditto -c -k --sequesterRsrc --keepParent "$STAGE/$APP_NAME" "$STAGE/app.zip"
    notarize "$STAGE/app.zip"
    rm -f "$STAGE/app.zip"
    xcrun stapler staple "$STAGE/$APP_NAME"
    xcrun stapler validate "$STAGE/$APP_NAME"
fi

# --- Disk image -----------------------------------------------------------------------------
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Brighter Pocket Companion" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$OUT/$DMG_NAME" > /dev/null
MOUNT=$(mktemp -d "${TMPDIR:-/tmp}/pocket-dmg.XXXXXX")
hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$MOUNT" "$OUT/$DMG_NAME" > /dev/null
[[ -d "$MOUNT/$APP_NAME" && -L "$MOUNT/Applications" ]] || { hdiutil detach "$MOUNT" -quiet; echo "error: the image lacks the app or the Applications link" >&2; exit 1; }
codesign --verify --deep --strict "$MOUNT/$APP_NAME" || { hdiutil detach "$MOUNT" -quiet; exit 1; }
hdiutil detach "$MOUNT" -quiet
rmdir "$MOUNT" 2> /dev/null || true
if [[ "$SIGNED" == yes ]]; then
    codesign --sign "$SIGN_ID" --timestamp "$OUT/$DMG_NAME"
    notarize "$OUT/$DMG_NAME"
    xcrun stapler staple "$OUT/$DMG_NAME"
    xcrun stapler validate "$OUT/$DMG_NAME"
    # Stapling rewrites the image, so Sparkle's signature comes last.
    ED_SIGNATURE=$(printf '%s\n' "$SPARKLE_ED_PRIVATE_KEY" | "$SPARKLE_BIN/sign_update" --ed-key-file - -p "$OUT/$DMG_NAME")
    [[ -n "$ED_SIGNATURE" ]] || { echo "error: sign_update gave no signature" >&2; exit 1; }
fi

# --- The appcast: this release, its notes as HTML ------------------------------------------
# Only the Markdown CHANGELOG.md uses: ### headings, "- " bullets (continued on indented lines),
# paragraphs, `code`, **bold** and [links](url). Text is escaped before markup goes in, which
# also keeps "]]>" from ending the CDATA early.
notes_html() {
    perl -e '
        use strict; use warnings;
        sub esc { my $s = shift; $s =~ s/&/&amp;/g; $s =~ s/</&lt;/g; $s =~ s/>/&gt;/g; $s }
        sub inline {
            my @p = split /`/, shift, -1;
            for my $i (0 .. $#p) {
                if ($i % 2) { $p[$i] = "<code>" . esc($p[$i]) . "</code>"; next }
                my $t = esc($p[$i]);
                $t =~ s{\[([^\]]+)\]\(([^)\s]+)\)}{<a href="$2">$1</a>}g;
                $t =~ s{\*\*(.+?)\*\*}{<strong>$1</strong>}g;
                $p[$i] = $t;
            }
            join "", @p;
        }
        my (@out, @para, @items);
        sub flush {
            push @out, "<p>" . inline(join " ", @para) . "</p>" if @para;
            push @out, "<ul>" . join("", map { "<li>" . inline($_) . "</li>" } @items) . "</ul>" if @items;
            @para = (); @items = ();
        }
        while (my $line = <>) {
            chomp $line;
            if ($line =~ /^\s*$/) { flush(); next }
            if ($line =~ /^(#{1,6})\s+(.*?)\s*$/) { flush(); my $n = length $1; push @out, "<h$n>" . inline($2) . "</h$n>"; next }
            if ($line =~ /^-\s+(.*)$/) { push @out, "<p>" . inline(join " ", @para) . "</p>" if @para; @para = (); push @items, $1; next }
            if (@items && $line =~ /^\s+(\S.*)$/) { $items[-1] .= " $1"; next }
            flush() if @items;
            (my $t = $line) =~ s/^\s+//;
            push @para, $t;
        }
        flush();
        print join("\n", @out), "\n";
    ' "$1"
}
if [[ "$SIGNED" == yes ]]; then
    SIGNATURE=" sparkle:edSignature=\"$ED_SIGNATURE\""
    NOTE=""
else
    SIGNATURE=""
    NOTE=$'\n      <!-- An unsigned trial build: no sparkle:edSignature, so Sparkle would refuse this item. -->'
fi
{
    cat <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Brighter Pocket Companion</title>
    <link>$REPO</link>
    <description>Brighter Pocket Companion's releases</description>
    <language>en</language>
    <item>
      <title>Version $VERSION</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <description><![CDATA[
XML
    notes_html "$OUT/notes.md"
    cat <<XML
      ]]></description>$NOTE
      <enclosure url="$REPO/releases/download/v$VERSION/$DMG_NAME" length="$(stat -f %z "$OUT/$DMG_NAME")" type="application/octet-stream"$SIGNATURE/>
    </item>
  </channel>
</rss>
XML
} > "$OUT/appcast.xml"
xmllint --noout "$OUT/appcast.xml"
(cd "$OUT" && shasum -a 256 "$DMG_NAME" > SHA256SUMS)

echo
if [[ "$SIGNED" == yes ]]; then
    echo "Release $VERSION ($BUILD): signed, notarized, stapled and signed for Sparkle."
else
    echo "Unsigned trial of $VERSION ($BUILD): no Developer ID, notarization or Sparkle signature."
fi
echo "In $OUT: $DMG_NAME appcast.xml notes.md SHA256SUMS"
