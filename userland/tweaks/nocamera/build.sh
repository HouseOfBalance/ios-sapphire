#!/bin/bash
# build.sh OUTDIR: SapphireNoCamera.dylib (+ .plist) for /var/jb/usr/lib/TweakInject (ElleKit)
set -e
cd "$(dirname "$0")"
SDK=${SDK:-$HOME/sdks/theos-sdks/iPhoneOS16.5.sdk}
LDID=${LDID:-$HOME/tools-dl/ldid/ldid}
CLANG=${CLANG:-clang}
out=${1:-/tmp}
"$CLANG" -target arm64-apple-ios16.0 -isysroot "$SDK" -O2 -Wall -dynamiclib \
	-install_name /var/jb/usr/lib/TweakInject/SapphireNoCamera.dylib \
	-framework CoreFoundation -framework CoreGraphics -framework CoreMedia -framework CoreVideo -framework QuartzCore \
	-lobjc -o "$out/SapphireNoCamera.dylib" SapphireNoCamera.c
"$LDID" -S "$out/SapphireNoCamera.dylib"
cp SapphireNoCamera.plist "$out/SapphireNoCamera.plist"
echo "$out/SapphireNoCamera.dylib"
