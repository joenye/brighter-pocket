#!/bin/bash
# Build what the emulator (emulator/, docs/emulator.md) links into .toolchain/emulator/ (ignored):
#   dynarmic   the arm64 JIT (azahar-emu's fork, pinned below), static, A64 frontend on its arm64
#              backend, with the externals it bundles for that (fmt, mcl, oaknut, robin-map), and
#              the patches in emulator/dynarmic-patches/ applied in order
#   boost/     Boost's headers (dynarmic uses ICL and variant), from Boost's own archive
#
# usage: tools/setup_emulator.sh
#
# For an Apple silicon Mac: needs git, curl, cmake (Homebrew) and Xcode's clang and mig (the
# Command Line Tools, or DEVELOPER_DIR in local.env). Builds with one job per core.
set -euo pipefail
cd "$(dirname "$0")/.."
DYNARMIC_URL=https://github.com/azahar-emu/dynarmic.git
DYNARMIC_COMMIT=a46601580d5512d324104f985b5f0209dc980ddc
BOOST_VERSION=1.86.0
BOOST_URL=https://archives.boost.io/release/$BOOST_VERSION/source/boost_${BOOST_VERSION//./_}.tar.bz2
BOOST_SHA256=1bed88e40401b2cb7a1f76d4bab499e352fa4d0c5f31c0dbae64e24d34d7513b
PATCHES=emulator/dynarmic-patches
E=.toolchain/emulator
mkdir -p "$E"

if [ "$(uname -s)/$(uname -m)" != "Darwin/arm64" ]; then
    echo "tools/setup_emulator.sh builds for an Apple silicon Mac (macOS on arm64)" >&2
    exit 1
fi
developer=$(sed -n 's/^DEVELOPER_DIR=//p' local.env 2>/dev/null | tail -n 1)
if [ -n "$developer" ]; then
    export DEVELOPER_DIR="$developer"
fi

if [ ! -f "$E/boost/boost/icl/interval_set.hpp" ]; then
    echo "downloading Boost $BOOST_VERSION's headers"
    curl -fsSL "$BOOST_URL" -o "$E/boost.tar.bz2"
    echo "$BOOST_SHA256  $E/boost.tar.bz2" | shasum -a 256 -c --quiet
    rm -rf "$E/boost" && mkdir -p "$E/boost"
    tar -xjf "$E/boost.tar.bz2" -C "$E/boost" --strip-components=1 "boost_${BOOST_VERSION//./_}/boost"
    rm "$E/boost.tar.bz2"
fi

# A checkout at the pin with exactly the patches in $PATCHES applied (their digest is kept beside
# it); anything else is checked out again and patched.
shopt -s nullglob
patches=("$PATCHES"/*.patch)
patched=$(cat /dev/null ${patches[@]+"${patches[@]}"} | shasum -a 256 | cut -c1-64)
head=$(git -C "$E/dynarmic-src" rev-parse HEAD 2>/dev/null || true)
if [ "$head" != "$DYNARMIC_COMMIT" ] || [ "$(cat "$E/dynarmic-src/.pocket-patches" 2>/dev/null)" != "$patched" ]; then
    if [ "$head" != "$DYNARMIC_COMMIT" ]; then
        rm -rf "$E/dynarmic-src"
        git init -q "$E/dynarmic-src"
        git -C "$E/dynarmic-src" fetch -q --depth 1 "$DYNARMIC_URL" "$DYNARMIC_COMMIT"
    fi
    git -C "$E/dynarmic-src" checkout -q -f "$DYNARMIC_COMMIT"
    git -C "$E/dynarmic-src" clean -q -fdx
    for external in fmt mcl oaknut robin-map; do
        git -C "$E/dynarmic-src" submodule update -q --init --depth 1 "externals/$external"
    done
    for patch in ${patches[@]+"${patches[@]}"}; do
        git -C "$E/dynarmic-src" apply "$PWD/$patch"
    done
    echo "$patched" > "$E/dynarmic-src/.pocket-patches"
    rm -rf "$E/dynarmic" "$E/dynarmic-build"
fi

if [ ! -f "$E/dynarmic/lib/libdynarmic.a" ] || [ -n "$(find "$E/dynarmic-src/src" -newer "$E/dynarmic/lib/libdynarmic.a" -print -quit)" ]; then
    cmake -S "$E/dynarmic-src" -B "$E/dynarmic-build" -DCMAKE_BUILD_TYPE=Release -DDYNARMIC_FRONTENDS=A64 \
        -DDYNARMIC_TESTS=OFF -DDYNARMIC_USE_BUNDLED_EXTERNALS=ON -DDYNARMIC_WARNINGS_AS_ERRORS=OFF \
        -DDYNARMIC_USE_PRECOMPILED_HEADERS=OFF -DBoost_INCLUDE_DIR="$PWD/$E/boost" \
        -DCMAKE_OSX_ARCHITECTURES=arm64 -Wno-author -Wno-deprecated \
        -DCMAKE_INSTALL_PREFIX="$PWD/$E/dynarmic" -DCMAKE_POSITION_INDEPENDENT_CODE=ON >/dev/null
    cmake --build "$E/dynarmic-build" -j "$(sysctl -n hw.ncpu)"
    cmake --install "$E/dynarmic-build" >/dev/null
fi
echo "dynarmic $DYNARMIC_COMMIT and Boost $BOOST_VERSION headers in $E"
