#!/bin/bash
# build.sh [OUTDIR]: SapphireBTCapability.dylib (+ .plist) for /var/jb/usr/lib/TweakInject (ElleKit)
# Default OUTDIR: /redwood/tweaks (for installer deployment)
set -e
cd "$(dirname "$0")"
SDK=${SDK:-$HOME/sdks/theos-sdks/iPhoneOS16.5.sdk}
LDID=${LDID:-$HOME/tools-dl/ldid/ldid}
out=${1:-/redwood/tweaks}
mkdir -p "$out"
if [[ "$OSTYPE" == "darwin"* ]]; then
    CC_BIN="${CC:-$(xcrun -find clang)}"
    LDFLAGS=""
else
    CC_BIN="${CC:-/usr/lib/llvm-18/bin/clang}"
    LDFLAGS="-fuse-ld=lld"
fi
$CC_BIN -target arm64-apple-ios16.0 -isysroot "$SDK" $LDFLAGS -O2 -Wall -fobjc-arc -dynamiclib \
	-install_name /var/jb/usr/lib/TweakInject/SapphireBTCapability.dylib -lobjc -framework Foundation -framework IOKit \
	-o "$out/SapphireBTCapability.dylib" SapphireBTCapability.m
"$LDID" -S "$out/SapphireBTCapability.dylib"
cp SapphireBTCapability.plist "$out/SapphireBTCapability.plist"
echo "$out/SapphireBTCapability.dylib"
