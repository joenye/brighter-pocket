#!/bin/bash
# Every check that runs without a device, on Linux or a Mac.
#
# usage: tests/run.sh
#
# Always: the layer prepares onto the pinned platform (tools/prepare.py), the profile is
# valid (the platform's own checker), and the offline Steam library, the network guard and
# the AIR 1.x module rule pass their tests on the host, with sanitizers.
# With an iOS SDK (IOS_SDK in local.env) and clang (CLANG, default .toolchain/llvm/bin/clang,
# else clang): every layer source, and each platform file a patch changes, compiles for arm64
# iOS, warnings as errors; on Linux with tools/linux/setup_toolchain.sh's toolchain, the
# whole app builds (tools/build_ios.py).
# With a downloaded client too (tools/fetch_client.py): the analysis finds a provider for
# every import; Tolkara's own loader, built for the host, reads the staged executable and
# applies all of its fixups, cross-checked pointer by pointer (tests/loader_check.py); and
# every shader library passes the on-device rewrap's checks (needs Python's zstandard).
# What is skipped, and why, is printed.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
OUT=build/tests
mkdir -p "$OUT"
PY=${PYTHON:-$( [ -x .venv/bin/python ] && echo .venv/bin/python || echo python3 )}
setting() { "$PY" -c "import sys; sys.path.insert(0, 'tools'); import common; print(common.setting('$1') or '')"; }
SAN=(-fsanitize=address,undefined -fno-sanitize=vptr -fno-omit-frame-pointer)
DL=(); [ "$(uname)" = Linux ] && DL=(-ldl -lpthread)
step() { printf '\n== %s\n' "$*"; }

step "layer prepares onto the pinned platform"
"$PY" tools/prepare.py --out "$OUT/platform"
"$PY" platform/tools/check_profile.py pocket/profiles/brighter-shores/profile.json

step "Steam library (host)"
cc -std=c11 -Wall -Wextra -Werror -O1 -g "${SAN[@]}" -c pocket/translation/libsteam_api/Steam.c -o "$OUT/steam.o"
c++ -std=c++17 -Wall -Wextra -Werror -O1 -g "${SAN[@]}" -Ipocket/translation/libsteam_api tests/steam_test.cpp "$OUT/steam.o" \
    -o "$OUT/steam_test" -rdynamic "${DL[@]}"
"$OUT/steam_test"

step "network guard (host)"
cc -std=c11 -D_GNU_SOURCE -Wall -Wextra -Werror -O1 -g "${SAN[@]}" -Ipocket/translation/libSystem.B tests/network_test.c \
    pocket/translation/libSystem.B/NetworkPolicy.c -o "$OUT/network_test" "${DL[@]}"
"$OUT/network_test"

step "folder-walk guard (host)"
cc -std=c11 -D_GNU_SOURCE -Wall -Wextra -Werror -O1 -g "${SAN[@]}" -Ipocket/translation/libSystem.B tests/paths_test.c \
    pocket/translation/libSystem.B/ContainerPaths.c -o "$OUT/paths_test" "${DL[@]}"
"$OUT/paths_test"

step "AIR 1.x module ends (host)"
cc -std=c11 -Wall -Wextra -Werror -O1 -g "${SAN[@]}" -Ipocket/translation/Metal tests/metal_test.c -o "$OUT/metal_test"
"$OUT/metal_test"

step "Steam session core (host)"
cc -std=c11 -Wall -Wextra -Werror -O1 -g "${SAN[@]}" -fno-sanitize-recover=all tests/steam_session_test.c \
    pocket/launcher/Pocket/PocketSteam.c -o "$OUT/steam_session_test"
"$OUT/steam_session_test"

SDK=$(setting IOS_SDK)
CLANG=${CLANG:-$( [ -x .toolchain/llvm/bin/clang ] && echo .toolchain/llvm/bin/clang || command -v clang || true )}
NM=$(dirname "$CLANG")/llvm-nm; [ -x "$NM" ] || NM=nm
if [ -z "$SDK" ] || [ ! -f "$SDK/SDKSettings.json" ] || [ -z "$CLANG" ]; then
    step "skipped: iOS compile, client analysis, loader (set IOS_SDK in local.env; clang needed)"
    exit 0
fi

step "layer sources compile for arm64 iOS"
IOS=("$CLANG" -target arm64-apple-ios17.0 -isysroot "$SDK" -O1 -g -fobjc-arc -Wall -Wextra -Werror
     -Wno-deprecated-declarations -I platform/translation/AKSupport -I platform/translation/AppKit)
for source in $(find pocket/translation pocket/launcher -name '*.c' -o -name '*.m' | sort) \
              "$OUT/platform/translation/Metal/LibraryContainer.m"; do
    "${IOS[@]}" -I "$OUT/platform/translation/Metal" -c "$source" -o "$OUT/ios-$(basename "$source").o"
    echo "  $source"
done
"$NM" -gUj "$OUT/ios-Steam.c.o" > "$OUT/steam.exports"

if [ "$(uname)" = Linux ] && [ -x .toolchain/ldid ]; then
    step "the app builds for iOS (tools/build_ios.py)"
    "$PY" tools/build_ios.py --out "$OUT/BrighterPocket-unsigned.ipa" | tail -1
fi

if ! "$PY" -c "import sys; sys.path.insert(0, 'tools'); import common; common.client_app()" 2>/dev/null; then
    step "skipped: client analysis and loader (no client: tools/fetch_client.py)"
    exit 0
fi

step "every import of the client has a provider"
"$PY" tools/analyze_client.py --sdk "$SDK" --out "$OUT/client-surface.md"

step "Tolkara's loader places the staged client"
"$PY" tools/stage_client.py --out "$OUT/stage" > /dev/null
COMPAT=$OUT/compat
rm -rf "$COMPAT"; mkdir -p "$COMPAT/mach-o" "$COMPAT/mach/machine" "$COMPAT/architecture"
# The SDK's Mach-O headers, with what they pull in from the kernel's headers reduced to
# the types they need; only on a host that lacks them.
if [ "$(uname)" != Darwin ]; then
    cp "$SDK/usr/include/mach-o/loader.h" "$SDK/usr/include/mach-o/fixup-chains.h" "$COMPAT/mach-o/"
    cp "$SDK/usr/include/mach/machine.h" "$SDK/usr/include/mach/vm_prot.h" "$SDK/usr/include/mach/boolean.h" "$COMPAT/mach/"
    printf '#pragma once\n#include <stdint.h>\ntypedef int32_t integer_t;\ntypedef uint32_t natural_t;\n' > "$COMPAT/mach/machine/vm_types.h"
    printf '#pragma once\ntypedef int boolean_t;\n' > "$COMPAT/mach/machine/boolean.h"
    printf '#pragma once\n' > "$COMPAT/mach/machine/thread_status.h"
    printf '#pragma once\n' > "$COMPAT/architecture/byte_order.h"
fi
cc -std=gnu11 -Wall -O1 -g "${SAN[@]}" -I"$COMPAT" -Iplatform/runtime tests/loader_test.c platform/runtime/GuestImage.c \
    platform/runtime/GuestFixups.c platform/runtime/GuestLink.c platform/runtime/GuestMemory.c -o "$OUT/loader_test"
EXECUTABLE="$OUT/stage/Brighter Shores/Brighter Shores.app/Contents/MacOS/Brighter Shores"
SLIDE=280000000   # any page-aligned slide: the launcher's arena is never at the preferred address
"$OUT/loader_test" "$EXECUTABLE" "$OUT/steam.exports" "$OUT/observed.txt" "$SLIDE" | grep -v '^\[guest\]'
"$PY" tests/loader_check.py "$EXECUTABLE" "$OUT/observed.txt" "$SLIDE"

if "$PY" -c "import zstandard" 2>/dev/null; then
    step "every shader library passes the on-device rewrap and the Mac translation reads it"
    "$PY" tools/check_shaders.py --translator "$OUT/platform/tools/translate_metallib.py"
else
    step "skipped: shader check (pip install zstandard)"
fi

FRAMEWORKS=build/ios/Payload/BrighterPocket.app/Frameworks
if "$PY" -c "import unicorn, zstandard" 2>/dev/null && [ -f "$FRAMEWORKS/aklibsteam_api.dylib" ]; then
    step "the client starts up and presents frames, emulated (about 30 s)"
    "$PY" tests/emulate/boot.py --frames 3 --check --frameworks "$FRAMEWORKS" | grep -v '^prepared '
else
    step "skipped: emulated startup (pip install unicorn zstandard; the app built by tools/build_ios.py)"
fi
step "all checks passed"
