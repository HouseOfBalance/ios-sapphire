#!/bin/bash
# build_all.sh: Build all userland binaries for iOS 16.7.16 on sapphire
# Run on macOS with Xcode 15/16 and iPhoneOS16.5.sdk
# Usage: ./build_all.sh [SDK_PATH] [OUTDIR] [LDID_PATH]

set -euo pipefail

SDK="${1:-$HOME/sdks/theos-sdks/iPhoneOS16.5.sdk}"
OUTDIR="${2:-../obj}"
LDID="${3:-$HOME/tools-dl/ldid/ldid}"

# Verify SDK exists
if [ ! -d "$SDK" ]; then
    echo "ERROR: iPhoneOS SDK not found at $SDK"
    echo "Download from https://github.com/theos/theos-sdks or extract from Xcode"
    exit 1
fi

# Verify ldid exists
if [ ! -x "$LDID" ]; then
    echo "ERROR: ldid not found at $LDID"
    echo "Build ldid from https://github.com/xerub/ldid"
    exit 1
fi

# Compiler flags for iOS 16 arm64
if [[ "$OSTYPE" == "darwin"* ]]; then
    CC="${CC:-$(xcrun -find clang)}"
    CFLAGS="-target arm64-apple-ios15.0 -isysroot $SDK -O2 -Wall -Wextra -Wno-unused-parameter"
else
    CC="${CC:-/usr/lib/llvm-18/bin/clang}"
    CFLAGS="-target arm64-apple-ios15.0 -isysroot $SDK -fuse-ld=lld -O2 -Wall -Wextra -Wno-unused-parameter"
fi

echo "=== Building all userland binaries for iOS 16 ==="
echo "SDK: $SDK"
echo "OUTDIR: $OUTDIR"
echo "LDID: $LDID"
echo "CC: $CC"
echo

mkdir -p "$OUTDIR"

# Function to build a component
build_component() {
    local name="$1"
    local dir="$2"
    local makefile="$3"
    local targets="$4"

    echo "=== Building $name ==="
    pushd "$dir" >/dev/null
    make -f "$makefile" OUTDIR="$OUTDIR" SDK="$SDK" LDID="$LDID" CC="$CC" CFLAGS="$CFLAGS" $targets
    popd >/dev/null
    echo "=== $name done ==="
    echo
}

# Build all components
build_component "sensord" "sensors" "Makefile" "all"
build_component "vibd" "haptics" "Makefile" "all"
build_component "SapphireHaptics.dylib" "haptics" "Makefile" "all"
build_component "thermald" "thermal" "Makefile" "all"
build_component "RedwoodAudio.driver" "audio" "Makefile" "all"
build_component "btmonitor" "bluetooth" "Makefile" "all"
build_component "SapphireBTCapability.dylib" "tweaks/btcapability" "build.sh" ""

# Build telephony components (ccstart, bbstart, ccbridge, fakebb, etc.)
echo "=== Building telephony components ==="
pushd "telephony" >/dev/null
bash build.sh
popd >/dev/null
echo "=== Telephony done ==="
echo

# Build eagl.c (the GL bridge for backboardd)
echo "=== Building eagl.c (GL bridge) ==="
pushd "src" >/dev/null
$CC $CFLAGS -dynamiclib -o "$OUTDIR"/eagl.dylib eagl.c \
    -framework Foundation -framework IOKit -framework CoreFoundation \
    -framework CoreGraphics -framework QuartzCore -framework AudioToolbox \
    -ldl -lpthread
$LDID -S "$OUTDIR"/eagl.dylib
popd >/dev/null
echo "=== eagl.dylib done ==="
echo

# Verify all outputs
echo "=== Verifying built binaries ==="
for bin in \
    "$OUTDIR"/sensord \
    "$OUTDIR"/vibd \
    "$OUTDIR"/SapphireHaptics.dylib \
    "$OUTDIR"/thermald \
    "$OUTDIR"/RedwoodAudio.driver/RedwoodAudio \
    "$OUTDIR"/eagl.dylib \
    "$OUTDIR"/btmonitor \
    "$OUTDIR"/SapphireBTCapability.dylib \
    "$OUTDIR"/ccstart \
    "$OUTDIR"/bbstart \
    "$OUTDIR"/pdpnet \
    "$OUTDIR"/qmitool \
    "$OUTDIR"/ctdial \
    "$OUTDIR"/ccbridge.dylib \
    "$OUTDIR"/libsapphire-fakebb.dylib \
    "$OUTDIR"/bdsandbox.dylib \
    "$OUTDIR"/libredwood-gl.dylib \
    "$OUTDIR"/libredwood-glload.dylib; do
    if [ -f "$bin" ]; then
        echo "✓ $bin"
        file "$bin"
    else
        echo "✗ MISSING: $bin"
        exit 1
    fi
done

echo
echo "=== All binaries built successfully! ==="
echo "Output directory: $OUTDIR"
echo
echo "To deploy to device, copy to /redwood/bin/ on iosroot partition:"
echo "  cp $OUTDIR/sensord /mnt/iosroot/redwood/bin/"
echo "  cp $OUTDIR/vibd /mnt/iosroot/redwood/bin/"
echo "  cp $OUTDIR/thermald /mnt/iosroot/redwood/bin/"
echo "  cp $OUTDIR/btmonitor /mnt/iosroot/redwood/bin/"
echo "  cp $OUTDIR/ccstart /mnt/iosroot/redwood/bin/"
echo "  cp $OUTDIR/bbstart /mnt/iosroot/redwood/bin/"
echo "  cp $OUTDIR/pdpnet /mnt/iosroot/redwood/bin/"
echo "  cp $OUTDIR/qmitool /mnt/iosroot/redwood/bin/"
echo "  cp $OUTDIR/ctdial /mnt/iosroot/redwood/bin/"
echo "  cp $OUTDIR/SapphireHaptics.dylib /mnt/iosroot/redwood/tweaks/"
echo "  cp $OUTDIR/SapphireBTCapability.dylib /mnt/iosroot/redwood/tweaks/"
echo "  cp $OUTDIR/SapphireBTCapability.plist /mnt/iosroot/redwood/tweaks/"
echo "  cp $OUTDIR/RedwoodAudio.driver /mnt/iosroot/System/Library/Audio/Plug-Ins/HAL/"
echo "  cp $OUTDIR/eagl.dylib /mnt/iosroot/redwood/lib/"
echo "  cp $OUTDIR/ccbridge.dylib /mnt/iosroot/redwood/lib/"
echo "  cp $OUTDIR/libsapphire-fakebb.dylib /mnt/iosroot/redwood/lib/"
echo "  cp $OUTDIR/bdsandbox.dylib /mnt/iosroot/redwood/lib/"
echo "  cp $OUTDIR/libredwood-gl.dylib /mnt/iosroot/redwood/lib/"
echo "  cp $OUTDIR/libredwood-glload.dylib /mnt/iosroot/redwood/lib/"
echo
echo "Don't forget to copy launchd plists from each component's directory to /mnt/iosroot/redwood/launchd/"