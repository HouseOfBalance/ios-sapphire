#!/bin/bash
# sensord: ADSP QMI SNS_CLIENT sensor daemon for iOS on Sapphire
# Build: ./build.sh [OUTDIR]
#   sensord -> /redwood/bin/sensord (launchd job com.sapphire.sensord)

set -e
cd "$(dirname "$0")"
SDK=${SDK:-$HOME/sdks/theos-sdks/iPhoneOS16.5.sdk}
LDID=${LDID:-$HOME/tools-dl/ldid/ldid}
CC="/usr/lib/llvm-18/bin/clang -target arm64-apple-ios15.0 -isysroot $SDK -fuse-ld=lld -O2 -Wall -Wextra"
out=${1:-../obj}
mkdir -p "$out"
$CC -o "$out/sensord" sensord.c
"$LDID" -S "$out/sensord"
echo "$out/sensord"