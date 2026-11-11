#!/bin/bash
# Build what the emulator (emulator/, docs/emulator.md) links into .toolchain/emulator/ (ignored):
#   dynarmic   the arm64-to-x86-64 JIT (azahar-emu's fork, pinned below), static, A64 frontend
#              only, with the externals it bundles (fmt, mcl, robin-map, xbyak, zydis, zycore)
#   boost/     Boost's headers (dynarmic uses ICL and variant), from Boost's own archive
#
# usage: tools/linux/setup_emulator.sh
#
# Needs git, curl, cmake and a C++20 compiler (g++ 13 here). Builds with 4 jobs: the WSL's
# memory is shared with other work.
set -euo pipefail
cd "$(dirname "$0")/../.."
DYNARMIC_URL=https://github.com/azahar-emu/dynarmic.git
DYNARMIC_COMMIT=a46601580d5512d324104f985b5f0209dc980ddc
BOOST_VERSION=1.86.0
BOOST_URL=https://archives.boost.io/release/$BOOST_VERSION/source/boost_${BOOST_VERSION//./_}.tar.bz2
BOOST_SHA256=1bed88e40401b2cb7a1f76d4bab499e352fa4d0c5f31c0dbae64e24d34d7513b
E=.toolchain/emulator
mkdir -p "$E"

if [ ! -f "$E/boost/boost/icl/interval_set.hpp" ]; then
    echo "downloading Boost $BOOST_VERSION's headers"
    curl -fsSL "$BOOST_URL" -o "$E/boost.tar.bz2"
    echo "$BOOST_SHA256  $E/boost.tar.bz2" | sha256sum -c --quiet
    rm -rf "$E/boost" && mkdir -p "$E/boost"
    tar -xjf "$E/boost.tar.bz2" -C "$E/boost" --strip-components=1 "boost_${BOOST_VERSION//./_}/boost"
    rm "$E/boost.tar.bz2"
fi

if [ "$(git -C "$E/dynarmic-src" rev-parse HEAD 2>/dev/null)" != "$DYNARMIC_COMMIT" ]; then
    rm -rf "$E/dynarmic-src"
    git init -q "$E/dynarmic-src"
    git -C "$E/dynarmic-src" fetch -q --depth 1 "$DYNARMIC_URL" "$DYNARMIC_COMMIT"
    git -C "$E/dynarmic-src" checkout -q FETCH_HEAD
    for external in fmt mcl robin-map xbyak zycore zydis; do
        git -C "$E/dynarmic-src" submodule update -q --init --depth 1 "externals/$external"
    done
fi

if [ ! -f "$E/dynarmic/lib/libdynarmic.a" ] || [ -n "$(find "$E/dynarmic-src/src" -newer "$E/dynarmic/lib/libdynarmic.a" -print -quit)" ]; then
    cmake -S "$E/dynarmic-src" -B "$E/dynarmic-build" -DCMAKE_BUILD_TYPE=Release -DDYNARMIC_FRONTENDS=A64 \
        -DDYNARMIC_TESTS=OFF -DDYNARMIC_USE_BUNDLED_EXTERNALS=ON -DDYNARMIC_WARNINGS_AS_ERRORS=OFF \
        -DDYNARMIC_USE_PRECOMPILED_HEADERS=OFF -DBoost_INCLUDE_DIR="$PWD/$E/boost" \
        -DCMAKE_INSTALL_PREFIX="$PWD/$E/dynarmic" -DCMAKE_POSITION_INDEPENDENT_CODE=ON >/dev/null
    cmake --build "$E/dynarmic-build" -j 4
    cmake --install "$E/dynarmic-build" >/dev/null
fi
echo "dynarmic $DYNARMIC_COMMIT and Boost $BOOST_VERSION headers in $E"
