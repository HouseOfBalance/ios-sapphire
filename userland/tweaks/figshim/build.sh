#!/bin/bash
set -e
cd "$(dirname "$0")"
SDK=${SDK:-$HOME/sdks/theos-sdks/iPhoneOS16.5.sdk}
LDID=${LDID:-$HOME/tools-dl/ldid/ldid}
CLANG=${CLANG:-clang}
out=${1:-/tmp}
"$CLANG" -target arm64-apple-ios16.0 -isysroot "$SDK" -O2 -Wall -dynamiclib \
	-install_name /var/jb/usr/lib/TweakInject/SapphireFigShim.dylib \
	-framework CoreFoundation -framework IOSurface \
	-lobjc -o "$out/SapphireFigShim.dylib" SapphireFigShim.c
"$LDID" -S "$out/SapphireFigShim.dylib"
cp SapphireFigShim.plist "$out/SapphireFigShim.plist"
echo "$out/SapphireFigShim.dylib"
