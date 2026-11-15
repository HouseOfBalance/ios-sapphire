#!/bin/bash
# 65-bluetooth-capability-tweak.sh: Install SapphireBTCapability tweak
# This tweak hooks MobileGestalt to report bluetooth=true and provides
# the BluetoothAddress, fixing "Bluetooth Unavailable" in Settings.
# The tweak binary and plist are PRE-BUILT and deployed via .supdate package.
# NO building on device (no iOS SDK/Clang on phone).

set -e

echo "=== [65] Installing SapphireBTCapability tweak ==="

JB_ROOT="/private/var/jb"
TWEAK_DIR="$JB_ROOT/usr/lib/TweakInject"

# Create TweakInject directory if it doesn't exist
mkdir -p "$TWEAK_DIR"

# Check if tweak is already installed (from overlay/update image)
if [ -f "$TWEAK_DIR/SapphireBTCapability.dylib" ] && [ -f "$TWEAK_DIR/SapphireBTCapability.plist" ]; then
    echo "  ✓ SapphireBTCapability already installed in $TWEAK_DIR"
else
    # The tweak binary and plist should be pre-built and placed in /redwood/tweaks/
    # by the build/deploy process (make-update.sh copies them there).
    if [ -f /redwood/tweaks/SapphireBTCapability.dylib ] && [ -f /redwood/tweaks/SapphireBTCapability.plist ]; then
        cp /redwood/tweaks/SapphireBTCapability.dylib "$TWEAK_DIR/"
        cp /redwood/tweaks/SapphireBTCapability.plist "$TWEAK_DIR/"
        chmod 755 "$TWEAK_DIR/SapphireBTCapability.dylib"
        chmod 644 "$TWEAK_DIR/SapphireBTCapability.plist"
        echo "  ✓ SapphireBTCapability.dylib deployed to $TWEAK_DIR from /redwood/tweaks/"
    else
        echo "  ⚠ WARNING: SapphireBTCapability.dylib not found at /redwood/tweaks/"
        echo "    This means the update package was built without the pre-built tweak."
        echo "    Build on macOS: cd userland/tweaks/btcapability && bash build.sh /redwood/tweaks"
        echo "    Continuing without tweak..."
    fi
fi

# Verify the tweak filter includes SpringBoard, Preferences, and BluetoothManager
if [ -f "$TWEAK_DIR/SapphireBTCapability.plist" ]; then
    if plutil -p "$TWEAK_DIR/SapphireBTCapability.plist" 2>/dev/null | grep -q "com.apple.springboard"; then
        echo "  ✓ Tweak filter includes SpringBoard"
    else
        echo "  ⚠ Tweak filter may be missing SpringBoard"
    fi
    if plutil -p "$TWEAK_DIR/SapphireBTCapability.plist" 2>/dev/null | grep -q "com.apple.Preferences"; then
        echo "  ✓ Tweak filter includes Preferences"
    else
        echo "  ⚠ Tweak filter may be missing Preferences"
    fi
    if plutil -p "$TWEAK_DIR/SapphireBTCapability.plist" 2>/dev/null | grep -q "com.apple.BluetoothManager"; then
        echo "  ✓ Tweak filter includes BluetoothManager"
    else
        echo "  ⚠ Tweak filter may be missing BluetoothManager"
    fi
fi

# The tweak will be loaded on next SpringBoard launch via ElleKit
# No need to reload SpringBoard here - that requires user action

echo "=== [65] Bluetooth capability tweak installation complete ==="
true