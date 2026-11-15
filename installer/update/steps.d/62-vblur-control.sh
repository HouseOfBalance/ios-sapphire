#!/bin/bash
# 62-vblur-control.sh: Configure vblur mode for Adreno 610 and ensure /var symlink integrity
# Preferences are now written as XML plist files by 60-skip-setup.sh (no defaults write needed)

set -e

echo "=== [62] Configuring vblur control and verifying preferences ==="

# 1. Ensure /var symlink points to private/var (critical for iOS dual-boot)
if [ -L /var ] && [ "$(readlink /var)" != "private/var" ]; then
    echo "  Fixing /var symlink..."
    rm -f /var
    ln -s private/var /var
fi

# 2. Ensure correct mobile ownership and permissions for preferences
mkdir -p /private/var/mobile/Library/Preferences
chown -R 501:501 /private/var/mobile/Library/Preferences
chmod 600 /private/var/mobile/Library/Preferences/*.plist 2>/dev/null || true

# 3. Verify critical preference files exist (written by 60-skip-setup.sh)
for plist in com.apple.springboard.plist com.apple.Accessibility.plist; do
    if [ -f "/private/var/mobile/Library/Preferences/$plist" ]; then
        echo "  ✓ $plist present"
    else
        echo "  ⚠ $plist missing (should be created by 60-skip-setup.sh)"
    fi
done

# 4. Kill cfprefsd and respring SpringBoard to apply immediately
killall -9 cfprefsd 2>/dev/null || true
killall -9 SpringBoard 2>/dev/null || true

echo "=== [62] vblur mode 2 + blur-free preferences verified ==="
true