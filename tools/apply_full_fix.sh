#!/bin/bash
set -euo pipefail

echo "=== 1. Connect NBD ==="
insmod /home/khanh/modules/hfsplus.ko 2>/dev/null || true
nbd-client -d /dev/nbd0 2>/dev/null || true
nbd-client 172.20.160.1 10810 /dev/nbd0 -b 4096

mkdir -p /mnt/iosroot
echo "=== 1.5. Run fsck ==="
fsck.hfsplus -y /dev/nbd0 || true

echo "=== 2. Mount HFS+ ==="
mount -t hfsplus -o force,rw /dev/nbd0 /mnt/iosroot

echo "=== 3. Fix /var symlink ==="
if [ ! -L /mnt/iosroot/var ]; then
    echo "Converting /var to symlink..."
    cp -a /mnt/iosroot/var/. /mnt/iosroot/private/var/ 2>/dev/null || true
    rm -rf /mnt/iosroot/var
    ln -s private/var /mnt/iosroot/var
fi
ls -ld /mnt/iosroot/var

echo "=== 4. Ensure Timezone and zoneinfo ==="
mkdir -p /mnt/iosroot/private/var/db/timezone
mkdir -p /mnt/iosroot/usr/share/zoneinfo.default
cp -a /usr/share/zoneinfo/. /mnt/iosroot/usr/share/zoneinfo.default/ 2>/dev/null || true
ln -sf /usr/share/zoneinfo.default /mnt/iosroot/private/var/db/timezone/zoneinfo
ln -sf /var/db/timezone/zoneinfo/Asia/Ho_Chi_Minh /mnt/iosroot/private/var/db/timezone/localtime
chown -R 0:0 /mnt/iosroot/usr/share /mnt/iosroot/private/var/db/timezone
chmod -R 755 /mnt/iosroot/usr/share /mnt/iosroot/private/var/db/timezone
ls -la /mnt/iosroot/private/var/db/timezone/

echo "=== 5. Write Preferences for Zero-Stutter 120 FPS ==="
PREFS="/mnt/iosroot/private/var/mobile/Library/Preferences"
mkdir -p "$PREFS"

cat << 'PLIST' > "$PREFS/com.apple.springboard.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>BKNoWatchdogs</key>
    <true/>
    <key>FBLaunchWatchdogExceptions</key>
    <dict>
        <key>com.apple.purplebuddy</key>
        <real>100.0</real>
    </dict>
    <key>MCForceShowCloudConfigurationUI</key>
    <false/>
    <key>SBDisableParallax</key>
    <true/>
    <key>SBReduceMotion</key>
    <true/>
</dict>
</plist>
PLIST

cat << 'PLIST' > "$PREFS/com.apple.Accessibility.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>ReduceTransparency</key>
    <true/>
    <key>EnhanceBackgroundContrast</key>
    <true/>
    <key>ReduceMotion</key>
    <true/>
    <key>DifferentiateWithoutColor</key>
    <false/>
    <key>InvertColors</key>
    <false/>
    <key>GrayscaleDisplay</key>
    <false/>
    <key>BoldText</key>
    <false/>
    <key>ButtonShapes</key>
    <false/>
    <key>OnOffLabels</key>
    <false/>
    <key>ReduceWhitePoint</key>
    <false/>
    <key>ReduceWhitePointIntensity</key>
    <real>0.5</real>
    <key>SpeakSelection</key>
    <false/>
    <key>SpeakScreen</key>
    <false/>
    <key>VoiceOverEnabled</key>
    <false/>
</dict>
</plist>
PLIST

cat << 'PLIST' > "$PREFS/com.apple.CoreAnimation.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CAHalfResolutionBackdrop</key>
    <true/>
    <key>CADisableBlur</key>
    <true/>
    <key>CAForceDirtyRects</key>
    <true/>
    <key>CAShadowQuality</key>
    <integer>1</integer>
</dict>
</plist>
PLIST

cat << 'PLIST' > "$PREFS/com.apple.MaterialKit.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>ReduceTransparency</key>
    <true/>
</dict>
</plist>
PLIST

chown -R 501:501 "$PREFS"
chmod 700 "$PREFS"
chmod 600 "$PREFS"/*.plist

echo "=== 6. Write eagl.c Boot Arguments (/var/tmp/gl.args) ==="
mkdir -p /mnt/iosroot/private/var/tmp
chmod 1777 /mnt/iosroot/private/var/tmp

# vblur=0: DISABLES Gaussian blur entirely (CRITICAL for Adreno 610 Control Center freeze)
# vblur=2: mask-based blur (lighter but still runs shader - NOT enough for CC freeze)
# glwait=1: CRITICAL - ensures glFinish() at frame_end, fixes Adreno 610 GMEM tiling corruption
printf "vblur=0 glwait=1 glprecision=0" > /mnt/iosroot/private/var/tmp/gl.args
chmod 666 /mnt/iosroot/private/var/tmp/gl.args
chown 501:501 /mnt/iosroot/private/var/tmp/gl.args

mkdir -p /mnt/iosroot/redwood/boot.d
cat << 'EOF' > /mnt/iosroot/redwood/boot.d/58-gl-args.sh
#!/bin/bash
# vblur=0 DISABLES Gaussian blur pass in eagl.c entirely - critical for Adreno 610
# glwait=1 ENSURES glFinish() at frame_end - fixes black rectangle tiling on Adreno 610 GMEM
printf "vblur=0 glwait=1 glprecision=0" > /var/tmp/gl.args
chmod 666 /var/tmp/gl.args
chown 501:501 /var/tmp/gl.args
EOF
chmod 755 /mnt/iosroot/redwood/boot.d/58-gl-args.sh
chown 0:0 /mnt/iosroot/redwood/boot.d/58-gl-args.sh

echo "=== 7. Mesa / freedreno Environment ==="
cat << 'EOF' > /mnt/iosroot/redwood/glenv
FD_MESA_DEBUG=
mesa_glthread=true
mesa_async_flush=true
FD_PERF=1
FD_DEBUG=0
IR3_SHADER_DEBUG=0
FD_NO_SYNC=0
FD_UBWC=0
EOF
chmod 644 /mnt/iosroot/redwood/glenv
chown 0:0 /mnt/iosroot/redwood/glenv

cat << 'EOF' > /mnt/iosroot/redwood/boot.d/56-mesa-env.sh
#!/bin/bash
export FD_MESA_DEBUG=
export mesa_glthread=true
export mesa_async_flush=true
export FD_PERF=1
export FD_DEBUG=0
export IR3_SHADER_DEBUG=0
export FD_NO_SYNC=0
export FD_UBWC=0
EOF
chmod 755 /mnt/iosroot/redwood/boot.d/56-mesa-env.sh
chown 0:0 /mnt/iosroot/redwood/boot.d/56-mesa-env.sh

echo "=== 8. ElleKit & Mesa Cache Perms ==="
rm -f /mnt/iosroot/redwood/sapphire-notweaks
rm -f /mnt/iosroot/private/var/tmp/sapphire-notweaks
rm -f /mnt/iosroot/private/var/root/sapphire-notweaks

mkdir -p /mnt/iosroot/private/var/tmp/mesa_cache
chmod 1777 /mnt/iosroot/private/var/tmp/mesa_cache
chown 501:501 /mnt/iosroot/private/var/tmp/mesa_cache

echo "=== 9. Flush and Unmount Cleanly ==="
sync
umount /mnt/iosroot
nbd-client -d /dev/nbd0
echo "=== ALL FIXES APPLIED AND FILESYSTEM UNMOUNTED CLEANLY! ==="
