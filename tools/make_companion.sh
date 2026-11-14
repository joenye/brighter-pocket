#!/bin/bash
# Build Brighter Pocket Companion, the Mac app that sets everything up (README.md, "Set up").
#
# usage: tools/make_companion.sh [--dmg]
#
# It is Tolkara Management (platform/management) built from the prepared tree, so it carries
# Brighter Pocket's source (Tolkara with the layer's patches and files, build/companion/platform)
# and builds that on the user's Mac with their own team; pocket/patches/0020, 0021, 0023 and
# 0034 make it Brighter Pocket's (Local signing by default, its own updates). Writes
# build/Brighter Pocket Companion.app and, with --dmg, a disk image to try,
# build/Brighter Pocket Companion.dmg (a release's is tools/release/release.sh's). Needs Xcode
# (DEVELOPER_DIR in local.env when xcode-select names another) and XcodeGen (brew install
# xcodegen); the first build fetches Sparkle, pinned, through Swift Package Manager.
#
# Version: VERSION (TOLKARA_VERSION overrides), build number COMPANION_BUILD (default 1; a
# release's is the time, so each is newer than the last to Sparkle).
# Updates: the Sparkle public key, POCKET_SPARKLE_PUBLIC_KEY or else
# tools/release/sparkle-public-key.txt; without one the app's updates are off.
# Signing, optional: COMPANION_SIGN_IDENTITY ("Developer ID Application: ...") signs Sparkle's
# parts and then the app with the hardened runtime and a secure timestamp, as notarization
# needs; otherwise ad hoc, without the runtime (library validation would refuse Sparkle's
# framework without a team), and macOS asks the user to allow the app once in System
# Settings > Privacy & Security.
set -euo pipefail
cd "$(dirname "$0")/.."
DMG=
case "${1:-}" in --dmg) DMG=1 ;; "") ;; *) echo "usage: tools/make_companion.sh [--dmg]"; exit 2 ;; esac
NAME="Brighter Pocket Companion"
TREE=build/companion/platform
setting() { python3 -c "import sys; sys.path.insert(0, 'tools'); import common; print(common.setting('$1') or '')"; }
DEVELOPER_DIR=${DEVELOPER_DIR:-$(setting DEVELOPER_DIR)}
export DEVELOPER_DIR=${DEVELOPER_DIR:-$(xcode-select -p)}
command -v xcodegen > /dev/null || { echo "XcodeGen is needed: brew install xcodegen"; exit 1; }
export TOLKARA_VERSION=${TOLKARA_VERSION:-$(tr -d '[:space:]' < VERSION)}
# (the app it builds says its version too, pocket/layer.env TOLKARA_APP_VERSION: the same, or no build)
APP_VERSION=$(setting TOLKARA_APP_VERSION)
[ "$APP_VERSION" = "$(tr -d '[:space:]' < VERSION)" ] || { echo "pocket/layer.env TOLKARA_APP_VERSION is '$APP_VERSION' but VERSION is '$(tr -d '[:space:]' < VERSION)': change both"; exit 1; }
BUILD_NUMBER=${COMPANION_BUILD:-1}
KEY=${POCKET_SPARKLE_PUBLIC_KEY:-}
if [ -z "$KEY" ] && [ -f tools/release/sparkle-public-key.txt ]; then
    KEY=$(grep -v '^#' tools/release/sparkle-public-key.txt | tr -d '[:space:]' || true)
fi

python3 tools/prepare.py --out "$TREE"
rm -f "$TREE/local.env"   # personal settings: never in the app
mkdir -p build/companion
LOG=build/companion/build.log
xcodegen generate -q --spec "$TREE/management/project.yml"
xcodebuild -project "$TREE/management/TolkaraManagement.xcodeproj" -scheme TolkaraManagement -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath build/companion/derived ONLY_ACTIVE_ARCH=NO \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" POCKET_SPARKLE_PUBLIC_KEY="$KEY" build > "$LOG" 2>&1 \
    || { grep -E "error:" "$LOG" | head -20; echo "BUILD FAILED -> $LOG"; exit 1; }
BUILT="build/companion/derived/Build/Products/Release/$NAME.app"
[ -d "$BUILT" ] || { echo "the build made no $BUILT -> $LOG"; exit 1; }

# What goes out: the prepared tree's own files, never personal or built ones, and the game's profile.
SOURCE="$BUILT/Contents/Resources/Tolkara-source.tar.gz"
[ -f "$SOURCE" ] || { echo "refusing: the app carries no source"; exit 1; }
LISTING=$(tar -tzf "$SOURCE")
if grep -E '(^|/)(local\.env|build|logs)(/|$)|\.(mobileprovision|p12|p8|ipa|dylib)$' <<< "$LISTING" | grep -q .; then
    echo "refusing: the source in the app carries personal or built files"; exit 1
fi
for file in layer.env profiles/brighter-shores/profile.json profiles/brighter-shores/install.py launcher/Pocket/PocketSteam.c; do
    grep -qxF "$file" <<< "$LISTING" || { echo "refusing: the source in the app has no $file"; exit 1; }
done
[ -f "$BUILT/Contents/Resources/CHANGELOG.md" ] || { echo "refusing: the app carries no release notes"; exit 1; }
plist() { /usr/libexec/PlistBuddy -c "Print $1" "$BUILT/Contents/Info.plist" 2>/dev/null || true; }
GOT="$(plist CFBundleShortVersionString) $(plist CFBundleVersion)"
[ "$GOT" = "$TOLKARA_VERSION $BUILD_NUMBER" ] || { echo "the app is version '$GOT', expected '$TOLKARA_VERSION $BUILD_NUMBER'"; exit 1; }
[ "$(plist SUPublicEDKey)" = "$KEY" ] || { echo "the app's SUPublicEDKey is not the key given"; exit 1; }

FRAMEWORK="$BUILT/Contents/Frameworks/Sparkle.framework"
[ -d "$FRAMEWORK" ] || { echo "the app carries no Sparkle.framework -> $LOG"; exit 1; }
if [ -n "${COMPANION_SIGN_IDENTITY:-}" ]; then
    # Sparkle's nested parts first (its XPC services, Autoupdate, Updater.app), then the
    # framework, then the app: --deep would sign them with the app's settings.
    NESTED=()
    for x in "$FRAMEWORK"/Versions/B/XPCServices/*.xpc; do [ -e "$x" ] && NESTED+=("$x"); done
    NESTED+=("$FRAMEWORK/Versions/B/Autoupdate" "$FRAMEWORK/Versions/B/Updater.app" "$FRAMEWORK")
    for x in "${NESTED[@]}"; do
        [ -e "$x" ] || { echo "no $x in Sparkle's framework (its layout changed?)"; exit 1; }
        codesign --force --options runtime --timestamp --sign "$COMPANION_SIGN_IDENTITY" "$x" >> "$LOG" 2>&1
    done
    codesign --force --options runtime --timestamp --sign "$COMPANION_SIGN_IDENTITY" "$BUILT" >> "$LOG" 2>&1
    for x in "$BUILT" "${NESTED[@]}"; do
        INFO=$(codesign -dv "$x" 2>&1)
        [[ "$INFO" == *flags=*runtime* ]] || { echo "$x is signed without the hardened runtime"; exit 1; }
    done
else
    codesign --force --sign - "$BUILT" >> "$LOG" 2>&1
fi
codesign --verify --deep --strict "$BUILT" >> "$LOG" 2>&1 || { echo "signature check failed -> $LOG"; exit 1; }
rm -rf "build/$NAME.app"
ditto "$BUILT" "build/$NAME.app"
UPDATES=$([ -n "$KEY" ] && echo "updates on" || echo "updates off: no Sparkle public key")
echo "Brighter Pocket Companion $TOLKARA_VERSION ($BUILD_NUMBER, $UPDATES) -> build/$NAME.app"
[ -n "$DMG" ] || exit 0

STAGE=$(mktemp -d "${TMPDIR:-/tmp}/brighter-pocket-companion.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
ditto "build/$NAME.app" "$STAGE/$NAME.app"
ln -s /Applications "$STAGE/Applications"
rm -f "build/$NAME.dmg"
hdiutil create -volname "$NAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "build/$NAME.dmg" >> "$LOG" 2>&1
echo "-> build/$NAME.dmg"
