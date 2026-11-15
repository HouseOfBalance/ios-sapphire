#!/bin/bash
# 90-telephony-stack.sh: Configure telephony stack on device
# Binaries (ccstart, bbstart, ccbridge.dylib, libsapphire-fakebb.dylib, etc.)
# are pre-deployed via the .supdate package (make-update.sh copies them to /redwood/bin and /redwood/lib).
# This script only fixes launchd plists and disables CPU-hogging daemons.

set -e

echo "=== [90] Configuring Telephony Stack (launchd plists & daemon control) ==="

# Verify binaries exist (deployed via update package)
echo "=== Verifying telephony binaries ==="
for f in /redwood/bin/ccstart /redwood/bin/bbstart /redwood/bin/pdpnet /redwood/bin/qmitool /redwood/bin/ctdial; do
    if [ -f "$f" ]; then
        echo "  ✓ $f"
    else
        echo "  ✗ $f MISSING (should be in update package)"
    fi
done

for f in /redwood/lib/ccbridge.dylib /redwood/lib/libsapphire-fakebb.dylib /redwood/lib/bdsandbox.dylib /redwood/lib/libredwood-gl.dylib /redwood/lib/libredwood-glload.dylib; do
    if [ -f "$f" ]; then
        echo "  ✓ $f"
    else
        echo "  ✗ $f MISSING (should be in update package)"
    fi
done

# Ensure launchd plists use ccstart and bbstart
echo ""
echo "=== Launchd Configuration ==="
COMM_CENTER_PLIST="/System/Library/LaunchDaemons/com.apple.CommCenter.plist"
LOCATIOND_PLIST="/System/Library/LaunchDaemons/com.apple.locationd.plist"
ABM_HELPER_PLIST="/System/Library/LaunchDaemons/com.apple.abm-helper.plist"

if [ -f "$COMM_CENTER_PLIST" ]; then
    if grep -q "/redwood/bin/ccstart" "$COMM_CENTER_PLIST"; then
        echo "  ✓ CommCenter uses ccstart"
    else
        echo "  ⚠ CommCenter does NOT use ccstart - fixing..."
        plutil -replace ProgramArguments -xml '<array><string>/redwood/bin/ccstart</string></array>' "$COMM_CENTER_PLIST"
        echo "  ✓ Fixed CommCenter plist"
    fi
fi

if [ -f "$LOCATIOND_PLIST" ]; then
    if grep -q "/redwood/bin/bbstart" "$LOCATIOND_PLIST"; then
        echo "  ✓ locationd uses bbstart"
    else
        echo "  ⚠ locationd does NOT use bbstart - fixing..."
        plutil -replace ProgramArguments -xml '<array><string>/redwood/bin/bbstart</string><string>/usr/libexec/locationd</string></array>' "$LOCATIOND_PLIST"
        echo "  ✓ Fixed locationd plist"
    fi
fi

if [ -f "$ABM_HELPER_PLIST" ]; then
    if grep -q "/redwood/bin/bbstart" "$ABM_HELPER_PLIST"; then
        echo "  ✓ abm-helper uses bbstart"
    else
        echo "  ⚠ abm-helper does NOT use bbstart - fixing..."
        plutil -replace ProgramArguments -xml '<array><string>/redwood/bin/bbstart</string><string>/System/Library/PrivateFrameworks/ABMHelper.framework/Support/abm-helper</string></array>' "$ABM_HELPER_PLIST"
        echo "  ✓ Fixed abm-helper plist"
    fi
fi

# Disable dasd and aggregated (CPU hogs) - coreduetd is kept as CRITICAL
echo ""
echo "=== Disabling CPU-hogging daemons (dasd, aggregated) ==="
L="/var/jb/usr/bin/launchctl"
command -v "$L" >/dev/null 2>&1 || L=launchctl

for daemon in com.apple.dasd com.apple.aggregated; do
    "$L" disable "system/$daemon" 2>/dev/null || true
    "$L" bootout "system/$daemon" 2>/dev/null || true
    echo "  ✓ Disabled $daemon"
done

# coreduetd is CRITICAL for location services - ensure it's enabled
"$L" enable "system/com.apple.coreduetd" 2>/dev/null || true
"$L" enable "system/com.apple.coreduetd.osx" 2>/dev/null || true
echo "  ✓ Ensured coreduetd is enabled (CRITICAL for location)"

echo ""
echo "=== [90] Telephony Stack Configuration COMPLETE ==="
true