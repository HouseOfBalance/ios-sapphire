#!/bin/bash
# 74-youtube-music-web-fix.sh: Fix YouTube Music Web Player Audio
# Root causes:
# 1. WebKit preferences missing MediaSourceEnabled, VP9DecoderEnabled, OpusDecoderEnabled
# 2. mediaserverd may lack Opus/WebM audio decoder plugins
# 3. Widevine/FairPlay EME may not be available for DRM content
# 4. YouTube Music uses MSE (Media Source Extensions) + WebM/Opus primarily

set -e

echo "=== [74] Fixing YouTube Music Web Player ==="

# 1. Safari/WebKit preferences - enable required media features
mkdir -p /private/var/mobile/Library/Preferences

cat > /private/var/mobile/Library/Preferences/com.apple.mobilesafari.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>MediaSourceEnabled</key>
    <true/>
    <key>VP9DecoderEnabled</key>
    <true/>
    <key>OpusDecoderEnabled</key>
    <true/>
    <key>WebMFormatEnabled</key>
    <true/>
    <key>MediaCapabilitiesDecodingInfoEnabled</key>
    <true/>
    <key>EncryptedMediaEnabled</key>
    <true/>
    <key>WebAudioEnabled</key>
    <true/>
    <key>AudioWorkletEnabled</key>
    <true/>
    <key>AllowInlineVideo</key>
    <true/>
    <key>RequiresUserActionForMediaPlayback</key>
    <false/>
</dict>
</plist>
EOF
chown 501:501 /private/var/mobile/Library/Preferences/com.apple.mobilesafari.plist
chmod 600 /private/var/mobile/Library/Preferences/com.apple.mobilesafari.plist

# 2. WebKit WebContent process preferences
cat > /private/var/mobile/Library/Preferences/com.apple.WebKit.WebContent.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>MediaSourceEnabled</key>
    <true/>
    <key>VP9DecoderEnabled</key>
    <true/>
    <key>OpusDecoderEnabled</key>
    <true/>
    <key>WebMFormatEnabled</key>
    <true/>
    <key>MediaCapabilitiesDecodingInfoEnabled</key>
    <true/>
    <key>EncryptedMediaEnabled</key>
    <true/>
    <key>WebAudioEnabled</key>
    <true/>
    <key>AudioWorkletEnabled</key>
    <true/>
</dict>
</plist>
EOF
chown 501:501 /private/var/mobile/Library/Preferences/com.apple.WebKit.WebContent.plist
chmod 600 /private/var/mobile/Library/Preferences/com.apple.WebKit.WebContent.plist

# 3. Network process preferences (for MSE)
cat > /private/var/mobile/Library/Preferences/com.apple.WebKit.Networking.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>MediaSourceEnabled</key>
    <true/>
    <key>VP9DecoderEnabled</key>
    <true/>
    <key>OpusDecoderEnabled</key>
    <true/>
</dict>
</plist>
EOF
chown 501:501 /private/var/mobile/Library/Preferences/com.apple.WebKit.Networking.plist
chmod 600 /private/var/mobile/Library/Preferences/com.apple.WebKit.Networking.plist

# 4. Ensure mediaserverd has audio decoder plugins
# On iOS, audio decoding goes through AudioToolbox / mediaserverd
# Check if Opus decoder is available
if [ -f /System/Library/Audio/Plug-Ins/Codecs/OpusAudioDecoder.codec ]; then
    echo "  Opus decoder present"
else
    echo "  WARNING: OpusAudioDecoder.codec not found - WebM/Opus may fail"
fi

# 5. Create a boot script to restart Safari/WebContent after prefs applied
cat > /redwood/boot.d/74-webkit-prefs.sh <<'EOF'
#!/bin/bash
# Restart WebKit processes to pick up new preferences
killall -9 com.apple.WebKit.WebContent com.apple.WebKit.Networking 2>/dev/null || true
# Also restart Safari if running
killall -9 MobileSafari 2>/dev/null || true
EOF
chmod 755 /redwood/boot.d/74-webkit-prefs.sh

# 6. Also set global WebKit preferences via defaults (for cfprefsd)
# These take effect immediately if cfprefsd is running
defaults write com.apple.mobilesafari MediaSourceEnabled -bool true 2>/dev/null || true
defaults write com.apple.mobilesafari VP9DecoderEnabled -bool true 2>/dev/null || true
defaults write com.apple.mobilesafari OpusDecoderEnabled -bool true 2>/dev/null || true
defaults write com.apple.mobilesafari WebMFormatEnabled -bool true 2>/dev/null || true
defaults write com.apple.mobilesafari EncryptedMediaEnabled -bool true 2>/dev/null || true
defaults write com.apple.WebKit.WebContent MediaSourceEnabled -bool true 2>/dev/null || true
defaults write com.apple.WebKit.WebContent VP9DecoderEnabled -bool true 2>/dev/null || true
defaults write com.apple.WebKit.WebContent OpusDecoderEnabled -bool true 2>/dev/null || true
defaults write com.apple.WebKit.WebContent WebMFormatEnabled -bool true 2>/dev/null || true

echo "=== [74] YouTube Music WebKit preferences applied ==="
true