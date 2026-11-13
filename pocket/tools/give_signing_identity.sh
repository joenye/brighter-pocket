#!/bin/bash
# Gives Brighter Pocket on the device your Apple Development identity, once, so that it signs
# the page container for a new build of the game itself (launcher/Pocket/PocketLocalSigning.m):
# a game update then needs no Mac to sign it. The key goes over the cable inside a PKCS#12 file
# under a random passphrase, which reaches the app only as a launch argument, with the
# certificates that complete its chain; the app keeps them in its keychain and deletes the
# files. tools/install.sh runs this with Local signing; it does nothing when the app already
# has this Mac's current identity with its chain (--again gives it again regardless). macOS may
# ask to allow the export of the key: choose Allow and enter your Mac password.
#
# usage: tools/give_signing_identity.sh DEVICE BUNDLE_ID TEAM_ID [--again]
set -euo pipefail
cd "$(dirname "$0")/.."
[ $# -ge 3 ] || { echo "usage: tools/give_signing_identity.sh DEVICE BUNDLE_ID TEAM_ID [--again]"; exit 2; }
DEVICE=$1; BUNDLE=$2; TEAM=$3
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p build/signing-identity
TOOL=build/signing-identity/export_signing_identity
if [ ! -x "$TOOL" ] || [ tools/export_signing_identity.m -nt "$TOOL" ]; then
    xcrun clang -fobjc-arc -O1 -Wall -Wextra -Werror -framework Foundation -framework Security \
        tools/export_signing_identity.m -o "$TOOL"
fi
# The app notes the identity it keeps in Documents/LocalSigning/identity.txt: its name, its
# certificate's SHA-1 and how many chain certificates came with it. The same certificate as
# this Mac's, with its chain: nothing to do.
if [ "${4:-}" != --again ] && xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer \
        --domain-identifier "$BUNDLE" --source Documents/LocalSigning/identity.txt --destination "$WORK/identity.txt" \
        > /dev/null 2>&1 && [ -s "$WORK/identity.txt" ]; then
    MINE=$("$TOOL" --fingerprint "$TEAM" 2>/dev/null || true)
    if [ -n "$MINE" ] && [ "$(sed -n 2p "$WORK/identity.txt")" = "$MINE" ] && [ "$(sed -n 3p "$WORK/identity.txt")" -gt 0 ] 2>/dev/null; then
        echo "Brighter Pocket on this device already signs with $(head -n 1 "$WORK/identity.txt")."
        exit 0
    fi
    echo "The developer identity on the device is not this Mac's current one; giving it again."
fi
PASSPHRASE=$(python3 -c 'import secrets; print(secrets.token_hex(24))')
echo "Giving Brighter Pocket your developer identity, so it signs new builds of the game itself."
echo "macOS may ask to allow the export of its key: choose Allow and enter your Mac password."
SIGNING_PASSPHRASE="$PASSPHRASE" "$TOOL" "$TEAM" "$WORK/identity.p12" "$WORK/identity-chain.pem"
for file in identity-chain.pem identity.p12; do
    xcrun devicectl device copy to --device "$DEVICE" --domain-type appDataContainer --domain-identifier "$BUNDLE" \
        --source "$WORK/$file" --destination "Documents/LocalSigning/$file" > "$WORK/copy.log" 2>&1 \
        || { cat "$WORK/copy.log"; echo "COPY FAILED: keep the device connected and unlocked"; exit 1; }
done
xcrun devicectl device process launch --terminate-existing --device "$DEVICE" "$BUNDLE" \
    --signing-identity-passphrase="$PASSPHRASE" > "$WORK/launch.log" 2>&1 \
    || { echo "LAUNCH FAILED: unlock the device and run this again (the copied file is deleted at the app's next start)"; exit 1; }
sleep 3   # the app takes the identity as it starts
echo "Brighter Pocket has your developer identity: it signs new builds of the game on the device."
