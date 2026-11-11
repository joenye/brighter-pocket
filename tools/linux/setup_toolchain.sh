#!/bin/bash
# Install what tools/build_ios.py needs on Linux (x86_64) into .toolchain/ (ignored):
#   llvm/   LLVM 23.1.5's release build, only clang, ld64.lld and the llvm-* tools used
#   llvm/lib/clang/23/lib/darwin/libclang_rt.ios.a   the one compiler-rt piece the app needs
#           (__isPlatformVersionAtLeast, behind @available), built from LLVM's source of the
#           same release; Xcode ships it, LLVM's Linux release does not
#   ldid    ProcursusTeam's ldid 2.1.5, for the ad hoc signatures that declare entitlements
#
# usage: tools/linux/setup_toolchain.sh
#
# The iPhoneOS SDK is not downloaded: copy Xcode's (Xcode.app/Contents/Developer/Platforms/
# iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk) and set IOS_SDK in local.env. It is needed
# here to build the compiler-rt piece. Downloads come from GitHub; ldid and the compiler-rt
# source are checked against the hashes below.
set -euo pipefail
cd "$(dirname "$0")/../.."
LLVM_VERSION=23.1.5
LDID_URL=https://github.com/ProcursusTeam/ldid/releases/download/v2.1.5-procursus7/ldid_linux_x86_64
LDID_SHA256=4b8862b2fefa2cd7fa8f88cb0310779619aeaa8c72d6aff22f019b470f2fa99a
OS_VERSION_CHECK_SHA256=37accdfb259f9228c1e5049e8bc3dcc2c996fa17c7fda542eed977237af71a9e
T=.toolchain
mkdir -p "$T"

IOS_SDK=${IOS_SDK:-$(sed -n 's/^IOS_SDK=//p' local.env 2>/dev/null | tr -d '"'"'" | tail -1)}
[ -n "$IOS_SDK" ] && [ -f "$IOS_SDK/SDKSettings.json" ] || { echo "set IOS_SDK in local.env to an iPhoneOS SDK folder first" >&2; exit 1; }

if ! "$T/llvm/bin/clang" --version 2>/dev/null | grep -q "clang version $LLVM_VERSION"; then
    echo "downloading LLVM $LLVM_VERSION (about 2 GB, of which about 800 MB is kept)"
    rm -rf "$T/llvm" "$T/LLVM-$LLVM_VERSION-Linux-X64"
    curl -fsSL "https://github.com/llvm/llvm-project/releases/download/llvmorg-$LLVM_VERSION/LLVM-$LLVM_VERSION-Linux-X64.tar.xz" |
        tar -xJ -C "$T" --wildcards '*/bin/clang' '*/bin/clang-[0-9]*' '*/bin/clang++' '*/bin/lld' '*/bin/ld64.lld' \
            '*/bin/llvm-ar' '*/bin/llvm-lipo' '*/bin/llvm-nm' '*/bin/llvm-objdump' '*/bin/llvm-otool' \
            '*/bin/llvm-install-name-tool' '*/bin/llvm-readobj' '*/bin/llvm-strip' '*/bin/llvm-objcopy' \
            '*/bin/llvm-ranlib' '*/bin/llvm-readtapi' '*/lib/clang/*'
    mv "$T/LLVM-$LLVM_VERSION-Linux-X64" "$T/llvm"
fi

if [ ! -x "$T/ldid" ] || ! echo "$LDID_SHA256  $T/ldid" | sha256sum -c --status; then
    curl -fsSL -o "$T/ldid" "$LDID_URL"
    echo "$LDID_SHA256  $T/ldid" | sha256sum -c --status || { echo "ldid does not match its pinned hash" >&2; rm -f "$T/ldid"; exit 1; }
    chmod +x "$T/ldid"
fi

# clang's resource directory (lib/clang/<major>), where the Darwin driver looks for it.
RT=$("$T/llvm/bin/clang" -print-resource-dir)/lib/darwin/libclang_rt.ios.a
if [ ! -f "$RT" ]; then
    mkdir -p "$T/compiler-rt" "$(dirname "$RT")"
    curl -fsSL -o "$T/compiler-rt/os_version_check.c" \
        "https://raw.githubusercontent.com/llvm/llvm-project/llvmorg-$LLVM_VERSION/compiler-rt/lib/builtins/os_version_check.c"
    echo "$OS_VERSION_CHECK_SHA256  $T/compiler-rt/os_version_check.c" | sha256sum -c --status ||
        { echo "os_version_check.c does not match its pinned hash" >&2; exit 1; }
    "$T/llvm/bin/clang" -target arm64-apple-ios17.0 -isysroot "$IOS_SDK" -O2 -c "$T/compiler-rt/os_version_check.c" \
        -o "$T/compiler-rt/os_version_check.o"
    "$T/llvm/bin/llvm-ar" rcs "$RT" "$T/compiler-rt/os_version_check.o"
fi
"$T/llvm/bin/clang" --version | head -1
echo "toolchain ready in $T"
