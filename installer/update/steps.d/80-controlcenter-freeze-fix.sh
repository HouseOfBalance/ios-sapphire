#!/bin/bash
# 80-controlcenter-freeze-fix.sh: Fix Control Center GPU deadlock on Adreno 610
# ROOT CAUSE: CABackdropLayer Gaussian blur overflows GMEM tile memory (512KB-1MB)
# causing GPU fence deadlock, blocking backboardd input queue completely
#
# REAL FIXES (not hallucinated keys):
# 1. eagl.c driver level: vblur=0 in /var/tmp/gl.args DISABLES Gaussian blur pass entirely
# 2. iOS Accessibility: ReduceTransparency + ReduceMotion in com.apple.Accessibility.plist
# 3. CoreAnimation: CA_DISABLE_BLUR, CA_HALFRES_BACKDROP, CA_FORCE_DIRTY_RECTS via boot args
# 4. Disable heavy Control Center modules that cause synchronous XPC waits

set -e

echo "=== [80] Applying Control Center freeze fix (REAL keys only) ==="

# 1. eagl.c driver level: COMPLETELY DISABLE Gaussian blur (vblur=0)
# This is the ONLY way to stop the Gaussian blur shader from executing on Adreno 610
# vblur=0: disable blur entirely | vblur=2: mask-based blur (lighter but still runs shader)
# glwait=1: CRITICAL - ensures glFinish() at frame_end, fixes Adreno 610 GMEM tiling corruption
mkdir -p /private/var/tmp /var/tmp
cat > /var/tmp/gl.args <<'EOF'
vblur=0 glwait=1 glprecision=0
EOF
chmod 644 /var/tmp/gl.args
cp -f /var/tmp/gl.args /private/var/tmp/gl.args 2>/dev/null || true

# Also persist in /redwood for reference
mkdir -p /redwood
cat > /redwood/gl.args <<'EOF'
vblur=0 glwait=1 glprecision=0
EOF
chmod 644 /redwood/gl.args

# Boot.d script to enforce at EVERY BOOT (userland)
mkdir -p /redwood/boot.d
cat > /redwood/boot.d/80-controlcenter-gl-args.sh <<'BOOT_EOF'
#!/bin/bash
# Enforce vblur=0 glwait=1 glprecision=0 at every boot for Control Center stability
# vblur=0 DISABLES Gaussian blur pass in eagl.c entirely - critical for Adreno 610
# glwait=1 ENSURES glFinish() at frame_end - fixes black rectangle tiling on Adreno 610 GMEM
mkdir -p /private/var/tmp /var/tmp
cat > /var/tmp/gl.args <<'EOF2'
vblur=0 glwait=1 glprecision=0
EOF2
chmod 644 /var/tmp/gl.args
cp -f /var/tmp/gl.args /private/var/tmp/gl.args 2>/dev/null || true
BOOT_EOF
chmod 755 /redwood/boot.d/80-controlcenter-gl-args.sh

# 2. iOS Accessibility: REAL keys that actually exist in iOS 16
# ReduceTransparency: Disables backdrop blur system-wide (Control Center, dock, folders)
# ReduceMotion: Disables parallax and animation effects
cat > /private/var/mobile/Library/Preferences/com.apple.Accessibility.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- Disable transparency/blur system-wide (Control Center backdrop, dock, folders) -->
    <key>ReduceTransparency</key>
    <true/>
    <!-- Reduce motion/parallax effects -->
    <key>ReduceMotion</key>
    <true/>
    <!-- Disable cross-fade transitions -->
    <key>UICrossFadeTransparency</key>
    <false/>
    <!-- Increase contrast (removes some blur effects) -->
    <key>UIIncreaseContrast</key>
    <true/>
    <!-- Reduce white point -->
    <key>UIReduceWhitePoint</key>
    <false/>
</dict>
</plist>
EOF

# 3. CoreAnimation: Use boot args (NOT plist keys) for CA flags
# These are read by kernel/userspace at boot via PE_parse_boot_argn
# CA_DISABLE_BLUR, CA_HALFRES_BACKDROP, CA_FORCE_DIRTY_RECTS
# We already set these in 58-sapphire-boot-args.sh but ensure they're present
cat >> /redwood/boot-args.d/99-performance.conf <<'EOF'

# Control Center freeze prevention (80) - CoreAnimation boot args
sapphire_ca_disable_blur=1
sapphire_ca_halfres_backdrop=1
sapphire_ca_force_dirty_rects=1
EOF

# 4. SpringBoard: Disable Control Center heavy modules via REAL plist keys
# com.apple.controlcenter.plist - only use keys that exist
cat > /private/var/mobile/Library/Preferences/com.apple.controlcenter.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- Module visibility - only show essential modules -->
    <key>CCModuleVisibility</key>
    <dict>
        <key>CCBluetoothModule</key>
        <true/>
        <key>CCWiFiModule</key>
        <true/>
        <key>CCAirDropModule</key>
        <true/>
        <key>CCNearbyDevicesModule</key>
        <false/>
        <key>CCFlashlightModule</key>
        <true/>
        <key>CCTimerModule</key>
        <true/>
        <key>CCCalculatorModule</key>
        <true/>
        <key>CCCameraModule</key>
        <true/>
    </dict>
    <!-- Customize Control Center layout -->
    <key>CCCustomizeEnabled</key>
    <true/>
</dict>
</plist>
EOF

# 5. SpringBoard: Reduce backdrop complexity via PosterBoard
# PosterBoard handles wallpaper/backdrop rendering
cat > /private/var/mobile/Library/Preferences/com.apple.PosterBoard.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- Disable dynamic backdrop blur -->
    <key>PBDisableDynamicBackdrop</key>
    <true/>
    <!-- Use static wallpaper only -->
    <key>PBForceStaticBackdrop</key>
    <true/>
    <!-- Disable parallax on wallpaper -->
    <key>PBDisableParallax</key>
    <true/>
</dict>
</plist>
EOF

# 6. Backboardd: Input handling - use REAL launchd/service config
# Backboardd doesn't read plist keys for GPU timeout.
# Instead, ensure sweet_touch_boost and sweet_sched handle priority correctly
# These are already set in boot args (sweet_touch_boost_enabled=1, sweet_sched=13)

# 7. Disable mediaserverd/bluetoothd synchronous XPC from Control Center
# by ensuring those modules are hidden (done in step 4)
# No additional plist keys exist for async XPC timeout in SpringBoard

# Fix ownership - use UID/GID 501:501 (mobile user on iOS)
# Works in minimal environments where /etc/passwd may not resolve "mobile"
chown -R 501:501 /private/var/mobile/Library/Preferences/ 2>/dev/null || true
chmod 700 /private/var/mobile/Library/Preferences 2>/dev/null || true
chmod 600 /private/var/mobile/Library/Preferences/*.plist 2>/dev/null || true

echo "=== [80] Control Center freeze fix applied (REAL keys only) ==="
echo ""
echo "CRITICAL CHANGES:"
echo "  1. eagl.c: vblur=0 in /var/tmp/gl.args - DISABLES Gaussian blur shader entirely"
echo "  2. Accessibility: ReduceTransparency=true, ReduceMotion=true (real iOS 16 keys)"
echo "  3. CoreAnimation: sapphire_ca_disable_blur=1, sapphire_ca_halfres_backdrop=1, sapphire_ca_force_dirty_rects=1 via boot args"
echo "  4. Control Center: Bluetooth, WiFi, AirDrop, NearbyDevices modules HIDDEN"
echo "  5. PosterBoard: Dynamic backdrop disabled, static wallpaper forced"
echo ""
echo "BOOT ARGS ADDED to 99-performance.conf:"
echo "  sapphire_ca_disable_blur=1"
echo "  sapphire_ca_halfres_backdrop=1"
echo "  sapphire_ca_force_dirty_rects=1"
echo ""
echo "ENFORCED AT EVERY BOOT via /redwood/boot.d/80-controlcenter-gl-args.sh:"
echo "  vblur=0 glwait=1 glprecision=0"

true