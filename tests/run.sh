#!/bin/bash
# Every check that runs without a device, on a Mac with Xcode (DEVELOPER_DIR in local.env when
# xcode-select names another developer folder).
#
# usage: tests/run.sh
#
# Always: the layer prepares onto the pinned platform (tools/prepare.py), the profile is
# valid (the platform's own checker), and the offline Steam library, the folder-walk guard and
# the AIR 1.x module rule pass their tests on the host, with sanitizers; every layer source,
# and each platform file a patch changes, compiles for arm64 iOS and the iOS Simulator,
# warnings as errors; the whole app builds (tools/build_ios.py).
# With a client in client/ too (tools/fetch_client.py): the analysis finds a provider for
# every import; Tolkara's own loader, built for the host, reads the staged executable and
# applies all of its fixups, cross-checked pointer by pointer (tests/loader_check.py); every
# shader library passes the on-device rewrap's checks (needs Python's zstandard); and, with
# the emulator's dynarmic (tools/setup_emulator.sh), the client starts up and presents frames.
# What is skipped, and why, is printed.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=build/tests
mkdir -p "$OUT"
PY=${PYTHON:-$( [ -x .venv/bin/python ] && echo .venv/bin/python || echo python3 )}
setting() { "$PY" -c "import sys; sys.path.insert(0, 'tools'); import common; print(common.setting('$1') or '')"; }
DEVELOPER_DIR=$(setting DEVELOPER_DIR); [ -n "$DEVELOPER_DIR" ] && export DEVELOPER_DIR
SAN=(-fsanitize=address,undefined -fno-sanitize=vptr -fno-omit-frame-pointer)
step() { printf '\n== %s\n' "$*"; }

step "the release notes are in the form the site and the companion read (CHANGELOG.md)"
"$PY" tools/check_changelog.py

step "layer prepares onto the pinned platform"
"$PY" tools/prepare.py --out "$OUT/platform"
"$PY" platform/tools/check_profile.py pocket/profiles/brighter-shores/profile.json

step "Steam library (host)"
cc -std=c11 -Wall -Wextra -Werror -O1 -g "${SAN[@]}" -c pocket/translation/libsteam_api/Steam.c -o "$OUT/steam.o"
c++ -std=c++17 -Wall -Wextra -Werror -O1 -g "${SAN[@]}" -Ipocket/translation/libsteam_api tests/steam_test.cpp "$OUT/steam.o" \
    -o "$OUT/steam_test" -rdynamic
"$OUT/steam_test"

step "folder-walk guard (host)"
cc -std=c11 -Wall -Wextra -Werror -O1 -g "${SAN[@]}" -Ipocket/translation/libSystem.B tests/paths_test.c \
    pocket/translation/libSystem.B/ContainerPaths.c -o "$OUT/paths_test"
"$OUT/paths_test"

step "AIR 1.x module ends (host)"
cc -std=c11 -Wall -Wextra -Werror -O1 -g "${SAN[@]}" -Ipocket/translation/Metal tests/metal_test.c -o "$OUT/metal_test"
"$OUT/metal_test"

step "Steam session core (host)"
cc -std=c11 -Wall -Wextra -Werror -O1 -g "${SAN[@]}" -fno-sanitize-recover=all tests/steam_session_test.c \
    pocket/launcher/Pocket/PocketSteam.c -o "$OUT/steam_session_test"
"$OUT/steam_session_test"

step "touch trackpad gestures (host)"
cc -std=c11 -Wall -Wextra -Werror -O1 -g "${SAN[@]}" -fno-sanitize-recover=all -I"$OUT/platform/translation/AppKit" \
    tests/trackpad_test.c "$OUT/platform/translation/AppKit/TouchTrackpad.c" -o "$OUT/trackpad_test"
"$OUT/trackpad_test"

for platform in iphoneos:arm64-apple-ios17.0 iphonesimulator:arm64-apple-ios17.0-simulator; do
    SDKNAME=${platform%%:*}; TARGET=${platform#*:}
    step "layer sources compile for $TARGET"
    SDK=$(xcrun --sdk "$SDKNAME" --show-sdk-path)
    # The prepared tree's headers, which carry the patches the layer's sources build on; -iquote:
    # PocketLocalSigning.m includes the platform's signer, ../../tools/sign_guest_local.m, found
    # beside its copy in the prepared tree.
    IOS=(xcrun --sdk "$SDKNAME" clang -target "$TARGET" -isysroot "$SDK" -O1 -g -fobjc-arc -Wall -Wextra -Werror
         -Wno-deprecated-declarations -I "$OUT/platform/translation/AKSupport" -I "$OUT/platform/translation/AppKit"
         -iquote "$OUT/platform/launcher/Pocket")
    for source in $(find pocket/translation pocket/launcher -name '*.c' -o -name '*.m' | sort) \
                  "$OUT/platform/translation/Metal/LibraryContainer.m"; do
        "${IOS[@]}" -I "$OUT/platform/translation/Metal" -c "$source" -o "$OUT/$SDKNAME-$(basename "$source").o"
        echo "  $source"
    done
done
xcrun nm -gUj "$OUT/iphoneos-Steam.c.o" > "$OUT/steam.exports"

step "the app builds for iOS (tools/build_ios.py)"
"$PY" tools/build_ios.py --out "$OUT/BrighterPocket-unsigned.ipa" | tail -1

if ! "$PY" -c "import sys; sys.path.insert(0, 'tools'); import common; common.client_app()" 2>/dev/null; then
    step "skipped: client analysis, loader, shaders and emulated startup (no client: tools/fetch_client.py)"
    exit 0
fi

step "every import of the client has a provider"
"$PY" tools/analyze_client.py --out "$OUT/client-surface.md"

step "Tolkara's loader places the staged client"
"$PY" tools/stage_client.py --out "$OUT/stage" > /dev/null
cc -std=gnu11 -Wall -O1 -g "${SAN[@]}" -Iplatform/runtime tests/loader_test.c platform/runtime/GuestImage.c \
    platform/runtime/GuestFixups.c platform/runtime/GuestLink.c platform/runtime/GuestMemory.c -o "$OUT/loader_test"
EXECUTABLE="$OUT/stage/Brighter Shores/Brighter Shores.app/Contents/MacOS/Brighter Shores"
SLIDE=280000000   # any page-aligned slide: the launcher's arena is never at the preferred address
"$OUT/loader_test" "$EXECUTABLE" "$OUT/steam.exports" "$OUT/observed.txt" "$SLIDE" | grep -v '^\[guest\]'
"$PY" tests/loader_check.py "$EXECUTABLE" "$OUT/observed.txt" "$SLIDE"

step "the app's own Local signing makes the Mac's page container (host)"
"$PY" "$OUT/platform/tools/build_signed_container.py" --guest "$EXECUTABLE" --platform ios --sign none \
    --output "$PWD/$OUT/mac-container.dylib" | sed 's/^/  /'
xcrun clang -fobjc-arc -O1 -g -Wall -Wextra -Werror -iquote "$OUT/platform/launcher/Pocket" \
    -framework Foundation -framework Security tests/local_signing_test.m -o "$OUT/local_signing_test"
mkdir -p "$OUT/local-signing"
"$OUT/local_signing_test" "$EXECUTABLE" "$OUT/mac-container.dylib" "$OUT/local-signing" > "$OUT/local-signing.log" 2>&1 \
    || { grep -v '^page [0-9]* (' "$OUT/local-signing.log" | tail -20; exit 1; }
grep '^local signing:' "$OUT/local-signing.log"

if "$PY" -c "import zstandard" 2>/dev/null; then
    step "every shader library passes the on-device rewrap and the Mac translation reads it"
    "$PY" tools/check_shaders.py --translator "$OUT/platform/tools/translate_metallib.py"
else
    step "skipped: shader check (pip install zstandard)"
fi

FRAMEWORKS=build/ios/Payload/BrighterPocket.app/Frameworks
if command -v cargo >/dev/null && [ -f .toolchain/emulator/dynarmic/lib/libdynarmic.a ]; then
    "$PY" tools/build_ios.py --for-client > /dev/null   # the adapters the emulator loads, made for the client
    step "the emulator's own tests"
    (cd emulator && cargo test --release -q 2>&1 | grep -E '^test result|FAILED|panicked' )
    step "the client starts up and presents frames, emulated"
    (cd emulator && cargo build --release -q)
    emulator/target/release/pocket-emulator --frames 3 --check --frameworks "$FRAMEWORKS"
else
    step "skipped: emulated startup (cargo; tools/setup_emulator.sh)"
fi
step "all checks passed"
