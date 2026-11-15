#!/bin/bash
# 70-wallpaper-posterboard-fix.sh: Fix Wallpaper Picker / Photos Wallpaper Freeze
# Root causes:
# 1. AegirPoster.appex (PosterBoard wallpaper provider) was moved away by sapphire-clean-base.sh
# 2. assetsd / photoanalysisd may be disabled
# 3. PosterBoard requires AMFI extension point (fixed by 0156-sapphire-amfi.patch)
# 4. ImageIO/Metal pixel format compatibility on Adreno 610

set -e

echo "=== [70] Fixing Wallpaper Picker / PosterBoard ==="

# 1. Restore AegirPoster.appex if it was disabled
B="/private/var/mobile/disabled-extensions"
if [ -d "$B/AegirPoster.appex" ]; then
    echo "  Restoring AegirPoster.appex..."
    mv "$B/AegirPoster.appex" "/System/Library/CoreServices/AegirProxyApp.app/PlugIns/AegirPoster.appex"
    chown -R 0:0 "/System/Library/CoreServices/AegirProxyApp.app/PlugIns/AegirPoster.appex"
    chmod -R 755 "/System/Library/CoreServices/AegirProxyApp.app/PlugIns/AegirPoster.appex"
fi

# Also check AppPlaceholders
if [ -d "$B/more" ]; then
    for f in "$B/more"/*-AegirPoster.appex; do
        if [ -d "$f" ]; then
            echo "  Restoring additional AegirPoster.appex..."
            mv "$f" "/System/Library/AppPlaceholders/AegirProxyApp.app/PlugIns/AegirPoster.appex" 2>/dev/null || true
        fi
    done
fi

# 2. Ensure critical daemons for Photos/PosterBoard are enabled
L=launchctl
command -v "$L" >/dev/null 2>&1 || L=/var/jb/usr/bin/launchctl

# assetsd (photo library daemon) - CRITICAL for wallpaper picker
"$L" enable "system/com.apple.assetsd" 2>/dev/null || true
"$L" bootstrap "system" "/System/Library/LaunchDaemons/com.apple.assetsd.plist" 2>/dev/null || true
"$L" kickstart -k "system/com.apple.assetsd" 2>/dev/null || true

# photoanalysisd (photo analysis for ML features)
"$L" enable "system/com.apple.photoanalysisd" 2>/dev/null || true
"$L" bootstrap "system" "/System/Library/LaunchDaemons/com.apple.photoanalysisd.plist" 2>/dev/null || true
"$L" kickstart -k "system/com.apple.photoanalysisd" 2>/dev/null || true

# PosterBoard daemon (wallpaper management)
"$L" enable "system/com.apple.PosterBoard" 2>/dev/null || true

# 3. Ensure PosterBoard XPC service is available
# ExtensionKit needs AMFI policy - already fixed in 0156-sapphire-amfi.patch
# But ensure the extension cache is valid
if [ -f /System/Library/xpc/extensions.plist ]; then
    echo "  Extension cache present"
else
    echo "  WARNING: /System/Library/xpc/extensions.plist missing - ExtensionKit may not find PosterBoard"
fi

# 4. ImageIO/Metal compatibility: Force software decoding for wallpaper picker
# Adreno 610 via HakiosMetal may not support all pixel formats PosterBoard requests
# Set preference for software fallback
mkdir -p /private/var/mobile/Library/Preferences
cat > /private/var/mobile/Library/Preferences/com.apple.ImageIO.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>DisableHardwareAcceleration</key>
    <true/>
    <key>ForceSoftwareDecode</key>
    <true/>
</dict>
</plist>
EOF
chown 501:501 /private/var/mobile/Library/Preferences/com.apple.ImageIO.plist
chmod 600 /private/var/mobile/Library/Preferences/com.apple.ImageIO.plist

# 5. PosterBoard preferences - ensure it uses compatible formats
cat > /private/var/mobile/Library/Preferences/com.apple.PosterBoard.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>UseSoftwareRenderer</key>
    <true/>
    <key>DisableMetalTextureCache</key>
    <true/>
    <key>AllowedPixelFormats</key>
    <array>
        <string>BGRA8Unorm</string>
        <string>RGBA8Unorm</string>
        <string>BGRA8Unorm_sRGB</string>
    </array>
</dict>
</plist>
EOF
chown 501:501 /private/var/mobile/Library/Preferences/com.apple.PosterBoard.plist
chmod 600 /private/var/mobile/Library/Preferences/com.apple.PosterBoard.plist

# 6. Restart affected services
killall -9 assetsd photoanalysisd PosterBoard 2>/dev/null || true

echo "=== [70] Wallpaper/PosterBoard fix applied ==="
true