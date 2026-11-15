#!/bin/bash
# thermald: Qualcomm Thermal Manager for iOS on Sapphire
# Build: ./build.sh [OUTDIR]
#   thermald -> /redwood/bin/thermald (launchd job com.sapphire.thermald)

set -e
cd "$(dirname "$0")"
SDK=${SDK:-$HOME/sdks/theos-sdks/iPhoneOS16.5.sdk}
LDID=${LDID:-$HOME/tools-dl/ldid/ldid}
CC="/usr/lib/llvm-18/bin/clang -target arm64-apple-ios15.0 -isysroot $SDK -fuse-ld=lld -O2 -Wall -Wextra"
out=${1:-../obj}
mkdir -p "$out"
$CC -o "$out/thermald" thermald.c
"$LDID" -S "$out/thermald"
echo "$out/thermald"