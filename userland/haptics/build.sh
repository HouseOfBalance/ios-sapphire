#!/bin/bash
# vibd: vibration motor daemon for iOS on Sapphire (ERM motor via PM7250B LDO)
# Build: ./build.sh [OUTDIR]
#   vibd -> /redwood/bin/vibd (launchd job com.sapphire.vibd)

set -e
cd "$(dirname "$0")"
SDK=${SDK:-$HOME/sdks/theos-sdks/iPhoneOS16.5.sdk}
LDID=${LDID:-$HOME/tools-dl/ldid/ldid}
CC="/usr/lib/llvm-18/bin/clang -target arm64-apple-ios15.0 -isysroot $SDK -fuse-ld=lld -O2 -Wall -Wextra"
out=${1:-../obj}
mkdir -p "$out"
$CC -o "$out/vibd" vibd.c
"$LDID" -S "$out/vibd"
echo "$out/vibd"