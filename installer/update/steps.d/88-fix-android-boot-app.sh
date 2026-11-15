#!/bin/bash
# 88-fix-android-boot-app.sh: Restore Android dual-boot switcher app entitlements & permissions
# Root cause: Blind ldid -S stripped platform-application, no-sandbox, and no-container entitlements.
# Without no-sandbox, iOS kills Android.app immediately when it tries to read /redwood/version or call sysctl.

set -e

echo "=== [88] Restoring Android Dual-Boot Switcher App ==="

ANDROID_ENT="/tmp/AndroidBoot.entitlements"
cat > "$ANDROID_ENT" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>application-identifier</key>
	<string>com.sapphire.androidboot</string>
	<key>platform-application</key>
	<true/>
	<key>com.apple.private.security.no-sandbox</key>
	<true/>
	<key>com.apple.private.security.no-container</key>
	<true/>
</dict>
</plist>
EOF

# Determine ldid binary
LDID="/var/jb/usr/bin/ldid"
[ -x "$LDID" ] || LDID="/usr/bin/ldid"

# 1. Clean up stray /Android.app at filesystem root if present
if [ -d "/Android.app" ]; then
    echo "Found stray /Android.app at root, moving to /Applications/Android.app if needed..."
    if [ ! -d "/Applications/Android.app" ]; then
        mv /Android.app /Applications/Android.app
    else
        cp -af /Android.app/* /Applications/Android.app/ 2>/dev/null || true
        rm -rf /Android.app
    fi
fi

# 2. Re-sign and restore /Applications/Android.app
if [ -d "/Applications/Android.app" ]; then
    echo "Restoring /Applications/Android.app..."
    chown -R 0:0 /Applications/Android.app
    chmod -R 755 /Applications/Android.app
    
    if [ -f "/Applications/Android.app/Android" ]; then
        chmod 755 /Applications/Android.app/Android
        if [ -x "$LDID" ]; then
            "$LDID" -S"$ANDROID_ENT" /Applications/Android.app/Android 2>/dev/null && \
                echo "  ✓ Re-signed /Applications/Android.app/Android with full entitlements"
        fi
    fi
fi

# 3. Check and restore TrollStore bundle location if present
for troll_app in /private/var/containers/Bundle/Application/*/Android.app; do
    if [ -d "$troll_app" ]; then
        echo "Found TrollStore Android app: $troll_app"
        chown -R 0:0 "$troll_app" 2>/dev/null || true
        chmod -R 755 "$troll_app" 2>/dev/null || true
        if [ -f "$troll_app/Android" ] && [ -x "$LDID" ]; then
            chmod 755 "$troll_app/Android"
            "$LDID" -S"$ANDROID_ENT" "$troll_app/Android" 2>/dev/null && \
                echo "  ✓ Re-signed $troll_app/Android"
        fi
    fi
done

# 4. Refresh icon and LaunchServices cache
if [ -x /var/jb/usr/bin/uicache ]; then
    /var/jb/usr/bin/uicache -p /Applications/Android.app 2>/dev/null || true
fi

rm -f "$ANDROID_ENT"

echo "=== [88] Android Dual-Boot Switcher App restored successfully ==="
