#!/bin/bash
# 84-fix-brightness-corebrightness.sh: Clean up deprecated CoreBrightness overrides
# The native brightness is handled by eagl.c bridge (backboardd -> AppleCLCD) when sweetbl=0.
# Fake daemons and polling loops are removed.

set -e

echo "=== [84] Purging deprecated brightness polling daemons ==="

# Stop and remove any fake corebrightnessd override
launchctl bootout system/com.apple.corebrightnessd 2>/dev/null || launchctl remove com.apple.corebrightnessd 2>/dev/null || true
rm -f /redwood/launchd/com.apple.corebrightnessd.plist

# Stop and remove dsi-brightness-bridge polling daemon
launchctl bootout system/com.sapphire.dsi-brightness 2>/dev/null || launchctl remove com.sapphire.dsi-brightness 2>/dev/null || true
rm -f /redwood/launchd/com.sapphire.dsi-brightness.plist
rm -f /redwood/bin/dsi-brightness-bridge.sh
rm -f /redwood/boot.d/84-publish-display-params.sh
rm -f /redwood/bin/publish-display-params.sh

echo "  ✓ Deprecated brightness daemons cleaned up"
